#!/bin/bash
# =============================================================================
# ws_lib/ws_install.sh — Instalación de servicios web
# Requiere: source lib/ui.sh, source ws_lib/ws_utils.sh, source ws_lib/ws_validators.sh
#           source ws_lib/ws_status.sh
# =============================================================================

# -----------------------------------------------------------------------------
# _http_ssl_hook
#
# Pregunta al usuario si desea activar SSL/TLS en el servicio recién instalado
# o reconfigurado. No es fatal: si se rechaza o ssl_lib no está disponible,
# el servicio sigue funcionando en HTTP plano.
#
# $1 = nombre interno del servicio (httpd | nginx | tomcat)
# $2 = contexto: "post_install" | "post_reconfig"
# -----------------------------------------------------------------------------
_http_ssl_hook() {
    local servicio="$1"
    local contexto="${2:-post_install}"
    local _ssl_lib="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/ssl_lib/ssl.sh"

    echo ""
    separator
    msg_info "Configuracion SSL/TLS — ${servicio}"
    separator
    echo ""
    msg_input "¿Desea activar SSL/TLS en ${servicio} ahora? [S/N]: "
    read -r _resp_ssl

    if [[ ! "${_resp_ssl^^}" =~ ^(S|SI|Y|YES)$ ]]; then
        msg_info "SSL omitido. Puede activarlo despues desde ws_manager.sh → opcion 6"
        return 0
    fi

    if [[ ! -f "$_ssl_lib" ]]; then
        msg_error "ssl_lib/ssl.sh no encontrado en: ${_ssl_lib}"
        msg_info  "Copie ssl_lib/ en el directorio raiz del proyecto para habilitar SSL"
        return 0
    fi

    if source "$_ssl_lib" 2>/dev/null; then
        case "$servicio" in
            httpd|apache) ssl_configurar_apache  || msg_alert "SSL para Apache no se completo — revise los logs" ;;
            nginx)        ssl_configurar_nginx   || msg_alert "SSL para Nginx no se completo — revise los logs" ;;
            tomcat)       ssl_configurar_tomcat  || msg_alert "SSL para Tomcat no se completo — revise los logs" ;;
            *)            msg_alert "Servicio '${servicio}' no tiene modulo SSL disponible" ;;
        esac

        # Actualizar index.html con ambos puertos si SSL se configuró correctamente
        if [[ -n "${_SSL_LAST_HTTPS_PORT:-}" && -n "${_SSL_LAST_HTTP_PORT:-}" ]]; then
            local _version
            _version=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}"                        "$(http_nombre_paquete "$servicio")" 2>/dev/null)
            http_crear_index "$servicio" "$_version"                              "$_SSL_LAST_HTTP_PORT" "$_SSL_LAST_HTTPS_PORT"                 2>/dev/null || true
            msg_success "index.html actualizado con puertos HTTP y HTTPS"
            unset _SSL_LAST_HTTP_PORT _SSL_LAST_HTTPS_PORT
        fi
    else
        msg_error "No se pudo cargar ssl_lib — SSL omitido"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# http_seleccionar_servicio
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# _http_seleccionar_fuente
#
# Pregunta al usuario si desea instalar desde Internet (dnf) o desde el
# repositorio FTP local. Retorna "internet" o "ftp" en la variable destino.
# -----------------------------------------------------------------------------
_http_seleccionar_fuente() {
    local _var="$1"
    echo ""
    separator
    msg_info "Fuente de instalación"
    separator
    echo ""
    echo -e "  ${BLUE}1)${NC} Internet — repositorio oficial (dnf)"
    echo -e "  ${BLUE}2)${NC} Repositorio FTP local"
    echo ""
    local sel
    while true; do
        msg_input "Seleccione fuente [1/2, Enter=1]: "; read -r sel
        [[ -z "$sel" ]] && sel="1"
        case "$sel" in
            1) printf -v "$_var" "internet"; return 0 ;;
            2) printf -v "$_var" "ftp";      return 0 ;;
            *) msg_error "Ingrese 1 o 2" ;;
        esac
    done
}

http_seleccionar_servicio() {
    local _var_destino="$1"

    clear
    http_draw_servicio_header "Selector de Servicio" "Paso 1 de 4"

    msg_info "Servicios HTTP disponibles en Fedora Server:"
    echo ""
    echo -e "  ${BLUE}1)${NC} Apache (httpd)"
    echo "      Servidor web clasico. Modular, ampliamente documentado."
    echo "      Paquete dnf: httpd  |  Usuario: apache  |  Puerto default: 80"
    echo ""
    echo -e "  ${BLUE}2)${NC} Nginx"
    echo "      Servidor web / proxy inverso de alto rendimiento."
    echo "      Paquete dnf: nginx  |  Usuario: nginx   |  Puerto default: 80"
    echo ""
    echo -e "  ${BLUE}3)${NC} Tomcat"
    echo "      Servidor de aplicaciones Java (Jakarta EE / Servlets)."
    echo "      Requiere JDK instalado. Puerto default: 8080"
    echo ""

    local opcion
    while true; do
        input_read "Seleccione el servicio [1-3]" opcion

        if ! http_validar_opcion_menu "$opcion" "3"; then
            echo ""
            continue
        fi

        local nombre_servicio
        case "$opcion" in
            1) nombre_servicio="httpd"  ;;
            2) nombre_servicio="nginx"  ;;
            3) nombre_servicio="tomcat" ;;
        esac

        local paquete
        paquete=$(http_nombre_paquete "$nombre_servicio")

        if rpm -q "$paquete" &>/dev/null; then
            local version_actual
            version_actual=$(rpm -q --queryformat "%{VERSION}" "$paquete" 2>/dev/null)
            echo ""
            msg_alert "El servicio '$nombre_servicio' ya esta instalado (v${version_actual})"
            echo ""
            echo "  Opciones:"
            echo "    1) Reinstalar (desinstala primero y vuelve a instalar)"
            echo "    2) Solo reconfigurar (omite instalacion, va directo a config)"
            echo "    3) Cancelar"
            echo ""

            local op_reinstalar
            input_read "Seleccione [1-3]" op_reinstalar

            case "$op_reinstalar" in
                1)
                    printf -v "$_var_destino" "reinstalar:${nombre_servicio}"
                    return 0
                    ;;
                2)
                    printf -v "$_var_destino" "reconfigurar:${nombre_servicio}"
                    return 0
                    ;;
                3|*)
                    printf -v "$_var_destino" "cancelar"
                    return 0
                    ;;
            esac
        fi

        printf -v "$_var_destino" "$nombre_servicio"
        return 0
    done
}

