#!/bin/bash
# =============================================================================
# ws_lib/ws_config.sh — Configuración y seguridad de servicios web
# Requiere: source lib/ui.sh, source ws_lib/ws_utils.sh, source ws_lib/ws_validators.sh
#           source ws_lib/ws_status.sh, source ws_lib/ws_install.sh
# =============================================================================

#
# _http_seleccionar_servicio_instalado  (interna)
#
_http_seleccionar_servicio_instalado() {
    local _var_destino="$1"

    local servicios_instalados=()
    local nombres_instalados=()

    local paquete
    for paquete in httpd nginx tomcat; do
        if rpm -q "$(http_nombre_paquete "$paquete")" &>/dev/null; then
            servicios_instalados+=("$paquete")
            case "$paquete" in
                httpd)  nombres_instalados+=("Apache (httpd)") ;;
                nginx)  nombres_instalados+=("Nginx")          ;;
                tomcat) nombres_instalados+=("Tomcat")         ;;
            esac
        fi
    done

    if [[ ${#servicios_instalados[@]} -eq 0 ]]; then
        msg_error "No hay ningun servicio HTTP instalado en el sistema"
        msg_info  "Vaya a la opcion 2) Instalar servicio HTTP"
        return 1
    fi

    echo ""
    msg_info "Servicios HTTP instalados:"
    echo ""

    local i
    for i in "${!servicios_instalados[@]}"; do
        local num=$(( i + 1 ))
        local svc="${servicios_instalados[$i]}"
        local nombre="${nombres_instalados[$i]}"
        local version
        version=$(rpm -q --queryformat "%{VERSION}" \
                  "$(http_nombre_paquete "$svc")" 2>/dev/null)
        local estado=""
        if check_service_active "$(http_nombre_systemd "$svc")"; then
            estado="${GREEN}activo${NC}"
        else
            estado="${YELLOW}inactivo${NC}"
        fi
        printf "  ${BLUE}%s)${NC} %-20s v%-15s " "$num" "$nombre" "$version"
        echo -e "$estado"
    done

    echo ""

    local opcion
    while true; do
        input_read "Seleccione el servicio [1-${#servicios_instalados[@]}]" opcion
        if http_validar_opcion_menu "$opcion" "${#servicios_instalados[@]}"; then
            break
        fi
        echo ""
    done

    printf -v "$_var_destino" "%s" "${servicios_instalados[$(( opcion - 1 ))]}"
    return 0
}

#
# _http_leer_puerto_config  (interna)
#
_http_leer_puerto_config() {
    local servicio="$1"
    local archivo_conf
    archivo_conf=$(http_get_conf_archivo "$servicio")
    [[ ! -f "$archivo_conf" ]] && return 0

    local puerto=""
    case "$servicio" in
        httpd)
            puerto=$(sudo grep -E "^Listen\s+[0-9]+" "$archivo_conf" 2>/dev/null \
                     | awk '{print $2}' | grep -oP '[0-9]+$' | head -1)
            ;;
        nginx)
            puerto=$(sudo grep -E "^\s+listen\s+[0-9]+" "$archivo_conf" 2>/dev/null \
                     | grep -oP '\d+' | head -1)
            # Si ssl_manager comentó el listen, leer desde http-redirect.conf
            if [[ -z "$puerto" ]] && \
               sudo grep -q "# ssl_manager: HTTP desactivado" "$archivo_conf" 2>/dev/null; then
                local redirect_conf="/etc/nginx/conf.d/http-redirect.conf"
                if [[ -f "$redirect_conf" ]]; then
                    puerto=$(sudo grep -E "^\s+listen\s+[0-9]+" "$redirect_conf" 2>/dev/null \
                             | grep -oP '\d+' | head -1)
                fi
            fi
            ;;
        tomcat)
            puerto=$(sudo grep -oP 'Connector port="\K[0-9]+(?=" protocol="HTTP)' \
                     "$archivo_conf" 2>/dev/null | head -1)
            ;;
    esac
    echo "$puerto"
}

