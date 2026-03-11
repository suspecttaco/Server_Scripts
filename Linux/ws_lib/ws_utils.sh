#!/bin/bash
# =============================================================================
# ws_lib/ws_utils.sh — Utilidades y constantes para gestión de servicios web
# Requiere: source lib/ui.sh, source lib/utils.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Constantes globales
# -----------------------------------------------------------------------------

readonly HTTP_SERVICIO_APACHE="httpd"
readonly HTTP_SERVICIO_NGINX="nginx"
readonly HTTP_SERVICIO_TOMCAT="tomcat"

readonly HTTP_WEBROOT_APACHE="/var/www/html"
readonly HTTP_WEBROOT_NGINX="/usr/share/nginx/html"

readonly HTTP_CONF_APACHE="/etc/httpd/conf/httpd.conf"
readonly HTTP_CONF_NGINX="/etc/nginx/nginx.conf"
readonly HTTP_CONF_APACHE_SECURITY="/etc/httpd/conf.d/security.conf"

readonly HTTP_USUARIO_APACHE="apache"
readonly HTTP_USUARIO_NGINX="nginx"
readonly HTTP_USUARIO_TOMCAT="tomcat"

readonly HTTP_PUERTOS_RESERVADOS=(22 25 53 3306 5432 6379 27017)

readonly HTTP_PUERTO_DEFAULT_APACHE=80
readonly HTTP_PUERTO_DEFAULT_NGINX=80
readonly HTTP_PUERTO_DEFAULT_TOMCAT=8080

# -----------------------------------------------------------------------------
# Verificación de dependencias
# -----------------------------------------------------------------------------

http_verificar_dependencias() {
    local faltantes=0
    local herramientas_criticas=("dnf" "systemctl" "firewall-cmd" "ss" "sed" "curl")

    msg_info "Verificando herramientas necesarias..."
    echo ""

    local herramienta
    for herramienta in "${herramientas_criticas[@]}"; do
        if command -v "$herramienta" &>/dev/null; then
            printf "  ${GREEN}[OK]${NC}  %-15s encontrado en: %s\n" \
                   "$herramienta" "$(command -v "$herramienta")"
        else
            printf "  ${RED}[NO]${NC}  %-15s NO encontrado\n" "$herramienta"
            (( faltantes++ ))
        fi
    done

    echo ""

    if command -v java &>/dev/null; then
        local java_ver
        java_ver=$(java -version 2>&1 | head -1)
        printf "  ${GREEN}[OK]${NC}  %-15s %s\n" "java" "$java_ver"
    else
        printf "  ${YELLOW}[WARN]${NC} %-15s No instalado (requerido solo para Tomcat)\n" "java"
        msg_info "  Instale con: sudo dnf install java-17-openjdk -y"
    fi

    echo ""

    if (( faltantes > 0 )); then
        msg_error "$faltantes herramienta(s) critica(s) no encontrada(s)"
        return 1
    fi

    msg_success "Todas las dependencias criticas disponibles"
    return 0
}

# -----------------------------------------------------------------------------
# Gestión de puertos (solo lectura)
# -----------------------------------------------------------------------------

http_puerto_en_uso() {
    local puerto="$1"
    sudo ss -tlnp 2>/dev/null | grep -q ":${puerto} "
}

http_quien_usa_puerto() {
    local puerto="$1"
    local proceso
    proceso=$(sudo ss -tlnp 2>/dev/null \
              | grep ":${puerto} " \
              | grep -oP 'users:\(\("\K[^"]+' \
              | head -1)
    echo "${proceso:-desconocido}"
}

http_listar_puertos_activos() {
    msg_info "Puertos HTTP activos en el sistema:"
    echo ""

    local puertos_web=(80 443 8080 8443 8888 3000 4000 8000 9090)
    printf "  %-10s %-12s %-20s\n" "PUERTO" "ESTADO" "PROCESO"
    separator

    local puerto
    for puerto in "${puertos_web[@]}"; do
        if http_puerto_en_uso "$puerto"; then
            local proceso
            proceso=$(http_quien_usa_puerto "$puerto")
            printf "  ${GREEN}%-10s${NC} %-12s %-20s\n" "${puerto}/tcp" "EN USO" "$proceso"
        else
            printf "  ${GRAY}%-10s${NC} %-12s\n" "${puerto}/tcp" "libre"
        fi
    done
}