# -----------------------------------------------------------------------------
# http_consultar_versiones
# -----------------------------------------------------------------------------
http_consultar_versiones() {
    local servicio="$1"
    local _array_destino="$2"

    local paquete
    paquete=$(http_nombre_paquete "$servicio")

    msg_info "Consultando versiones disponibles de '${paquete}' en repositorios..."
    echo ""

    local versiones_raw
    versiones_raw=$(dnf repoquery \
                        --arch "$(uname -m)" \
                        --showduplicates \
                        --queryformat "%{version}-%{release}" \
                        "$paquete" 2>/dev/null \
                    | grep -v "^$" \
                    | sort -Vr \
                    | uniq)

    if [[ -z "$versiones_raw" ]]; then
        versiones_raw=$(dnf list --showduplicates "$paquete" 2>/dev/null \
                        | grep "^${paquete}" \
                        | awk '{print $2}' \
                        | sort -Vr \
                        | uniq)
    fi

    if rpm -q "$paquete" &>/dev/null; then
        local version_instalada
        version_instalada=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" \
                            "$paquete" 2>/dev/null)
        if [[ -n "$version_instalada" ]] && \
           ! echo "$versiones_raw" | grep -qF "$version_instalada"; then
            versiones_raw="${version_instalada}"$'\n'"${versiones_raw}"
            versiones_raw=$(echo "$versiones_raw" | grep -v "^$" | sort -Vr | uniq)
        fi
    fi

    if [[ -z "$versiones_raw" ]]; then
        msg_alert "No se encontraron versiones para '${paquete}' en los repositorios"
        return 1
    fi

    local versiones_array=()
    while IFS= read -r linea; do
        [[ -n "$linea" ]] && versiones_array+=("$linea")
    done <<< "$versiones_raw"

    local -n _ref_array="$_array_destino"
    _ref_array=("${versiones_array[@]}")

    msg_success "Se encontraron ${#versiones_array[@]} version(es) disponible(s)"
    return 0
}

# -----------------------------------------------------------------------------
# http_seleccionar_version
# -----------------------------------------------------------------------------
http_seleccionar_version() {
    local servicio="$1"
    local _nombre_array="$2"
    local _var_version="$3"

    local -n _versiones_ref="$_nombre_array"
    local total="${#_versiones_ref[@]}"

    clear
    http_draw_servicio_header "Selector de Version — ${servicio}" "Paso 2 de 4"

    msg_info "Versiones disponibles en repositorios (orden: mas reciente primero):"
    echo ""
    printf "  %-5s %-35s %-12s\n" "NUM" "VERSION" "ETIQUETA"
    separator

    local i
    for i in "${!_versiones_ref[@]}"; do
        local num=$(( i + 1 ))
        local ver="${_versiones_ref[$i]}"
        local etiqueta=""

        if (( total == 1 )); then
            etiqueta="${GREEN}Latest${NC} / ${BLUE}Stable${NC}"
        elif (( i == 0 )); then
            etiqueta="${GREEN}Latest${NC}   — mas reciente, desarrollo activo"
        elif (( i == 1 && total >= 3 )); then
            etiqueta="${CYAN}Reciente${NC}  — un ciclo anterior, probada"
        elif (( i == total - 1 )); then
            etiqueta="${BLUE}Stable${NC}   — mayor tiempo en produccion"
        else
            local ciclos_atras=$(( i ))
            etiqueta="${GRAY}Anterior${NC}  — ${ciclos_atras} version(es) atras"
        fi

        printf "  %-5s %-38s " "$num)" "$ver"
        echo -e "$etiqueta"
    done

    echo ""

    local indice_elegido
    while true; do
        input_read "Seleccione el numero de version [1-${total}]" indice_elegido
        if http_validar_indice_version "$indice_elegido" "$total"; then
            break
        fi
        echo ""
    done

    local idx=$(( indice_elegido - 1 ))
    local version_final="${_versiones_ref[$idx]}"

    printf -v "$_var_version" "%s" "$version_final"

    echo ""
    msg_success "Version seleccionada: ${version_final}"
    return 0
}