#
# _http_actualizar_firewall_puerto  (interna)
#
_http_actualizar_firewall_puerto() {
    local puerto_nuevo="$1"
    local puerto_viejo="$2"

    msg_info "Actualizando reglas de firewall..."
    echo ""

    if ! sudo firewall-cmd --list-ports 2>/dev/null \
         | grep -q "${puerto_nuevo}/tcp"; then
        if sudo firewall-cmd --permanent \
               --add-port="${puerto_nuevo}/tcp" 2>/dev/null; then
            msg_success "Puerto ${puerto_nuevo}/tcp abierto (permanente)"
        else
            msg_error "No se pudo abrir el puerto ${puerto_nuevo}/tcp"
            return 1
        fi
    else
        msg_info "Puerto ${puerto_nuevo}/tcp ya estaba abierto"
    fi

    if ! http_puerto_en_uso "$puerto_viejo"; then
        if (( puerto_viejo == 80 )); then
            sudo firewall-cmd --permanent --remove-service=http \
                 2>/dev/null \
            && msg_success "Servicio http (80) eliminado del firewall"
        fi
        if sudo firewall-cmd --list-ports 2>/dev/null \
           | grep -q "${puerto_viejo}/tcp"; then
            sudo firewall-cmd --permanent \
                 --remove-port="${puerto_viejo}/tcp" 2>/dev/null \
            && msg_success "Puerto ${puerto_viejo}/tcp cerrado en firewall"
        fi
    else
        local proceso_viejo
        proceso_viejo=$(http_quien_usa_puerto "$puerto_viejo")
        msg_info "Puerto ${puerto_viejo} aun en uso por '${proceso_viejo}' — no se cierra"
    fi

    sudo firewall-cmd --reload 2>/dev/null
    msg_success "Firewall recargado"
    return 0
}

#
# _http_ssl_activo_para  (interna)
# Retorna 0 si SSL está activo para el servicio dado.
# No depende de ssl_lib — solo lee archivos y puertos.
#
_http_ssl_activo_para() {
    local servicio="$1"
    case "$servicio" in
        httpd)
            [[ -f "/etc/httpd/conf.d/ssl-reprobados.conf" ]]
            ;;
        nginx)
            # El bloque SSL está dentro de nginx.conf — buscar la marca
            sudo grep -q "ssl_manager: SSL block" /etc/nginx/nginx.conf 2>/dev/null
            ;;
        tomcat)
            local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
            sudo grep -q 'SSLEnabled="true"' "${catalina}/conf/server.xml" 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

#
# http_cambiar_puerto
#
# Cuando SSL está activo, pide AMBOS puertos (HTTP y HTTPS) y llama
# a ssl_*_actualizar_puertos para reescribir la config SSL completa.
#
http_cambiar_puerto() {
    clear
    draw_header "Cambiar Puerto de Servicio HTTP"

    local servicio
    if ! _http_seleccionar_servicio_instalado servicio; then
        return 1
    fi

    http_draw_servicio_header "$servicio" "Cambio de Puerto"

    local ssl_activo=false
    _http_ssl_activo_para "$servicio" && ssl_activo=true

    # ── Leer puertos actuales ─────────────────────────────────────────────
    local puerto_http_actual
    puerto_http_actual=$(_http_leer_puerto_config "$servicio")
    [[ -z "$puerto_http_actual" ]] && {
        case "$servicio" in
            httpd)  puerto_http_actual="$HTTP_PUERTO_DEFAULT_APACHE" ;;
            nginx)  puerto_http_actual="$HTTP_PUERTO_DEFAULT_NGINX"  ;;
            tomcat) puerto_http_actual="$HTTP_PUERTO_DEFAULT_TOMCAT" ;;
        esac
    }

    local puerto_https_actual=""
    if $ssl_activo; then
        case "$servicio" in
            httpd)
                puerto_https_actual=$(sudo grep -oP "^Listen\s+\K[0-9]+"                     /etc/httpd/conf.d/ssl-reprobados.conf 2>/dev/null | head -1)
                ;;
            nginx)
                puerto_https_actual=$(sudo grep -A3 "ssl_manager: SSL block"                     /etc/nginx/nginx.conf 2>/dev/null                     | grep -oP "listen\s+\K[0-9]+" | head -1)
                ;;
            tomcat)
                puerto_https_actual=$(sudo grep -A5 "ssl_manager: HTTPS Connector"                     "${CATALINA_HOME:-/usr/share/tomcat}/conf/server.xml" 2>/dev/null                     | grep -oP 'port="\K[0-9]+' | head -1)
                ;;
        esac
    fi

    echo ""
    msg_info "Puertos actuales:"
    printf "    HTTP  : %s/tcp
