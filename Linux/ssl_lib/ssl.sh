#!/bin/bash
# =============================================================================
# ssl_lib/ssl.sh — Entry point SSL/TLS. Variables globales y carga de módulos.
# Uso: source ssl_lib/ssl.sh
# Requiere: source lib/ui.sh, source lib/utils.sh
# =============================================================================

SSL_BASE_DIR="${SSL_BASE_DIR:-/etc/ssl/reprobados}"
SSL_CERT_DAYS_DEFAULT=365

SSL_DIR_APACHE="${SSL_BASE_DIR}/apache"
SSL_DIR_NGINX="${SSL_BASE_DIR}/nginx"
SSL_DIR_TOMCAT="${SSL_BASE_DIR}/tomcat"
SSL_DIR_VSFTPD="${SSL_BASE_DIR}/vsftpd"

SSL_CERT_FILE="server.crt"
SSL_KEY_FILE="server.key"
SSL_CSR_FILE="server.csr"

SSL_PORT_TOMCAT_HTTPS=8443   # default sugerido para Tomcat
SSL_FTPS_PASV_MIN=30000
SSL_FTPS_PASV_MAX=31000

# -----------------------------------------------------------------------------
# ssl_seleccionar_puerto_https
#
# Muestra el puerto HTTPS sugerido (80→443, 8080→8443, otro→otro+363)
# y permite al usuario aceptarlo o ingresar uno diferente.
# Valida que no colisione con el puerto HTTP ni esté en uso por otro proceso.
#
# $1 = nombre del servicio  (para mensajes)
# $2 = puerto HTTP actual
# $3 = variable destino
# -----------------------------------------------------------------------------
ssl_seleccionar_puerto_https() {
    local nombre_svc="$1"
    local http_port="$2"
    local __var="$3"

    # Calcular puerto sugerido
    local puerto_sugerido
    case "$http_port" in
        80)   puerto_sugerido=443  ;;
        8080) puerto_sugerido=8443 ;;
        *)    puerto_sugerido=$(( http_port + 363 )) ;;
    esac

    echo ""
    msg_info "Puerto HTTP activo    : ${http_port}/tcp"
    msg_info "Puerto HTTPS sugerido : ${puerto_sugerido}/tcp"
    echo ""
    msg_input "¿Usar ${puerto_sugerido} como puerto HTTPS? [S/n/número]: "
    read -r resp

    # Enter o S → usar el sugerido
    if [[ -z "$resp" || "${resp^^}" =~ ^(S|SI|Y|YES)$ ]]; then
        printf -v "$__var" "%s" "$puerto_sugerido"
        msg_success "Puerto HTTPS: ${puerto_sugerido}/tcp"
        return 0
    fi

    # Si el usuario escribió un número directamente, usarlo como candidato
    local candidato=""
    [[ "$resp" =~ ^[0-9]+$ ]] && candidato="$resp"

    # Pedir puerto con validación
    while true; do
        if [[ -n "$candidato" ]]; then
            local puerto_elegido="$candidato"
            candidato=""
        else
            msg_input "Puerto HTTPS [1-65535, distinto de ${http_port}]: "
            read -r puerto_elegido
        fi

        # Validar formato
        if ! [[ "$puerto_elegido" =~ ^[0-9]+$ ]] || \
           (( puerto_elegido < 1 || puerto_elegido > 65535 )); then
            msg_error "Puerto inválido — debe ser un número entre 1 y 65535"
            continue
        fi

        # No puede ser igual al HTTP
        if [[ "$puerto_elegido" == "$http_port" ]]; then
            msg_error "El puerto HTTPS no puede ser igual al HTTP (${http_port})"
            continue
        fi

        # Advertir si ya está en uso (pero no bloquear)
        if sudo ss -tlnp 2>/dev/null | grep -q ":${puerto_elegido} "; then
            msg_alert "El puerto ${puerto_elegido} ya está en uso por otro proceso"
            msg_input "¿Continuar de todas formas? [s/N]: "
            read -r forzar
            [[ ! "${forzar^^}" =~ ^(S|SI|Y|YES)$ ]] && continue
        fi

        printf -v "$__var" "%s" "$puerto_elegido"
        msg_success "Puerto HTTPS seleccionado: ${puerto_elegido}/tcp"
        return 0
    done
}

# -----------------------------------------------------------------------------
# ssl_esta_activo
# Retorna 0 si SSL está activo para el servicio dado.
# -----------------------------------------------------------------------------
ssl_esta_activo() {
    local servicio="$1"
    case "$servicio" in
        apache|httpd)
            [[ -f "/etc/httpd/conf.d/ssl-reprobados.conf" ]]
            ;;
        nginx)
            sudo grep -q "${_SSL_NGINX_MARCA:-ssl_manager: SSL block}" \
                 /etc/nginx/nginx.conf 2>/dev/null
            ;;
        tomcat)
            local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
            sudo grep -q 'SSLEnabled="true"' \
                 "${catalina}/conf/server.xml" 2>/dev/null
            ;;
        vsftpd|ftp)
            grep -q "^ssl_enable=YES" \
                 "${VSFTPD_CONF:-/etc/vsftpd/vsftpd.conf}" 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# ssl_preguntar_activar
# Pregunta interactiva reutilizable: "¿Desea activar SSL? [S/N]"
# -----------------------------------------------------------------------------
ssl_preguntar_activar() {
    local nombre_servicio="${1:-servicio}"
    echo ""
    msg_input "¿Desea activar SSL/TLS en ${nombre_servicio}? [S/N]: "
    read -r respuesta
    case "${respuesta^^}" in
        S|SI|Y|YES) return 0 ;;
        *)           return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Cargar módulos
# -----------------------------------------------------------------------------
_SSL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$_SSL_LIB_DIR/ssl_certs.sh"  || { echo "ERROR: ssl_certs.sh no cargó"; return 1; }
source "$_SSL_LIB_DIR/ssl_apache.sh" || { echo "ERROR: ssl_apache.sh no cargó"; return 1; }
source "$_SSL_LIB_DIR/ssl_nginx.sh"  || { echo "ERROR: ssl_nginx.sh no cargó"; return 1; }
source "$_SSL_LIB_DIR/ssl_tomcat.sh" || { echo "ERROR: ssl_tomcat.sh no cargó"; return 1; }
source "$_SSL_LIB_DIR/ssl_ftp.sh"    || { echo "ERROR: ssl_ftp.sh no cargó"; return 1; }
source "$_SSL_LIB_DIR/ssl_audit.sh"  || { echo "ERROR: ssl_audit.sh no cargó"; return 1; }

export SSL_BASE_DIR SSL_CERT_DAYS_DEFAULT
export SSL_DIR_APACHE SSL_DIR_NGINX SSL_DIR_TOMCAT SSL_DIR_VSFTPD
export SSL_CERT_FILE SSL_KEY_FILE SSL_CSR_FILE
export SSL_PORT_TOMCAT_HTTPS SSL_FTPS_PASV_MIN SSL_FTPS_PASV_MAX
export -f ssl_seleccionar_puerto_https
export -f ssl_esta_activo
export -f ssl_preguntar_activar