# -----------------------------------------------------------------------------
# http_seleccionar_puerto
# -----------------------------------------------------------------------------
http_seleccionar_puerto() {
    local servicio="$1"
    local _var_puerto="$2"
    local _paso_label="${3:-Paso 3 de 4}"   # $3 opcional para FTP (Paso 2 de 3, etc.)

    clear
    http_draw_servicio_header "Selector de Puerto — ${servicio}" "$_paso_label"

    local puerto_default
    case "$servicio" in
        httpd|apache) puerto_default="$HTTP_PUERTO_DEFAULT_APACHE" ;;
        nginx)        puerto_default="$HTTP_PUERTO_DEFAULT_NGINX"  ;;
        tomcat)       puerto_default="$HTTP_PUERTO_DEFAULT_TOMCAT" ;;
        *)            puerto_default="80" ;;
    esac

    msg_info "Puertos comunes para servicios HTTP:"
    echo "    80   — HTTP estandar (requiere root)"
    echo "    8080 — Alternativa HTTP (Tomcat default)"
    echo "    8888 — Puerto de pruebas comun"
    echo "    443  — HTTPS (requiere certificado SSL)"
    echo ""
    msg_info "Puerto por defecto para ${servicio}: ${puerto_default}"
    echo ""

    http_listar_puertos_activos
    echo ""

    local _puerto_sel="$puerto_default"
    while true; do
        input_read "Puerto de escucha [Enter = ${puerto_default}]" _puerto_sel
        [[ -z "$_puerto_sel" ]] && _puerto_sel="$puerto_default"
        if http_validar_puerto "$_puerto_sel"; then
            break
        fi
        _puerto_sel="$puerto_default"
        echo ""
    done

    printf -v "$_var_puerto" "%s" "$_puerto_sel"

    echo ""
    msg_success "Puerto seleccionado: ${_puerto_sel}/tcp"
    return 0
}

# -----------------------------------------------------------------------------
# _http_instalar_paquete  (interna)
# -----------------------------------------------------------------------------
_http_instalar_paquete() {
    local paquete="$1"
    local version="$2"

    local _version_inst="$version"
    if [[ "$version" != *".fc"* && "$version" != *".el"* ]]; then
        local _dist_tag
        _dist_tag=$(rpm --eval "%{dist}" 2>/dev/null | tr -d '\n')
        [[ -n "$_dist_tag" ]] && _version_inst="${version}${_dist_tag}"
    fi
    local paquete_version="${paquete}-${_version_inst}"

    msg_info "Instalando: ${paquete_version}"
    msg_info "Comando: sudo dnf install -y ${paquete_version}"
    echo ""

    if sudo dnf install -y --best "${paquete_version}" &>/dev/null \
       | while IFS= read -r linea; do echo "    $linea"; done; then

        if rpm -q "$paquete" &>/dev/null; then
            local version_instalada
            version_instalada=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" "$paquete")
            msg_success "Instalado correctamente: ${paquete} v${version_instalada}"
            return 0
        else
            msg_error "dnf reporto exito pero el paquete no aparece instalado"
            return 1
        fi
    else
        msg_error "Error durante la instalacion de ${paquete_version}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# http_crear_usuario_dedicado
# -----------------------------------------------------------------------------
http_crear_usuario_dedicado() {
    local usuario="$1"
    local webroot="$2"

    msg_info "Configurando usuario dedicado: ${usuario}"
    echo ""

    if id "$usuario" &>/dev/null; then
        msg_success "Usuario '${usuario}' ya existe (creado por el paquete)"

        local shell_actual
        shell_actual=$(getent passwd "$usuario" | cut -d: -f7)

        if [[ "$shell_actual" != "/sbin/nologin" && "$shell_actual" != "/bin/false" ]]; then
            msg_alert "Shell interactiva detectada en '${usuario}' — corrigiendo..."
            sudo usermod -s /sbin/nologin "$usuario"
            msg_success "Shell cambiada a /sbin/nologin"
        else
            msg_success "Sin shell interactiva — correcto"
        fi

    else
        msg_info "Creando usuario del sistema '${usuario}'..."

        if sudo useradd -r -s /sbin/nologin -d /dev/null \
                        -c "Usuario del servicio ${usuario}" "$usuario" 2>/dev/null; then
            msg_success "Usuario '${usuario}' creado correctamente"
        else
            msg_error "No se pudo crear el usuario '${usuario}'"
            return 1
        fi
    fi

    echo ""

    if [[ ! -d "$webroot" ]]; then
        msg_info "Creando directorio webroot: ${webroot}"
        sudo mkdir -p "$webroot"
    fi

    sudo chown root:root "$webroot"
    sudo chmod 755 "$webroot"

    sudo find "$webroot" -type f -exec sudo chmod 644 {} \; 2>/dev/null
    sudo find "$webroot" -type d -exec sudo chmod 755 {} \; 2>/dev/null

    msg_success "Permisos aplicados en webroot: ${webroot}"
    return 0
}

# -----------------------------------------------------------------------------
# http_crear_index
# -----------------------------------------------------------------------------
http_crear_index() {
    local servicio="$1"
    local version="$2"
    local puerto_http="$3"
    local puerto_https="${4:-}"   # opcional — se rellena si SSL está activo

    local webroot
    webroot=$(http_get_webroot "$servicio")

    local nombre_display
    case "$servicio" in
        httpd)  nombre_display="Apache HTTP Server" ;;
        nginx)  nombre_display="Nginx"              ;;
        tomcat) nombre_display="Apache Tomcat"      ;;
        *)      nombre_display="$servicio"          ;;
    esac

    # Construir filas de puertos según si SSL está activo
    local fila_http fila_https
    if [[ -n "$puerto_https" ]]; then
        fila_http="<tr><td>Puerto HTTP</td>  <td>${puerto_http}/tcp &rarr; redirect HTTPS</td></tr>"
        fila_https="<tr><td>Puerto HTTPS</td> <td style=\"color:#2a7;font-weight:bold\">${puerto_https}/tcp (SSL activo)</td></tr>"
    else
        fila_http="<tr><td>Puerto</td> <td>${puerto_http}/tcp</td></tr>"
        fila_https=""
    fi

    msg_info "Generando index.html en ${webroot}..."