" "$puerto_http_actual"
    $ssl_activo && printf "    HTTPS : %s/tcp
" "${puerto_https_actual:-desconocido}"
    echo ""
    http_listar_puertos_activos
    echo ""

    # ── Pedir nuevo puerto HTTP ───────────────────────────────────────────
    local puerto_http_nuevo
    while true; do
        input_read "Nuevo puerto HTTP [actual: ${puerto_http_actual}]" puerto_http_nuevo
        [[ -z "$puerto_http_nuevo" ]] && {
            msg_error "Debe ingresar un número de puerto"; echo ""; continue; }
        http_validar_puerto_cambio "$puerto_http_nuevo" "$puerto_http_actual" && break
        echo ""
    done

    # ── Pedir nuevo puerto HTTPS si SSL está activo ───────────────────────
    local puerto_https_nuevo=""
    if $ssl_activo; then
        echo ""
        msg_info "SSL activo — también debes cambiar el puerto HTTPS."
        while true; do
            input_read "Nuevo puerto HTTPS [actual: ${puerto_https_actual:-443}]" puerto_https_nuevo
            [[ -z "$puerto_https_nuevo" ]] && {
                msg_error "Debe ingresar un número de puerto"; echo ""; continue; }
            # No puede ser igual al puerto HTTP nuevo
            if [[ "$puerto_https_nuevo" == "$puerto_http_nuevo" ]]; then
                msg_error "El puerto HTTPS no puede ser igual al HTTP (${puerto_http_nuevo})"
                echo ""; continue
            fi
            # No puede ser igual al puerto HTTPS actual (no hay cambio)
            if [[ -n "${puerto_https_actual:-}" && "$puerto_https_nuevo" == "$puerto_https_actual" ]]; then
                msg_error "El puerto HTTPS nuevo es igual al actual (${puerto_https_actual}) — ingresa un puerto diferente"
                echo ""; continue
            fi
            # No puede ser igual al puerto HTTP actual
            if [[ "$puerto_https_nuevo" == "$puerto_http_actual" ]]; then
                msg_error "El puerto HTTPS no puede ser igual al HTTP actual (${puerto_http_actual})"
                echo ""; continue
            fi
            http_validar_puerto_cambio "$puerto_https_nuevo" "${puerto_https_actual:-443}" && break
            echo ""
        done
    fi

    echo ""
    msg_alert "Cambios a aplicar en ${servicio}:"
    printf "    HTTP  : %s → %s/tcp
" "$puerto_http_actual" "$puerto_http_nuevo"
    $ssl_activo && printf "    HTTPS : %s → %s/tcp
