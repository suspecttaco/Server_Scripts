#!/bin/bash
# =============================================================================
# ws_lib/ws_config.sh — Configuración y seguridad de servicios web
# Requiere: source lib/ui.sh, source ws_lib/ws_utils.sh, source ws_lib/ws_validators.sh
#           source ws_lib/ws_status.sh, source ws_lib/ws_install.sh
# =============================================================================

#
# _http_seleccionar_servicio_instalado  (interna)
# Muestra solo los servicios que están actualmente instalados.
# Retorna el nombre interno en la variable $1 o 1 si ninguno está instalado.
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
# Lee el puerto del archivo de configuración sin depender de que el servicio
# esté corriendo. Devuelve el número o cadena vacía.
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
# Abre el puerto nuevo y cierra el viejo si ya no lo usa nadie.
#
_http_actualizar_firewall_puerto() {
    local puerto_nuevo="$1"
    local puerto_viejo="$2"

    msg_info "Actualizando reglas de firewall..."
    echo ""

    # Abrir el puerto nuevo
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

    # Cerrar el puerto viejo solo si no lo usa nadie más
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
# http_cambiar_puerto
#
# Edge case completo de cambio de puerto con rollback automático.
# Secuencia:
#   1. Seleccionar servicio instalado
#   2. Detectar puerto actual desde el archivo de config
#   3. Solicitar nuevo puerto (http_validar_puerto_cambio)
#   4. Backup del archivo de config
#   5. Editar el archivo (reutiliza _http_configurar_puerto_inicial del Grupo B)
#   6. Restart del servicio (restart — el socket debe re-abrirse)
#   7. Verificar respuesta HTTP en el nuevo puerto (curl -I)
#   8. Si falla → restaurar backup + restart
#   9. Si pasa → actualizar firewall + index.html
#
http_cambiar_puerto() {
    clear
    draw_header "Cambiar Puerto de Servicio HTTP"

    # Paso 1: Servicio instalado
    local servicio
    if ! _http_seleccionar_servicio_instalado servicio; then
        return 1
    fi

    http_draw_servicio_header "$servicio" "Cambio de Puerto"

    # Paso 2: Puerto actual desde el archivo de config
    local puerto_actual
    puerto_actual=$(_http_leer_puerto_config "$servicio")

    if [[ -z "$puerto_actual" ]]; then
        msg_alert "No se pudo detectar el puerto actual automaticamente"
        case "$servicio" in
            httpd)  puerto_actual="$HTTP_PUERTO_DEFAULT_APACHE" ;;
            nginx)  puerto_actual="$HTTP_PUERTO_DEFAULT_NGINX"  ;;
            tomcat) puerto_actual="$HTTP_PUERTO_DEFAULT_TOMCAT" ;;
        esac
        msg_info "Usando puerto por defecto: ${puerto_actual}"
    else
        msg_info "Puerto actual configurado: ${puerto_actual}/tcp"
    fi

    echo ""
    http_listar_puertos_activos
    echo ""

    # Paso 3: Nuevo puerto
    local puerto_nuevo
    while true; do
        input_read "Nuevo puerto [actual: ${puerto_actual}]" puerto_nuevo
        if [[ -z "$puerto_nuevo" ]]; then
            msg_error "Debe ingresar un numero de puerto"
            echo ""
            continue
        fi
        if http_validar_puerto_cambio "$puerto_nuevo" "$puerto_actual"; then
            break
        fi
        echo ""
    done

    echo ""
    msg_alert "Se modificara la configuracion de ${servicio}:"
    echo "    Puerto actual : ${puerto_actual}/tcp"
    echo "    Puerto nuevo  : ${puerto_nuevo}/tcp"
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

    # Paso 4: Backup
    local archivo_conf
    archivo_conf=$(http_get_conf_archivo "$servicio")

    msg_info "PASO 1/5 — Backup de configuracion"
    if ! http_crear_backup "$archivo_conf"; then
        msg_error "No se pudo crear backup — operacion cancelada por seguridad"
        return 1
    fi
    echo ""

    # Paso 5: Editar archivo (reutiliza función del Grupo B)
    msg_info "PASO 2/5 — Aplicando nuevo puerto en ${archivo_conf}"
    _http_configurar_puerto_inicial "$servicio" "$puerto_nuevo"
    echo ""

    # Paso 6: Restart (no reload — el socket cambia de puerto)
    msg_info "PASO 3/5 — Reiniciando servicio para aplicar nuevo puerto"
    if ! http_reiniciar_servicio "$servicio"; then
        msg_error "El servicio no levanto — restaurando configuracion anterior"
        http_restaurar_backup "$archivo_conf"
        http_reiniciar_servicio "$servicio"
        return 1
    fi
    echo ""

    # Paso 7: Verificar respuesta en el nuevo puerto
    msg_info "PASO 4/5 — Verificando respuesta HTTP en puerto ${puerto_nuevo}"
    sleep 2

    if ! http_verificar_respuesta "$servicio" "$puerto_nuevo"; then
        msg_error "Sin respuesta en puerto ${puerto_nuevo} — restaurando"
        http_restaurar_backup "$archivo_conf"
        http_reiniciar_servicio "$servicio"
        msg_info "Configuracion restaurada al puerto ${puerto_actual}"
        return 1
    fi
    echo ""

    # Paso 8: Firewall
    msg_info "PASO 5/5 — Actualizando reglas de firewall"
    _http_actualizar_firewall_puerto "$puerto_nuevo" "$puerto_actual"
    echo ""

    # Paso 9: Actualizar index.html
    local version_actual
    version_actual=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" \
                     "$(http_nombre_paquete "$servicio")" 2>/dev/null)
    http_crear_index "$servicio" "$version_actual" "$puerto_nuevo"

    echo ""
    separator
    msg_success "Puerto cambiado exitosamente: ${puerto_actual} → ${puerto_nuevo}"
    separator
}