sudo tee "${webroot}/index.html" > /dev/null << EOF
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>${nombre_display}</title>
    <style>
        body { font-family: sans-serif; max-width: 500px; margin: 60px auto; color: #222; }
        h1   { border-bottom: 2px solid #222; padding-bottom: 8px; }
        td   { padding: 6px 16px 6px 0; }
        td:first-child { font-weight: bold; color: #555; }
    </style>
</head>
<body>
    <h1>${nombre_display}</h1>
    <table>
        <tr><td>Version</td> <td>${version}</td></tr>
        ${fila_http}
        ${fila_https}
        <tr><td>Webroot</td> <td>${webroot}</td></tr>
        <tr><td>Usuario</td> <td>$(http_get_usuario_servicio "$servicio")</td></tr>
        <tr><td>Fecha</td>   <td>$(date '+%Y-%m-%d %H:%M')</td></tr>
    </table>
</body>
</html>
EOF

    if [[ $? -eq 0 ]]; then
        msg_success "index.html generado correctamente"
        return 0
    else
        msg_error "No se pudo escribir el index.html en ${webroot}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# _http_registrar_puerto_selinux  (interna)
# -----------------------------------------------------------------------------
_http_registrar_puerto_selinux() {
    local puerto="$1"

    if ! command -v getenforce &>/dev/null; then
        return 0
    fi
    local modo_selinux
    modo_selinux=$(getenforce 2>/dev/null)
    if [[ "$modo_selinux" == "Disabled" ]]; then
        return 0
    fi

    msg_info "SELinux activo (${modo_selinux}) — verificando registro del puerto ${puerto}..."

    if sudo semanage port -l 2>/dev/null | grep -E "^http_port_t\s" | grep -qw "$puerto"; then
        msg_info "Puerto ${puerto} ya registrado en SELinux como http_port_t"
        return 0
    fi

    if ! command -v semanage &>/dev/null; then
        msg_alert "semanage no disponible — instalando policycoreutils-python-utils..."
        if ! sudo dnf install -y policycoreutils-python-utils 2>/dev/null; then
            msg_error "No se pudo instalar semanage"
            return 1
        fi
    fi

    msg_info "Registrando puerto ${puerto}/tcp en SELinux como http_port_t..."
    if sudo semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null; then
        msg_success "Puerto ${puerto}/tcp registrado en SELinux (http_port_t)"
        return 0
    else
        if sudo semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null; then
            msg_success "Puerto ${puerto}/tcp reasignado a http_port_t en SELinux"
            return 0
        else
            msg_error "No se pudo registrar el puerto ${puerto} en SELinux"
            return 1
        fi
    fi
}

# -----------------------------------------------------------------------------
# _http_configurar_puerto_inicial  (interna)
# -----------------------------------------------------------------------------
_http_configurar_puerto_inicial() {
    local servicio="$1"
    local puerto="$2"

    local archivo_conf
    archivo_conf=$(http_get_conf_archivo "$servicio")

    msg_info "Configurando puerto ${puerto} en: ${archivo_conf}"

    if ! http_crear_backup "$archivo_conf"; then
        msg_alert "Continuando sin backup (archivo puede ser nuevo)"
    fi

    echo ""

    case "$servicio" in
        httpd)
            if [[ -z "$puerto" ]]; then
                msg_error "Puerto vacio — no se modificara httpd.conf"
                return 1
            fi
            if sudo grep -qE "^Listen\s" "$archivo_conf" 2>/dev/null; then
                sudo sed -i -E "s/^Listen\s+[0-9]+\s*$/Listen ${puerto}/" "$archivo_conf"
                sudo sed -i -E "s/^Listen\s+[0-9.]+:[0-9]+\s*$/Listen ${puerto}/" "$archivo_conf"
                sudo sed -i -E "s/^(Listen\s+\[::\]:[0-9]+)$/#\1 # desactivado por gestor HTTP/" "$archivo_conf"
                msg_success "Puerto Apache actualizado: Listen ${puerto}"
            else
                echo "Listen ${puerto}" | sudo tee -a "$archivo_conf" > /dev/null
                msg_success "Directiva Listen ${puerto} agregada a httpd.conf"
            fi
            ;;
        nginx)
            if sudo grep -qE "^\s+listen\s+[0-9]+" "$archivo_conf" 2>/dev/null; then
                # listen activo — actualizar normalmente
                sudo sed -i -E "s/(^\s+listen\s+)[0-9]+(;)/\1${puerto}\2/" "$archivo_conf"
                msg_success "Puerto Nginx actualizado en nginx.conf: listen ${puerto};"
            elif sudo grep -q "# ssl_manager: HTTP desactivado" "$archivo_conf" 2>/dev/null; then
                # ssl_manager comentó la directiva listen — actualizar el número dentro
                # del comentado y en conf.d/http-redirect.conf
                sudo sed -i -E \
                    "s/(#\s*listen\s+)[0-9]+(;)/\1${puerto}\2/" \
                    "$archivo_conf" 2>/dev/null || true
                local _redirect_conf="/etc/nginx/conf.d/http-redirect.conf"
                if [[ -f "$_redirect_conf" ]]; then
                    local _ts_r; _ts_r=$(date +%Y%m%d_%H%M%S)
                    sudo cp "$_redirect_conf" "${_redirect_conf}.bak_${_ts_r}"
                    sudo sed -i -E \
                        "s/(^\s+listen\s+)[0-9]+(;)/\1${puerto}\2/" \
                        "$_redirect_conf" 2>/dev/null || true
                    msg_success "Puerto HTTP actualizado en http-redirect.conf: listen ${puerto};"
                fi
                msg_info "Puerto HTTP actualizado (bloque ssl_manager) en nginx.conf"
            else
                msg_alert "Directiva 'listen' no encontrada en nginx.conf — verifique manualmente"
            fi
            ;;
        tomcat)
            if sudo grep -q 'protocol="HTTP/1.1"' "$archivo_conf" 2>/dev/null; then
                sudo sed -i -E \
                    "s/(Connector port=\")[0-9]+(\" protocol=\"HTTP\/1\.1\")/\1${puerto}\2/" \
                    "$archivo_conf"
                msg_success "Puerto Tomcat actualizado: Connector port=\"${puerto}\""
            else
                msg_alert "Conector HTTP/1.1 no encontrado en server.xml"
            fi
            ;;
    esac

    echo ""
    _http_registrar_puerto_selinux "$puerto"

    return 0
}