"         "${puerto_https_actual:-?}" "$puerto_https_nuevo"
    echo ""

    local confirmacion
    while true; do
        input_read "Confirmar cambio? [s/n]" confirmacion
        http_validar_confirmacion "$confirmacion"
        local rc=$?
        (( rc == 0 )) && break
        (( rc == 1 )) && { msg_info "Cambio cancelado"; sleep 1; return 0; }
        echo ""
    done

    separator
    echo ""

    local archivo_conf
    archivo_conf=$(http_get_conf_archivo "$servicio")

    # ── PASO 1: Cambiar puerto HTTP en la config principal ────────────────
    msg_info "PASO 1/4 — Actualizar puerto HTTP en ${archivo_conf}"
    http_crear_backup "$archivo_conf" || {
        msg_error "No se pudo crear backup"; return 1; }
    _http_configurar_puerto_inicial "$servicio" "$puerto_http_nuevo"
    echo ""

    # ── PASO 2: Si SSL activo, reescribir config SSL con ambos puertos ────
    if $ssl_activo; then
        msg_info "PASO 2/4 — Actualizar configuración SSL"
        local _ssl_lib
        _ssl_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/ssl_lib/ssl.sh"
        [[ ! -f "$_ssl_lib" ]] &&             _ssl_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../ssl_lib/ssl.sh"

        if [[ -f "$_ssl_lib" ]] && source "$_ssl_lib" 2>/dev/null; then
            case "$servicio" in
                httpd) ssl_apache_actualizar_puertos "$puerto_http_nuevo" "$puerto_https_nuevo" ;;
                nginx) ssl_nginx_actualizar_puertos  "$puerto_http_nuevo" "$puerto_https_nuevo" ;;
                tomcat) ssl_tomcat_actualizar_puertos "$puerto_https_nuevo" ;;
            esac || {
                msg_error "Error al actualizar SSL — restaurando"
                http_restaurar_backup "$archivo_conf"
                return 1
            }
        else
            msg_error "ssl_lib no disponible — rollback"
            http_restaurar_backup "$archivo_conf"
            return 1
        fi
        echo ""
    fi

    # ── PASO 3: Reiniciar ─────────────────────────────────────────────────
    msg_info "PASO 3/4 — Reiniciar servicio"
    if ! http_reiniciar_servicio "$servicio"; then
        msg_error "El servicio no levanto — restaurando"
        http_restaurar_backup "$archivo_conf"
        http_reiniciar_servicio "$servicio"
        return 1
    fi
    echo ""

    # ── PASO 4: Verificar ─────────────────────────────────────────────────
    msg_info "PASO 4/4 — Verificar respuesta en puerto ${puerto_http_nuevo}"
    sleep 2

    local _verify_ok=false
    if $ssl_activo; then
        local _code
        _code=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 5 --max-redirs 0 \
                "http://localhost:${puerto_http_nuevo}" 2>/dev/null)
        [[ "$_code" =~ ^(200|301|302)$ ]] && {
            msg_success "Puerto ${puerto_http_nuevo} responde (HTTP ${_code})"
            _verify_ok=true
        }
    else
        http_verificar_respuesta "$servicio" "$puerto_http_nuevo" && _verify_ok=true
    fi

    if ! $_verify_ok; then
        msg_error "Sin respuesta en puerto ${puerto_http_nuevo} — restaurando"
        http_restaurar_backup "$archivo_conf"
        http_reiniciar_servicio "$servicio"
        return 1
    fi
    echo ""

    # Actualizar firewall para el puerto HTTP (el HTTPS ya lo maneja ssl_*_actualizar_puertos)
    msg_info "PASO 5/5 — Actualizando reglas de firewall"
    _http_actualizar_firewall_puerto "$puerto_http_nuevo" "$puerto_http_actual"
    echo ""

    # Actualizar index.html con los puertos correctos
    local _version
    _version=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" \
               "$(http_nombre_paquete "$servicio")" 2>/dev/null)
    if $ssl_activo && [[ -n "$puerto_https_nuevo" ]]; then
        http_crear_index "$servicio" "$_version" "$puerto_http_nuevo" "$puerto_https_nuevo"
    else
        http_crear_index "$servicio" "$_version" "$puerto_http_nuevo"
    fi

    echo ""
    separator
    if $ssl_activo; then
        msg_success "Puertos cambiados — HTTP: ${puerto_http_actual} → ${puerto_http_nuevo} | HTTPS: ${puerto_https_actual} → ${puerto_https_nuevo}"
    else
        msg_success "Puerto cambiado exitosamente: ${puerto_http_actual} → ${puerto_http_nuevo}"
    fi
    separator
}

#
# _http_seguridad_apache  (interna)
# Escribe security.conf preservando el bloque HSTS si SSL está activo.
#
_http_seguridad_apache() {
    msg_info "Aplicando security headers en Apache..."
    echo ""

    http_crear_backup "$HTTP_CONF_APACHE_SECURITY"
    echo ""

    # Si SSL está activo, HSTS ya está en ssl-reprobados.conf.
    # Lo incluimos igualmente en security.conf para que funcione
    # también en el VirtualHost HTTP (aunque redirija, algunos proxies
    # pueden necesitarlo). Si no hay SSL, el bloque HSTS no causa daño
    # porque solo aplica sobre conexiones que ya son HTTPS.
    local hsts_block=""
    if _http_ssl_activo_para "httpd"; then
        hsts_block='    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"'
        msg_info "SSL activo — HSTS preservado en security.conf"
    fi

    sudo tee "$HTTP_CONF_APACHE_SECURITY" > /dev/null << APACHEEOF
# security.conf — Generado por ws_config.sh
# $(date '+%Y-%m-%d %H:%M:%S')

# Ocultar version del servidor en headers HTTP
ServerTokens Prod
ServerSignature Off

# Deshabilitar TRACE
TraceEnable Off

<IfModule !mod_headers.c>
    LoadModule headers_module modules/mod_headers.so
</IfModule>

<IfModule mod_headers.c>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set X-XSS-Protection "1; mode=block"
${hsts_block}
</IfModule>

<Directory "/var/www/html">
    <LimitExcept GET POST HEAD>
        Require all denied
    </LimitExcept>
</Directory>
APACHEEOF

    if [[ $? -eq 0 ]]; then
        msg_success "security.conf escrito"
        echo "    ServerTokens          -> Prod"
        echo "    ServerSignature       -> Off"
        echo "    TraceEnable           -> Off"
        echo "    X-Frame-Options       -> SAMEORIGIN"
        echo "    X-Content-Type-Options-> nosniff"
        echo "    Referrer-Policy       -> strict-origin-when-cross-origin"
        echo "    X-XSS-Protection      -> 1; mode=block"
        [[ -n "$hsts_block" ]] && \
            echo "    HSTS                  -> max-age=31536000 (SSL activo)"
        return 0
    else
        msg_error "No se pudo escribir security.conf"
        return 1
    fi
}