# -----------------------------------------------------------------------------
# Resolución de metadatos del servicio
# -----------------------------------------------------------------------------

http_nombre_paquete() {
    local servicio="$1"
    case "$servicio" in
        httpd|apache) echo "httpd"  ;;
        nginx)        echo "nginx"  ;;
        tomcat)       echo "tomcat" ;;
        *)            echo "$servicio" ;;
    esac
}

http_nombre_systemd() {
    local servicio="$1"
    case "$servicio" in
        httpd|apache) echo "httpd"  ;;
        nginx)        echo "nginx"  ;;
        tomcat)       echo "tomcat" ;;
        *)            echo "$servicio" ;;
    esac
}

http_get_webroot() {
    local servicio="$1"
    case "$servicio" in
        httpd|apache) echo "$HTTP_WEBROOT_APACHE" ;;
        nginx)        echo "$HTTP_WEBROOT_NGINX"  ;;
        tomcat)
            local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
            echo "${catalina}/webapps/ROOT"
            ;;
        *) echo "/var/www/html" ;;
    esac
}

http_get_usuario_servicio() {
    local servicio="$1"
    case "$servicio" in
        httpd|apache) echo "$HTTP_USUARIO_APACHE" ;;
        nginx)        echo "$HTTP_USUARIO_NGINX"  ;;
        tomcat)       echo "$HTTP_USUARIO_TOMCAT" ;;
        *)            echo "nobody" ;;
    esac
}

http_get_conf_archivo() {
    local servicio="$1"
    case "$servicio" in
        httpd|apache) echo "$HTTP_CONF_APACHE" ;;
        nginx)        echo "$HTTP_CONF_NGINX"  ;;
        tomcat)
            local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
            echo "${catalina}/conf/server.xml"
            ;;
        *) echo "" ;;
    esac
}

# -----------------------------------------------------------------------------
# Backup / restauración de configuraciones
# -----------------------------------------------------------------------------

http_crear_backup() {
    local archivo="$1"

    if [[ ! -f "$archivo" ]]; then
        msg_alert "Archivo no encontrado para backup: $archivo"
        return 1
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup="${archivo}.bak_${timestamp}"

    if sudo cp "$archivo" "$backup" 2>/dev/null; then
        msg_success "Backup creado: $backup"
        return 0
    else
        msg_error "No se pudo crear backup de: $archivo"
        return 1
    fi
}