#
# _http_seguridad_apache  (interna)
# Escribe security.conf completo con ServerTokens, ServerSignature y headers.
#
_http_seguridad_apache() {
    msg_info "Aplicando security headers en Apache..."
    echo ""

    http_crear_backup "$HTTP_CONF_APACHE_SECURITY"
    echo ""

    sudo tee "$HTTP_CONF_APACHE_SECURITY" > /dev/null << 'APACHEEOF'
# security.conf — Generado por http_functions_C.sh

# Ocultar version del servidor en headers HTTP
ServerTokens Prod
ServerSignature Off

# Deshabilitar TRACE a nivel de servidor — previene Cross-Site Tracing (XST)
# LimitExcept NO bloquea TRACE porque Apache lo procesa antes de evaluar Directory
# TraceEnable es la unica directiva que opera a nivel mod_core
TraceEnable Off

# Activar mod_headers si no esta cargado
# (requerido para las directivas Header always set)
<IfModule !mod_headers.c>
    LoadModule headers_module modules/mod_headers.so
</IfModule>

# Security Headers — aplicados a todas las respuestas
<IfModule mod_headers.c>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set X-XSS-Protection "1; mode=block"
</IfModule>

# Control de metodos HTTP
# <LimitExcept> requiere contexto Directory/Location — se aplica al webroot
# http_restringir_metodos() sobreescribe este bloque con la seleccion del usuario
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
        echo "    TraceEnable           -> Off (anti-XST)"
        echo "    X-Frame-Options       -> SAMEORIGIN"
        echo "    X-Content-Type-Options-> nosniff"
        echo "    Referrer-Policy       -> strict-origin-when-cross-origin"
        echo "    X-XSS-Protection      -> 1; mode=block"
        return 0
    else
        msg_error "No se pudo escribir security.conf"
        return 1
    fi
}