#
# _http_seguridad_nginx  (interna)
#
_http_seguridad_nginx() {
    msg_info "Aplicando security headers en Nginx..."
    echo ""

    http_crear_backup "$HTTP_CONF_NGINX"
    echo ""

    if sudo grep -q "server_tokens" "$HTTP_CONF_NGINX" 2>/dev/null; then
        sudo sed -i "s/server_tokens.*/server_tokens off;/" "$HTTP_CONF_NGINX"
        msg_success "server_tokens off: actualizado"
    else
        sudo sed -i "/^http {/a\\    server_tokens off;" "$HTTP_CONF_NGINX"
        msg_success "server_tokens off: agregado"
    fi

    _nginx_set_header() {
        local nombre="$1"
        local valor="$2"
        local directiva="    add_header ${nombre} \"${valor}\" always;"

        # Buscar en nginx.conf principal (bloque http {})
        if sudo grep -q "add_header ${nombre}" "$HTTP_CONF_NGINX" 2>/dev/null; then
            sudo sed -i "s|add_header ${nombre}.*|${directiva}|" "$HTTP_CONF_NGINX"
            msg_success "${nombre}: actualizado en nginx.conf"
        else
            sudo sed -i "/server_tokens off;/a\\${directiva}" "$HTTP_CONF_NGINX"
            msg_success "${nombre}: agregado en nginx.conf"
        fi

        # Si SSL activo, actualizar también en ssl-reprobados.conf
        local ssl_conf="/etc/nginx/conf.d/ssl-reprobados.conf"
        if [[ -f "$ssl_conf" ]]; then
            if sudo grep -q "add_header ${nombre}" "$ssl_conf" 2>/dev/null; then
                sudo sed -i "s|add_header ${nombre}.*|    ${directiva}|" "$ssl_conf"
            fi
        fi
    }

    echo ""
    _nginx_set_header "X-Frame-Options"        "SAMEORIGIN"
    _nginx_set_header "X-Content-Type-Options" "nosniff"
    _nginx_set_header "Referrer-Policy"        "strict-origin-when-cross-origin"
    _nginx_set_header "X-XSS-Protection"       "1; mode=block"
    echo ""

    if sudo nginx -t 2>/dev/null; then
        msg_success "Sintaxis de nginx.conf valida"
        return 0
    else
        msg_error "Error de sintaxis — restaurando backup"
        http_restaurar_backup "$HTTP_CONF_NGINX"
        return 1
    fi
}