http_restaurar_backup() {
    local archivo="$1"
    local directorio
    directorio=$(dirname "$archivo")
    local nombre
    nombre=$(basename "$archivo")

    local backup_reciente
    backup_reciente=$(sudo find "$directorio" -name "${nombre}.bak_*" 2>/dev/null \
                      | sort | tail -1)

    if [[ -z "$backup_reciente" ]]; then
        msg_error "No se encontro ningun backup para: $archivo"
        return 1
    fi

    msg_info "Restaurando desde: $backup_reciente"

    if sudo cp "$backup_reciente" "$archivo" 2>/dev/null; then
        msg_success "Archivo restaurado correctamente"
        return 0
    else
        msg_error "Error al restaurar el backup"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Presentación visual específica HTTP
# -----------------------------------------------------------------------------

http_draw_servicio_header() {
    local servicio="$1"
    local accion="$2"
    echo ""
    separator
    echo -e "  ${CYAN}[HTTP]${NC} ${servicio} — ${accion}"
    separator
    echo ""
}

http_draw_resumen() {
    local servicio="$1"
    local puerto="$2"
    local version="$3"

    echo ""
    separator
    echo -e "${GREEN}Despliegue completado exitosamente${NC}"
    separator
    printf "%-10s %-30s \n" "Servicio:"  "$servicio"
    printf "%-10s %-30s \n" "Version:"   "$version"
    printf "%-10s %-30s \n" "Puerto:"    "$puerto/tcp"
    separator
    echo ""
    msg_info "Verificacion rapida:"
    echo "curl -I http://localhost:${puerto}"
    echo ""
}

# -----------------------------------------------------------------------------
# Recarga / reinicio de servicios
# -----------------------------------------------------------------------------

http_recargar_servicio() {
    local servicio="$1"
    local nombre_systemd
    nombre_systemd=$(http_nombre_systemd "$servicio")

    msg_info "Recargando configuracion de ${nombre_systemd}..."

    if sudo systemctl reload "$nombre_systemd" 2>/dev/null; then
        sleep 1
        if check_service_active "$nombre_systemd"; then
            msg_success "${nombre_systemd} recargado y activo"
            return 0
        else
            msg_error "${nombre_systemd} no esta activo tras el reload"
            return 1
        fi
    else
        msg_alert "reload no disponible — intentando restart..."
        http_reiniciar_servicio "$servicio"
        return $?
    fi
}

http_reiniciar_servicio() {
    local servicio="$1"
    local nombre_systemd
    nombre_systemd=$(http_nombre_systemd "$servicio")

    msg_info "Reiniciando ${nombre_systemd}..."

    if sudo systemctl restart "$nombre_systemd" 2>/dev/null; then
        sleep 2
        if check_service_active "$nombre_systemd"; then
            local pid
            pid=$(sudo systemctl show "$nombre_systemd" \
                  --property=MainPID --value 2>/dev/null)
            msg_success "${nombre_systemd} reiniciado — PID: ${pid}"
            return 0
        else
            msg_error "${nombre_systemd} no levanto tras el reinicio"
            msg_info "Revise los logs: sudo journalctl -u ${nombre_systemd} -n 20"
            return 1
        fi
    else
        msg_error "Error al ejecutar restart de ${nombre_systemd}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Verificación HTTP en vivo
# -----------------------------------------------------------------------------

http_verificar_respuesta() {
    local servicio="$1"
    local puerto="$2"

    msg_info "Verificando respuesta HTTP en localhost:${puerto}..."
    echo ""

    local respuesta
    respuesta=$(curl -I --max-time 5 --silent --show-error \
                "http://localhost:${puerto}" 2>&1)
    local exit_code=$?

    if (( exit_code == 0 )); then
        msg_success "Servicio respondiendo en puerto ${puerto}"
        echo ""
        echo "$respuesta" | sed 's/^/    /'
        return 0
    else
        msg_error "El servicio NO responde en puerto ${puerto}"
        msg_info "Posibles causas:"
        echo "    - El servicio no esta activo (systemctl status ${servicio})"
        echo "    - El puerto configurado no coincide con el real"
        echo "    - El firewall esta bloqueando la conexion"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Exports
# -----------------------------------------------------------------------------

export HTTP_SERVICIO_APACHE HTTP_SERVICIO_NGINX HTTP_SERVICIO_TOMCAT
export HTTP_WEBROOT_APACHE HTTP_WEBROOT_NGINX
export HTTP_CONF_APACHE HTTP_CONF_NGINX HTTP_CONF_APACHE_SECURITY
export HTTP_USUARIO_APACHE HTTP_USUARIO_NGINX HTTP_USUARIO_TOMCAT
export HTTP_PUERTOS_RESERVADOS
export HTTP_PUERTO_DEFAULT_APACHE HTTP_PUERTO_DEFAULT_NGINX HTTP_PUERTO_DEFAULT_TOMCAT

export -f http_verificar_dependencias
export -f http_puerto_en_uso
export -f http_quien_usa_puerto
export -f http_listar_puertos_activos
export -f http_nombre_paquete
export -f http_nombre_systemd
export -f http_get_webroot
export -f http_get_usuario_servicio
export -f http_get_conf_archivo
export -f http_crear_backup
export -f http_restaurar_backup
export -f http_draw_servicio_header
export -f http_draw_resumen
export -f http_recargar_servicio
export -f http_reiniciar_servicio
export -f http_verificar_respuesta