#
# _http_seguridad_nginx  (interna)
# server_tokens off + add_header en bloque http {} de nginx.conf.
#
_http_seguridad_nginx() {
    msg_info "Aplicando security headers en Nginx..."
    echo ""

    http_crear_backup "$HTTP_CONF_NGINX"
    echo ""

    # server_tokens off
    if sudo grep -q "server_tokens" "$HTTP_CONF_NGINX" 2>/dev/null; then
        sudo sed -i "s/server_tokens.*/server_tokens off;/" "$HTTP_CONF_NGINX"
        msg_success "server_tokens off: actualizado"
    else
        sudo sed -i "/^http {/a\\    server_tokens off;" "$HTTP_CONF_NGINX"
        msg_success "server_tokens off: agregado"
    fi

    # Función local para insertar/actualizar un add_header en nginx.conf
    _nginx_set_header() {
        local nombre="$1"
        local valor="$2"
        local directiva="    add_header ${nombre} \"${valor}\" always;"
        if sudo grep -q "add_header ${nombre}" "$HTTP_CONF_NGINX" 2>/dev/null; then
            sudo sed -i "s|add_header ${nombre}.*|${directiva}|" "$HTTP_CONF_NGINX"
            msg_success "${nombre}: actualizado"
        else
            sudo sed -i "/server_tokens off;/a\\${directiva}" "$HTTP_CONF_NGINX"
            msg_success "${nombre}: agregado"
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
# HttpHeaderSecurityFilter en web.xml para X-Frame-Options, nosniff, XSS.
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

    # Eliminar filtro anterior si ya existe
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

    # Insertar el filtro antes de </web-app>
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
    return 0
}

#
# http_configurar_seguridad
# Orquesta la aplicación de security headers para el servicio seleccionado.
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

    # Verificar headers reales con curl
    local puerto_activo
    puerto_activo=$(_http_obtener_puerto_activo "$(http_nombre_systemd "$servicio")")

    if [[ -n "$puerto_activo" ]]; then
        msg_info "Headers presentes en respuesta HTTP real:"
        echo ""
        curl -I --max-time 5 --silent "http://localhost:${puerto_activo}" \
             2>/dev/null \
        | grep -E "^(Server|X-Frame|X-Content|X-XSS|Referrer)" \
        | sed 's/^/    /'
    fi

    echo ""
    separator
    msg_success "Security headers configurados correctamente"
}

#
# _http_metodos_apache  (interna)
# LimitExcept en security.conf — permite los métodos listados, bloquea el resto.
#
_http_metodos_apache() {
    local metodos_permitidos="$1"

    msg_info "Configurando metodos HTTP en Apache..."
    echo ""

    http_crear_backup "$HTTP_CONF_APACHE_SECURITY"

    # Eliminar bloque Directory+LimitExcept anterior completo
    sudo sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/d' \
             "$HTTP_CONF_APACHE_SECURITY" 2>/dev/null

    # Agregar bloque actualizado — LimitExcept DEBE estar dentro de Directory
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
# Bloque if ($request_method) en nginx.conf — devuelve 405 para bloqueados.
#
_http_metodos_nginx() {
    local metodos_bloqueados="$1"

    msg_info "Configurando metodos HTTP en Nginx..."
    echo ""

    http_crear_backup "$HTTP_CONF_NGINX"

    # Eliminar bloque anterior si existe
    sudo sed -i '/# Control de metodos HTTP/,/^        }$/d' \
             "$HTTP_CONF_NGINX" 2>/dev/null

    # Insertar antes del primer bloque location
    sudo sed -i "/location \//i\\        # Control de metodos HTTP\\n        if (\$request_method ~ ^(${metodos_bloqueados})\$) {\\n            return 405;\\n        }" \
             "$HTTP_CONF_NGINX" 2>/dev/null

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
# security-constraint en web.xml con http-method-omission.
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

    # Construir líneas de http-method-omission
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
# Menú con perfiles: Recomendado, Estricto, Personalizado.
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
# Submenú del Grupo C. Opción 3 del menú principal.
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
            1) http_cambiar_puerto;      echo ""; msg_pause ;;
            2) http_configurar_seguridad; echo ""; msg_pause ;;
            3) http_restringir_metodos;  echo ""; msg_pause ;;
            4) http_menu_versiones ;;
            5) return 0 ;;
            *) msg_error "Opcion invalida. Seleccione entre 1 y 5"; sleep 2 ;;
        esac
    done
}

#
#   EXPORTAR FUNCIONES DEL GRUPO C
#

export -f http_cambiar_puerto
export -f http_configurar_seguridad
export -f http_restringir_metodos
export -f http_menu_configurar
export -f _http_seleccionar_servicio_instalado
export -f _http_actualizar_firewall_puerto
export -f _http_leer_puerto_config
export -f _http_seguridad_apache
export -f _http_seguridad_nginx
export -f _http_seguridad_tomcat
export -f _http_metodos_apache
export -f _http_metodos_nginx
export -f _http_metodos_tomcat