# -----------------------------------------------------------------------------
# _http_habilitar_servicio  (interna)
# -----------------------------------------------------------------------------
_http_habilitar_servicio() {
    local servicio="$1"
    local nombre_systemd
    nombre_systemd=$(http_nombre_systemd "$servicio")

    msg_info "Habilitando ${nombre_systemd} en el boot..."
    if sudo systemctl enable "$nombre_systemd" 2>/dev/null; then
        msg_success "Inicio automatico habilitado"
    else
        msg_error "No se pudo habilitar ${nombre_systemd} en el boot"
        return 1
    fi

    echo ""
    msg_info "Iniciando servicio ${nombre_systemd}..."

    if sudo systemctl restart "$nombre_systemd" 2>/dev/null; then
        sleep 2
        if check_service_active "$nombre_systemd"; then
            local pid
            pid=$(sudo systemctl show "$nombre_systemd" \
                  --property=MainPID --value 2>/dev/null)
            msg_success "${nombre_systemd} activo — PID: ${pid}"
            return 0
        else
            msg_error "${nombre_systemd} no levanto correctamente"
            return 1
        fi
    else
        msg_error "Error al iniciar ${nombre_systemd}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# _http_configurar_firewall_inicial  (interna)
# -----------------------------------------------------------------------------
_http_configurar_firewall_inicial() {
    local servicio="$1"
    local puerto_nuevo="$2"

    msg_info "Configurando firewall para puerto ${puerto_nuevo}/tcp..."
    echo ""

    if ! sudo systemctl is-active --quiet firewalld 2>/dev/null; then
        msg_alert "firewalld inactivo — iniciando..."
        sudo systemctl start firewalld 2>/dev/null
        sudo systemctl enable firewalld 2>/dev/null
    fi

    if ! sudo firewall-cmd --list-ports 2>/dev/null | grep -q "${puerto_nuevo}/tcp"; then
        if sudo firewall-cmd --permanent --add-port="${puerto_nuevo}/tcp" 2>/dev/null; then
            msg_success "Puerto ${puerto_nuevo}/tcp abierto en firewall (permanente)"
        else
            msg_error "No se pudo abrir el puerto ${puerto_nuevo}/tcp"
            return 1
        fi
    else
        msg_info "Puerto ${puerto_nuevo}/tcp ya estaba abierto en firewall"
    fi

    local puerto_default
    case "$servicio" in
        httpd|nginx) puerto_default=80   ;;
        tomcat)      puerto_default=8080 ;;
    esac

    if (( puerto_nuevo != puerto_default )); then
        if ! http_puerto_en_uso "$puerto_default"; then
            if (( puerto_default == 80 )); then
                sudo firewall-cmd --permanent --remove-service=http 2>/dev/null && \
                msg_success "Servicio 'http' (puerto 80) eliminado del firewall"
            fi
            if sudo firewall-cmd --list-ports 2>/dev/null | grep -q "${puerto_default}/tcp"; then
                sudo firewall-cmd --permanent --remove-port="${puerto_default}/tcp" 2>/dev/null && \
                msg_success "Puerto ${puerto_default}/tcp cerrado en firewall"
            fi
        else
            msg_info "Puerto default ${puerto_default} en uso por otro servicio — no se cierra"
        fi
    fi

    sudo firewall-cmd --reload 2>/dev/null
    msg_success "Firewall recargado — reglas activas"
    return 0
}

# -----------------------------------------------------------------------------
# _http_setup_apache / _http_setup_nginx / _http_setup_tomcat  (internas)
# -----------------------------------------------------------------------------
_http_setup_apache() {
    local puerto="$1"
    msg_info "Aplicando configuracion post-instalacion de Apache..."
    echo ""

    if [[ ! -d "$HTTP_WEBROOT_APACHE" ]]; then
        sudo mkdir -p "$HTTP_WEBROOT_APACHE"
        sudo chown root:root "$HTTP_WEBROOT_APACHE"
        sudo chmod 755 "$HTTP_WEBROOT_APACHE"
        msg_success "Directorio /var/www/html creado"
    fi

    sudo tee "$HTTP_CONF_APACHE_SECURITY" > /dev/null << 'EOF'
# security.conf — Configuracion de seguridad HTTP
# Generado por ws_install.sh (instalacion inicial)

ServerTokens Prod
ServerSignature Off
EOF
    msg_success "security.conf aplicado: ServerTokens Prod, ServerSignature Off"
    return 0
}