#
# _http_seguridad_tomcat  (interna)
#
_http_seguridad_tomcat() {
    msg_info "Aplicando security headers en Tomcat..."
    echo ""

    local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
    local webxml="${catalina}/conf/web.xml"

    if [[ ! -f "$webxml" ]]; then
        msg_error "web.xml no encontrado: ${webxml}"
        return 1
    fi

    http_crear_backup "$webxml"
    echo ""

    sudo sed -i '/<!-- HTTP Security Headers Filter -->/,/<\/filter>/d' \
             "$webxml" 2>/dev/null
    sudo sed -i '/<!-- HTTP Security Headers Filter mapping -->/,/<\/filter-mapping>/d' \
             "$webxml" 2>/dev/null

    local linea_cierre
    linea_cierre=$(sudo grep -n "</web-app>" "$webxml" | tail -1 | cut -d: -f1)

    if [[ -z "$linea_cierre" ]]; then
        msg_error "Estructura web.xml invalida — falta </web-app>"
        http_restaurar_backup "$webxml"
        return 1
    fi

    sudo sed -i "${linea_cierre}i\\
\\
  <!-- HTTP Security Headers Filter -->\\
  <filter>\\
    <filter-name>httpHeaderSecurity</filter-name>\\
    <filter-class>org.apache.catalina.filters.HttpHeaderSecurityFilter</filter-class>\\
    <init-param><param-name>antiClickJackingEnabled</param-name><param-value>true</param-value></init-param>\\
    <init-param><param-name>antiClickJackingOption</param-name><param-value>SAMEORIGIN</param-value></init-param>\\
    <init-param><param-name>blockContentTypeSniffingEnabled</param-name><param-value>true</param-value></init-param>\\
    <init-param><param-name>xssProtectionEnabled</param-name><param-value>true</param-value></init-param>\\
    <init-param><param-name>hstsEnabled</param-name><param-value>true</param-value></init-param>\\
    <init-param><param-name>hstsMaxAgeSeconds</param-name><param-value>31536000</param-value></init-param>\\
  </filter>\\
  <!-- HTTP Security Headers Filter mapping -->\\
  <filter-mapping>\\
    <filter-name>httpHeaderSecurity</filter-name>\\
    <url-pattern>/*</url-pattern>\\
    <dispatcher>REQUEST</dispatcher>\\
  </filter-mapping>" "$webxml" 2>/dev/null

    msg_success "HttpHeaderSecurityFilter configurado en web.xml"
    echo "    X-Frame-Options        -> SAMEORIGIN"
    echo "    X-Content-Type-Options -> nosniff"
    echo "    X-XSS-Protection       -> activado"
    echo "    HSTS                   -> max-age=31536000 (si HTTPS activo)"
    return 0
}

#
# http_configurar_seguridad
#
http_configurar_seguridad() {
    clear
    draw_header "Configurar Security Headers"

    msg_info "Protege contra: Clickjacking, MIME sniffing, XSS, info leakage"
    echo ""

    local servicio
    if ! _http_seleccionar_servicio_instalado servicio; then
        return 1
    fi

    http_draw_servicio_header "$servicio" "Security Headers"

    # Advertir si SSL está activo — HSTS se preservará
    if _http_ssl_activo_para "$servicio"; then
        msg_info "SSL activo — el header HSTS se incluirá en security.conf"
        echo ""
    fi

    local resultado=0
    case "$servicio" in
        httpd)  _http_seguridad_apache || resultado=1 ;;
        nginx)  _http_seguridad_nginx  || resultado=1 ;;
        tomcat) _http_seguridad_tomcat || resultado=1 ;;
    esac

    (( resultado != 0 )) && return 1

    echo ""
    msg_info "Recargando servicio..."
    http_recargar_servicio "$servicio"
    echo ""

    # Verificar headers — usar HTTPS si SSL está activo
    local puerto_activo
    puerto_activo=$(_http_obtener_puerto_activo "$(http_nombre_systemd "$servicio")")

    if [[ -n "$puerto_activo" ]]; then
        local proto="http"
        local curl_opts="-I --max-time 5 --silent"
        if _http_ssl_activo_para "$servicio"; then
            proto="https"
            curl_opts="-Ik --max-time 5 --silent"
        fi
        msg_info "Headers presentes en respuesta ${proto^^} real:"
        echo ""
        curl $curl_opts "${proto}://localhost:${puerto_activo}" 2>/dev/null \
        | grep -E "^(Server|X-Frame|X-Content|X-XSS|Referrer|Strict)" \
        | sed 's/^/    /'
    fi

    echo ""
    separator
    msg_success "Security headers configurados correctamente"
}

#
# _http_metodos_apache  (interna)
#
_http_metodos_apache() {
    local metodos_permitidos="$1"

    msg_info "Configurando metodos HTTP en Apache..."
    echo ""

    http_crear_backup "$HTTP_CONF_APACHE_SECURITY"

    sudo sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/d' \
             "$HTTP_CONF_APACHE_SECURITY" 2>/dev/null

    sudo tee -a "$HTTP_CONF_APACHE_SECURITY" > /dev/null << EOF

# Control de metodos HTTP
<Directory "/var/www/html">
    <LimitExcept ${metodos_permitidos}>
        Require all denied
    </LimitExcept>
</Directory>
EOF

    msg_success "Metodos permitidos en Apache: ${metodos_permitidos}"
    return 0
}

#
# _http_metodos_nginx  (interna)
#
_http_metodos_nginx() {
    local metodos_bloqueados="$1"

    msg_info "Configurando metodos HTTP en Nginx..."
    echo ""

    http_crear_backup "$HTTP_CONF_NGINX"

    sudo sed -i '/# Control de metodos HTTP/,/^        }$/d' \
             "$HTTP_CONF_NGINX" 2>/dev/null

    sudo sed -i "/location \//i\\        # Control de metodos HTTP\\n        if (\$request_method ~ ^(${metodos_bloqueados})\$) {\\n            return 405;\\n        }" \
             "$HTTP_CONF_NGINX" 2>/dev/null

    # Si SSL activo, aplicar también en ssl-reprobados.conf
    local ssl_conf="/etc/nginx/conf.d/ssl-reprobados.conf"
    if [[ -f "$ssl_conf" ]]; then
        http_crear_backup "$ssl_conf"
        sudo sed -i '/# Control de metodos HTTP/,/^        }$/d' "$ssl_conf" 2>/dev/null
        sudo sed -i "/location \//i\\        # Control de metodos HTTP\\n        if (\$request_method ~ ^(${metodos_bloqueados})\$) {\\n            return 405;\\n        }" \
                 "$ssl_conf" 2>/dev/null
        msg_success "Metodos bloqueados aplicados tambien en ssl-reprobados.conf"
    fi

    if sudo nginx -t 2>/dev/null; then
        msg_success "Metodos bloqueados en Nginx: ${metodos_bloqueados}"
        return 0
    else
        msg_error "Error de sintaxis — restaurando nginx.conf"
        http_restaurar_backup "$HTTP_CONF_NGINX"
        return 1
    fi
}

#
# _http_metodos_tomcat  (interna)
#
_http_metodos_tomcat() {
    local metodos_bloqueados_str="$1"

    msg_info "Configurando metodos HTTP en Tomcat..."
    echo ""

    local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
    local webxml="${catalina}/conf/web.xml"

    [[ ! -f "$webxml" ]] && {
        msg_error "web.xml no encontrado: ${webxml}"
        return 1
    }

    http_crear_backup "$webxml"

    sudo sed -i '/<!-- HTTP Method Restriction -->/,/<\/security-constraint>/d' \
             "$webxml" 2>/dev/null

    local metodos_xml=""
    local metodo
    for metodo in $metodos_bloqueados_str; do
        metodos_xml+="      <http-method-omission>${metodo}</http-method-omission>\n"
    done

    local linea_cierre
    linea_cierre=$(sudo grep -n "</web-app>" "$webxml" | tail -1 | cut -d: -f1)

    if [[ -z "$linea_cierre" ]]; then
        msg_error "web.xml invalido — falta </web-app>"
        http_restaurar_backup "$webxml"
        return 1
    fi

    sudo sed -i "${linea_cierre}i\\
\\
  <!-- HTTP Method Restriction -->\\
  <security-constraint>\\
    <web-resource-collection>\\
      <web-resource-name>Metodos Restringidos</web-resource-name>\\
      <url-pattern>/*</url-pattern>\\
$(printf "%b" "$metodos_xml")    </web-resource-collection>\\
    <auth-constraint/>\\
  </security-constraint>" "$webxml" 2>/dev/null

    msg_success "Metodos bloqueados en Tomcat: ${metodos_bloqueados_str}"
    return 0
}

#
# http_restringir_metodos
#
http_restringir_metodos() {
    clear
    draw_header "Control de Metodos HTTP"

    msg_info "Metodos peligrosos a restringir:"
    echo "    TRACE  — Refleja la peticion (facilita XST)"
    echo "    TRACK  — Variante de TRACE en IIS"
    echo "    DELETE — Puede eliminar recursos"
    echo "    PUT    — Puede subir archivos arbitrarios"
    echo ""

    local servicio
    if ! _http_seleccionar_servicio_instalado servicio; then
        return 1
    fi

    http_draw_servicio_header "$servicio" "Control de Metodos HTTP"

    msg_info "Perfiles de restriccion:"
    echo ""
    echo -e "  ${BLUE}1)${NC} Recomendado  — Bloquea: TRACE, TRACK"
    echo -e "  ${BLUE}2)${NC} Estricto     — Bloquea: TRACE, TRACK, DELETE, PUT, PATCH"
    echo -e "  ${BLUE}3)${NC} Personalizado — Ingresar manualmente"
    echo ""

    local perfil
    while true; do
        input_read "Seleccione perfil [1-3]" perfil
        if http_validar_opcion_menu "$perfil" "3"; then
            break
        fi
        echo ""
    done

    echo ""

    local metodos_bloquear metodos_permitir
    case "$perfil" in
        1)
            metodos_bloquear="TRACE TRACK"
            metodos_permitir="GET POST HEAD OPTIONS PUT DELETE"
            ;;
        2)
            metodos_bloquear="TRACE TRACK DELETE PUT PATCH"
            metodos_permitir="GET POST HEAD"
            ;;
        3)
            msg_info "Metodos disponibles: TRACE TRACK DELETE PUT PATCH OPTIONS CONNECT"
            msg_info "Ingrese los metodos a bloquear separados por espacio (MAYUSCULAS)"
            echo ""
            local entrada_metodos
            input_read "Metodos a bloquear" entrada_metodos

            if [[ -z "$entrada_metodos" ]]; then
                msg_error "Debe ingresar al menos un metodo"
                return 1
            fi

            local metodos_validos=""
            local m
            for m in $entrada_metodos; do
                if http_validar_metodo_http "$m"; then
                    metodos_validos="${metodos_validos} ${m^^}"
                else
                    msg_alert "Metodo ignorado: $m"
                fi
            done

            metodos_bloquear="${metodos_validos# }"
            if [[ -z "$metodos_bloquear" ]]; then
                msg_error "Ningun metodo valido ingresado"
                return 1
            fi
            metodos_permitir="GET POST HEAD (resto no bloqueado)"
            ;;
    esac

    separator
    msg_info "Configuracion a aplicar:"
    echo "    Servicio          : ${servicio}"
    echo "    Metodos bloqueados: ${metodos_bloquear}"
    echo "    Metodos permitidos: ${metodos_permitir}"
    echo ""

    local confirmacion
    while true; do
        input_read "Confirmar? [s/n]" confirmacion
        http_validar_confirmacion "$confirmacion"
        local rc=$?
        (( rc == 0 )) && break
        (( rc == 1 )) && { msg_info "Operacion cancelada"; sleep 1; return 0; }
        echo ""
    done

    echo ""

    local resultado=0
    case "$servicio" in
        httpd)
            _http_metodos_apache "$metodos_permitir" || resultado=1
            ;;
        nginx)
            local metodos_regex
            metodos_regex=$(echo "$metodos_bloquear" | tr ' ' '|')
            _http_metodos_nginx "$metodos_regex" || resultado=1
            ;;
        tomcat)
            _http_metodos_tomcat "$metodos_bloquear" || resultado=1
            ;;
    esac

    (( resultado != 0 )) && return 1

    echo ""
    msg_info "Recargando servicio..."
    http_recargar_servicio "$servicio"

    echo ""
    separator
    msg_success "Control de metodos HTTP aplicado correctamente"
}

#
# http_menu_configurar
#
http_menu_configurar() {
    while true; do
        clear
        draw_header "Configurar Servicio HTTP"
        echo ""
        echo -e "  ${BLUE}1)${NC} Cambiar puerto de escucha"
        echo -e "  ${BLUE}2)${NC} Configurar security headers"
        echo -e "  ${BLUE}3)${NC} Control de metodos HTTP"
        echo -e "  ${BLUE}4)${NC} Gestion de versiones (upgrade / downgrade)"
        echo -e "  ${BLUE}5)${NC} Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) http_cambiar_puerto;       echo ""; msg_pause ;;
            2) http_configurar_seguridad; echo ""; msg_pause ;;
            3) http_restringir_metodos;   echo ""; msg_pause ;;
            4) http_menu_versiones ;;
            5) return 0 ;;
            *) msg_error "Opcion invalida. Seleccione entre 1 y 5"; sleep 2 ;;
        esac
    done
}

export -f http_cambiar_puerto
export -f http_configurar_seguridad
export -f http_restringir_metodos
export -f http_menu_configurar
export -f _http_seleccionar_servicio_instalado
export -f _http_actualizar_firewall_puerto
export -f _http_leer_puerto_config
export -f _http_ssl_activo_para
export -f _http_seguridad_apache
export -f _http_seguridad_nginx
export -f _http_seguridad_tomcat
export -f _http_metodos_apache
export -f _http_metodos_nginx
export -f _http_metodos_tomcat