_http_setup_nginx() {
    local puerto="$1"
    msg_info "Aplicando configuracion post-instalacion de Nginx..."
    echo ""

    if sudo grep -q "server_tokens" "$HTTP_CONF_NGINX" 2>/dev/null; then
        sudo sed -i "s/server_tokens.*/server_tokens off;/" "$HTTP_CONF_NGINX"
    else
        sudo sed -i "/^http {/a\\    server_tokens off;" "$HTTP_CONF_NGINX"
    fi

    msg_success "server_tokens off aplicado en nginx.conf"

    if sudo nginx -t 2>/dev/null; then
        msg_success "Sintaxis de nginx.conf: valida"
    else
        msg_alert "Problema de sintaxis en nginx.conf — verificar manualmente"
    fi
    return 0
}

_http_setup_tomcat() {
    local puerto="$1"
    msg_info "Aplicando configuracion post-instalacion de Tomcat..."
    echo ""

    if ! command -v java &>/dev/null; then
        msg_alert "Java no esta instalado — instalando java-17-openjdk..."
        if sudo dnf install -y java-17-openjdk 2>/dev/null; then
            msg_success "java-17-openjdk instalado"
        else
            msg_error "No se pudo instalar Java — Tomcat no funcionara sin JDK"
            return 1
        fi
    else
        local java_ver
        java_ver=$(java -version 2>&1 | head -1)
        msg_success "Java encontrado: ${java_ver}"
    fi

    local catalina_home="${CATALINA_HOME:-/usr/share/tomcat}"
    local java_home
    java_home=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")

    msg_info "CATALINA_HOME : ${catalina_home}"
    msg_info "JAVA_HOME     : ${java_home}"
    echo ""

    local unit_file="/etc/systemd/system/tomcat.service"

    if [[ ! -f "$unit_file" ]] && [[ ! -f "/usr/lib/systemd/system/tomcat.service" ]]; then
        msg_info "Creando unit file de systemd para Tomcat..."

        sudo tee "$unit_file" > /dev/null << EOF
[Unit]
Description=Apache Tomcat Web Application Container
After=network.target

[Service]
Type=forking
User=${HTTP_USUARIO_TOMCAT}
Group=${HTTP_USUARIO_TOMCAT}
Environment="JAVA_HOME=${java_home}"
Environment="CATALINA_HOME=${catalina_home}"
Environment="CATALINA_BASE=${catalina_home}"
Environment="CATALINA_PID=${catalina_home}/temp/tomcat.pid"
ExecStart=${catalina_home}/bin/startup.sh
ExecStop=${catalina_home}/bin/shutdown.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        msg_success "Unit file creado: ${unit_file}"
    else
        msg_success "Unit file de Tomcat ya existe"
    fi

    local dirs_tomcat=("logs" "work" "temp")
    local dir
    for dir in "${dirs_tomcat[@]}"; do
        local ruta_dir="${catalina_home}/${dir}"
        if [[ -d "$ruta_dir" ]]; then
            sudo chown -R "${HTTP_USUARIO_TOMCAT}:${HTTP_USUARIO_TOMCAT}" "$ruta_dir"
            msg_success "Permisos aplicados: ${ruta_dir} → ${HTTP_USUARIO_TOMCAT}"
        fi
    done

    return 0
}

# -----------------------------------------------------------------------------
# http_instalar_apache
# Hook SSL al final, tras http_draw_resumen.
# -----------------------------------------------------------------------------
http_instalar_apache() {
    local version="$1"
    local puerto="$2"

    http_draw_servicio_header "Apache (httpd)" "Paso 4 de 4 — Instalacion"

    separator
    msg_info "PASO 1/5 — Instalacion del paquete"
    separator
    if ! _http_instalar_paquete "httpd" "$version"; then
        return 1
    fi

    echo ""
    separator
    msg_info "PASO 2/5 — Usuario dedicado"
    separator
    http_crear_usuario_dedicado "$HTTP_USUARIO_APACHE" "$HTTP_WEBROOT_APACHE"

    echo ""
    separator
    msg_info "PASO 3/5 — Configuracion post-instalacion"
    separator
    _http_setup_apache "$puerto"

    echo ""
    separator
    msg_info "PASO 4/5 — Configuracion de puerto"
    separator
    _http_configurar_puerto_inicial "httpd" "$puerto"

    echo ""
    separator
    msg_info "PASO 5/5 — Activacion del servicio"
    separator
    if ! _http_habilitar_servicio "httpd"; then
        return 1
    fi
    echo ""
    _http_configurar_firewall_inicial "httpd" "$puerto"
    echo ""
    http_crear_index "httpd" "$version" "$puerto"

    echo ""
    http_draw_resumen "Apache (httpd)" "$puerto" "$version"

    # Hook SSL — pregunta al usuario si desea activar HTTPS
    _http_ssl_hook "httpd" "post_install"

    return 0
}

# -----------------------------------------------------------------------------
# http_instalar_nginx
# Hook SSL al final, tras http_draw_resumen.
# -----------------------------------------------------------------------------
http_instalar_nginx() {
    local version="$1"
    local puerto="$2"

    http_draw_servicio_header "Nginx" "Paso 4 de 4 — Instalacion"

    separator
    msg_info "PASO 1/5 — Instalacion del paquete"
    separator
    if ! _http_instalar_paquete "nginx" "$version"; then
        return 1
    fi

    echo ""
    separator
    msg_info "PASO 2/5 — Usuario dedicado"
    separator
    http_crear_usuario_dedicado "$HTTP_USUARIO_NGINX" "$HTTP_WEBROOT_NGINX"

    echo ""
    separator
    msg_info "PASO 3/5 — Configuracion post-instalacion"
    separator
    _http_setup_nginx "$puerto"

    echo ""
    separator
    msg_info "PASO 4/5 — Configuracion de puerto"
    separator
    _http_configurar_puerto_inicial "nginx" "$puerto"

    echo ""
    separator
    msg_info "PASO 5/5 — Activacion del servicio"
    separator
    if ! _http_habilitar_servicio "nginx"; then
        return 1
    fi
    echo ""
    _http_configurar_firewall_inicial "nginx" "$puerto"
    echo ""
    http_crear_index "nginx" "$version" "$puerto"

    echo ""
    http_draw_resumen "Nginx" "$puerto" "$version"

    # Hook SSL — pregunta al usuario si desea activar HTTPS
    _http_ssl_hook "nginx" "post_install"

    return 0
}

# -----------------------------------------------------------------------------
# http_instalar_tomcat
# Hook SSL al final, tras http_draw_resumen.
# -----------------------------------------------------------------------------
http_instalar_tomcat() {
    local version="$1"
    local puerto="$2"

    http_draw_servicio_header "Tomcat" "Paso 4 de 4 — Instalacion"

    separator
    msg_info "PASO 1/5 — Instalacion del paquete"
    separator
    if ! _http_instalar_paquete "tomcat" "$version"; then
        return 1
    fi

    echo ""
    separator
    msg_info "PASO 2/5 — Usuario dedicado"
    separator
    http_crear_usuario_dedicado "$HTTP_USUARIO_TOMCAT" "$(http_get_webroot tomcat)"

    echo ""
    separator
    msg_info "PASO 3/5 — Configuracion post-instalacion (Java + systemd)"
    separator
    if ! _http_setup_tomcat "$puerto"; then
        return 1
    fi

    echo ""
    separator
    msg_info "PASO 4/5 — Configuracion de puerto"
    separator
    _http_configurar_puerto_inicial "tomcat" "$puerto"

    echo ""
    separator
    msg_info "PASO 5/5 — Activacion del servicio"
    separator
    if ! _http_habilitar_servicio "tomcat"; then
        return 1
    fi
    echo ""
    _http_configurar_firewall_inicial "tomcat" "$puerto"
    echo ""
    http_crear_index "tomcat" "$version" "$puerto"

    echo ""
    http_draw_resumen "Tomcat" "$puerto" "$version"

    # Hook SSL — pregunta al usuario si desea activar HTTPS
    _http_ssl_hook "tomcat" "post_install"

    return 0
}

# -----------------------------------------------------------------------------
# http_menu_instalar
# Hook SSL en el flujo de reconfiguración (caso "reconfigurar:*").
# -----------------------------------------------------------------------------
http_menu_instalar() {
    # Cargar módulo FTP si está disponible
    local _ftp_src_lib
    _ftp_src_lib="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/ws_lib/ws_ftp_source.sh"
    [[ -f "$_ftp_src_lib" ]] && source "$_ftp_src_lib" 2>/dev/null || true

    local seleccion_servicio
    http_seleccionar_servicio seleccion_servicio

    case "$seleccion_servicio" in
        cancelar)
            msg_info "Instalacion cancelada"
            sleep 2
            return 0
            ;;
        reinstalar:*)
            local servicio="${seleccion_servicio#reinstalar:}"
            msg_alert "Desinstalando version actual de ${servicio}..."
            sudo dnf remove -y "$(http_nombre_paquete "$servicio")" &>/dev/null
            msg_success "Desinstalado. Continuando con instalacion limpia..."
            sleep 2
            ;;
        reconfigurar:*)
            local servicio="${seleccion_servicio#reconfigurar:}"
            msg_info "Modo reconfiguracion — omitiendo instalacion del paquete"
            local version_actual
            version_actual=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" \
                             "$(http_nombre_paquete "$servicio")" 2>/dev/null)

            local puerto_reconfig
            http_seleccionar_puerto "$servicio" puerto_reconfig

            _http_configurar_puerto_inicial "$servicio" "$puerto_reconfig"
            echo ""

            if ! http_reiniciar_servicio "$servicio"; then
                msg_error "El servicio no levanto con el nuevo puerto"
                msg_pause
                return 1
            fi
            echo ""

            _http_configurar_firewall_inicial "$servicio" "$puerto_reconfig"
            echo ""
            http_crear_index "$servicio" "$version_actual" "$puerto_reconfig"

            echo ""
            http_draw_resumen "$servicio" "$puerto_reconfig" "$version_actual"

            # Hook SSL en reconfiguración — reescribe todo si acepta
            _http_ssl_hook "$servicio" "post_reconfig"

            echo ""
            msg_pause
            return 0
            ;;
        *)
            local servicio="$seleccion_servicio"
            ;;
    esac

    # ── Selección de fuente ANTES de consultar versiones ─────────────
    # Si se elige FTP, se salta la consulta de versiones a dnf.
    local _fuente_instalacion="internet"
    if declare -f ftp_src_flujo_completo &>/dev/null; then
        _http_seleccionar_fuente _fuente_instalacion
    fi

    if [[ "$_fuente_instalacion" == "ftp" ]]; then
        # ── Flujo FTP correcto:
        #   Paso 2/4: FTP (credenciales, version, descarga, instalacion RPM)
        #   Paso 3/4: Puerto
        #   Paso 4/4: Setup, firewall, index, resumen, SSL

        # Paso 2: Todo lo de FTP
        local _version_ftp
        if ! ftp_src_flujo_completo "$servicio" _version_ftp; then
            msg_error "Instalacion desde FTP fallida"
            echo ""
            msg_pause
            return 1
        fi
        [[ -z "$_version_ftp" ]] && _version_ftp="desconocida"
        echo ""

        # Paso 3: Puerto (despues del FTP, no antes)
        local puerto_elegido
        http_seleccionar_puerto "$servicio" puerto_elegido "Paso 3 de 4"

        if ! http_validar_puerto "$puerto_elegido"; then
            msg_error "El puerto $puerto_elegido no está disponible. Instalacion cancelada."
            return 1
        fi

        # Paso 4: Setup, habilitar, firewall, index, resumen, SSL
        case "$servicio" in
            httpd)
                _http_setup_apache "$puerto_elegido"
                _http_configurar_puerto_inicial "httpd" "$puerto_elegido"
                _http_habilitar_servicio "httpd"
                _http_configurar_firewall_inicial "httpd" "$puerto_elegido"
                http_crear_index "httpd" "$_version_ftp" "$puerto_elegido"
                http_draw_resumen "Apache (httpd)" "$puerto_elegido" "$_version_ftp"
                _http_ssl_hook "httpd" "post_install"
                ;;
            nginx)
                _http_setup_nginx "$puerto_elegido"
                _http_configurar_puerto_inicial "nginx" "$puerto_elegido"
                _http_habilitar_servicio "nginx"
                _http_configurar_firewall_inicial "nginx" "$puerto_elegido"
                http_crear_index "nginx" "$_version_ftp" "$puerto_elegido"
                http_draw_resumen "Nginx" "$puerto_elegido" "$_version_ftp"
                _http_ssl_hook "nginx" "post_install"
                ;;
            tomcat)
                _http_setup_tomcat "$puerto_elegido"
                _http_configurar_puerto_inicial "tomcat" "$puerto_elegido"
                _http_habilitar_servicio "tomcat"
                _http_configurar_firewall_inicial "tomcat" "$puerto_elegido"
                http_crear_index "tomcat" "$_version_ftp" "$puerto_elegido"
                http_draw_resumen "Tomcat" "$puerto_elegido" "$_version_ftp"
                _http_ssl_hook "tomcat" "post_install"
                ;;
        esac

        echo ""
        msg_pause
        return 0
    fi

    # ── Flujo Internet (dnf) ──────────────────────────────────────────
    echo ""
    msg_pause

    local versiones_disponibles=()
    if ! http_consultar_versiones "$servicio" versiones_disponibles; then
        msg_error "No se pudieron obtener versiones. Verifique la conexion."
        echo ""
        msg_pause
        return 1
    fi

    echo ""
    msg_pause

    local version_elegida
    http_seleccionar_version "$servicio" versiones_disponibles version_elegida

    echo ""
    msg_pause

    local puerto_elegido
    http_seleccionar_puerto "$servicio" puerto_elegido

    if ! http_validar_puerto "$puerto_elegido"; then
        msg_error "El puerto $puerto_elegido ya no esta disponible. Instalacion cancelada."
        return 1
    fi

    echo ""
    separator
    msg_info "Resumen de la instalacion a realizar:"
    echo ""
    printf "    Servicio : %s\n" "$servicio"
    printf "    Version  : %s\n" "$version_elegida"
    printf "    Puerto   : %s/tcp\n" "$puerto_elegido"
    echo ""

    local confirmacion
    while true; do
        input_read "Confirmar instalacion? [s/n]" confirmacion
        local resultado
        http_validar_confirmacion "$confirmacion"
        resultado=$?

        if (( resultado == 0 )); then
            break
        elif (( resultado == 1 )); then
            msg_info "Instalacion cancelada"
            sleep 2
            return 0
        fi
        echo ""
    done

    separator
    echo ""

    # ── Instalación normal desde Internet (dnf) ───────────────────────
    case "$servicio" in
        httpd)  http_instalar_apache "$version_elegida" "$puerto_elegido" ;;
        nginx)  http_instalar_nginx  "$version_elegida" "$puerto_elegido" ;;
        tomcat) http_instalar_tomcat "$version_elegida" "$puerto_elegido" ;;
    esac

    echo ""
    msg_pause
}

# -----------------------------------------------------------------------------
# Exports
# -----------------------------------------------------------------------------
export -f _http_ssl_hook
export -f _http_seleccionar_fuente
export -f http_seleccionar_servicio
export -f http_consultar_versiones
export -f http_seleccionar_version
export -f http_seleccionar_puerto
export -f http_crear_usuario_dedicado
export -f http_crear_index
export -f http_instalar_apache
export -f http_instalar_nginx
export -f http_instalar_tomcat
export -f http_menu_instalar
export -f _http_instalar_paquete
export -f _http_registrar_puerto_selinux
export -f _http_configurar_puerto_inicial
export -f _http_habilitar_servicio
export -f _http_configurar_firewall_inicial
export -f _http_setup_apache
export -f _http_setup_nginx
export -f _http_setup_tomcat