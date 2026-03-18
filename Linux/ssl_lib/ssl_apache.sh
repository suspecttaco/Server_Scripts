#!/bin/bash
# =============================================================================
# ssl_lib/ssl_apache.sh — SSL/TLS para Apache (httpd)
# =============================================================================

readonly _SSL_APACHE_CONF="/etc/httpd/conf.d/ssl-reprobados.conf"

_ssl_apache_leer_puerto_http() {
    local puerto
    puerto=$(sudo grep -E "^Listen\s+[0-9]+" /etc/httpd/conf/httpd.conf 2>/dev/null \
             | awk '{print $2}' | grep -oP '[0-9]+$' | head -1)
    echo "${puerto:-80}"
}

_ssl_apache_leer_puerto_https() {
    # Lee el puerto HTTPS desde ssl-reprobados.conf si existe
    local puerto
    puerto=$(sudo grep -oP "^Listen\s+\K[0-9]+" "$_SSL_APACHE_CONF" 2>/dev/null | head -1)
    echo "${puerto:-443}"
}

_ssl_apache_verificar_mod_ssl() {
    msg_process "Verificando mod_ssl..."

    if rpm -q mod_ssl &>/dev/null; then
        msg_success "mod_ssl instalado: $(rpm -q --queryformat '%{VERSION}' mod_ssl 2>/dev/null)"
    else
        msg_alert "mod_ssl no instalado — instalando..."
        if ! sudo dnf install -y mod_ssl &>/dev/null; then
            msg_error "No se pudo instalar mod_ssl"
            return 1
        fi
        msg_success "mod_ssl instalado"
    fi

    # Desactivar ssl.conf del paquete — apunta a certs que no existen
    local mod_ssl_conf="/etc/httpd/conf.d/ssl.conf"
    if [[ -f "$mod_ssl_conf" ]]; then
        local ts; ts=$(date +%Y%m%d_%H%M%S)
        sudo mv "$mod_ssl_conf" "${mod_ssl_conf}.disabled_${ts}"
        msg_success "ssl.conf de mod_ssl desactivado"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# _ssl_apache_escribir_conf  (interna)
# Genera/reescribe completo ssl-reprobados.conf con los puertos indicados.
# -----------------------------------------------------------------------------
_ssl_apache_escribir_conf() {
    local http_port="$1"
    local https_port="$2"
    local cert_path="${SSL_DIR_APACHE}/${SSL_CERT_FILE}"
    local key_path="${SSL_DIR_APACHE}/${SSL_KEY_FILE}"
    local server_name="${SSL_CERT_CN}"
    local webroot="${HTTP_WEBROOT_APACHE:-/var/www/html}"
    # Obtener todas las IPs del servidor para ServerName del VirtualHost HTTP
    # Igual que Nginx: Apache hace match por ServerName y %{SERVER_ADDR}
    # devuelve la IP correcta del socket
    local server_ips
    server_ips=$(hostname -I 2>/dev/null | tr " " "\n" | grep -v "^$" | tr "\n" " " | xargs)
    [[ -z "$server_ips" ]] && server_ips="$server_name"

    msg_process "Escribiendo ${_SSL_APACHE_CONF}..."

    sudo tee "$_SSL_APACHE_CONF" > /dev/null << APACHESSL
# ssl-reprobados.conf
# Generado por ssl_manager — $(date '+%Y-%m-%d %H:%M:%S')
# Reescribir completo al reconfigurar — no editar manualmente.

# Listen DEBE estar fuera del VirtualHost
Listen ${https_port}

# ── VirtualHost HTTPS ────────────────────────────────────────────────────────
<VirtualHost *:${https_port}>
    ServerName ${server_name}
    DocumentRoot ${webroot}

    SSLEngine on
    SSLCertificateFile    ${cert_path}
    SSLCertificateKeyFile ${key_path}

    SSLProtocol all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite HIGH:!aNULL:!MD5:!3DES
    SSLHonorCipherOrder on
    SSLCompression off

    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set X-Content-Type-Options "nosniff"
        Header always set Referrer-Policy "strict-origin-when-cross-origin"
        Header always set X-XSS-Protection "1; mode=block"
    </IfModule>

    ErrorLog  /var/log/httpd/ssl_error.log
    CustomLog /var/log/httpd/ssl_access.log combined

    <Directory "${webroot}">
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>

# ── Redirect HTTP → HTTPS ────────────────────────────────────────────────────
# ServerName con todas las IPs del servidor para capturar peticiones
# desde cualquier adaptador. %{HTTP_HOST} devuelve host:puerto del cliente,
# usamos el header directamente y eliminamos el puerto con regex.
<VirtualHost *:${http_port}>
    ServerName ${server_name}
    ServerAlias ${server_ips}
    RewriteEngine On
    # %{HTTP_HOST} = host:puerto o solo host — eliminar puerto si existe
    RewriteCond %{HTTP_HOST} ^([^:]+)(:[0-9]+)?$
    RewriteRule ^(.*)$ https://%1:${https_port}\$1 [R=301,L]
</VirtualHost>
APACHESSL

    [[ $? -eq 0 ]] && msg_success "ssl-reprobados.conf escrito" && return 0
    msg_error "Error al escribir ${_SSL_APACHE_CONF}"
    return 1
}

_ssl_apache_verificar_sintaxis() {
    msg_process "Verificando sintaxis Apache..."
    local out; out=$(sudo apachectl configtest 2>&1)
    if echo "$out" | grep -q "Syntax OK"; then
        msg_success "Sintaxis: OK"
        return 0
    fi
    msg_error "Error de sintaxis:"
    echo "$out" | sed 's/^/    /'
    return 1
}

_ssl_apache_abrir_firewall() {
    local puerto="$1"
    command -v firewall-cmd &>/dev/null || return 0
    sudo systemctl is-active --quiet firewalld 2>/dev/null || return 0
    msg_process "Abriendo ${puerto}/tcp en firewalld..."
    sudo firewall-cmd --permanent --add-port="${puerto}/tcp" &>/dev/null || true
    [[ "$puerto" == "443" ]] && \
        sudo firewall-cmd --permanent --add-service=https &>/dev/null || true
    sudo firewall-cmd --reload &>/dev/null
    msg_success "Puerto ${puerto}/tcp abierto"
}

# -----------------------------------------------------------------------------
# ssl_apache_actualizar_puertos  (pública)
#
# Reescribe ssl-reprobados.conf con nuevos puertos HTTP y/o HTTPS.
# Llamada desde ws_config.sh cuando el usuario cambia puertos con SSL activo.
# -----------------------------------------------------------------------------
ssl_apache_actualizar_puertos() {
    local http_port="$1"
    local https_port="$2"

    msg_info "Actualizando puertos en ssl-reprobados.conf..."
    msg_info "  HTTP  : ${http_port}/tcp"
    msg_info "  HTTPS : ${https_port}/tcp"

    # Necesita SSL_CERT_CN — si no está en el entorno, leerlo del certificado
    if [[ -z "${SSL_CERT_CN:-}" ]]; then
        SSL_CERT_CN=$(sudo openssl x509 -in "${SSL_DIR_APACHE}/${SSL_CERT_FILE}" \
                      -noout -subject 2>/dev/null \
                      | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 | xargs)
    fi

    # Registrar puerto HTTPS en SELinux (Apache falla con Permission denied
    # en puertos no registrados como http_port_t)
    _http_registrar_puerto_selinux "$https_port" 2>/dev/null || true

    _ssl_apache_escribir_conf "$http_port" "$https_port" || return 1

    if ! _ssl_apache_verificar_sintaxis; then
        msg_error "Error de sintaxis — rollback"
        return 1
    fi

    # NO reiniciar aquí — ws_config.sh hace el restart único en PASO 4
    _ssl_apache_abrir_firewall "$https_port"
    msg_success "Puertos Apache SSL actualizados: HTTP=${http_port} HTTPS=${https_port}"
    return 0
}

# -----------------------------------------------------------------------------
# ssl_configurar_apache  (pública)
# -----------------------------------------------------------------------------
ssl_configurar_apache() {
    separator
    msg_info "Configuración SSL/TLS — Apache (httpd)"
    separator
    echo ""

    if ! rpm -q httpd &>/dev/null; then
        msg_error "Apache no está instalado"
        return 1
    fi

    msg_info "PASO 1/7 — Verificar mod_ssl"
    _ssl_apache_verificar_mod_ssl || return 1
    echo ""

    local http_port; http_port=$(_ssl_apache_leer_puerto_http)

    msg_info "PASO 2/7 — Datos del certificado"
    ssl_recopilar_datos_certificado "Apache" || return 1
    echo ""

    msg_info "PASO 3/7 — Puerto HTTPS"
    local https_port
    ssl_seleccionar_puerto_https "Apache" "$http_port" https_port || return 1
    echo ""

    msg_input "¿Confirmar configuración SSL para Apache? [S/N]: "; read -r _conf
    [[ ! "${_conf^^}" =~ ^(S|SI|Y|YES)$ ]] && { msg_info "Cancelado"; return 0; }
    echo ""

    msg_info "PASO 4/7 — Generar certificado"
    ssl_generar_certificado "$SSL_DIR_APACHE" "Apache" || return 1
    echo ""

    msg_info "PASO 5/7 — Registrar puertos en SELinux"
    _http_registrar_puerto_selinux "$https_port" 2>/dev/null || true
    echo ""

    msg_info "PASO 6/7 — Escribir configuración SSL"
    _ssl_apache_escribir_conf "$http_port" "$https_port" || return 1
    echo ""

    msg_info "PASO 6/7 — Verificar sintaxis"
    if ! _ssl_apache_verificar_sintaxis; then
        msg_error "Rollback: eliminando ssl-reprobados.conf"
        sudo rm -f "$_SSL_APACHE_CONF"
        return 1
    fi
    echo ""

    msg_info "PASO 8/8 — Reiniciar y verificar"
    if ! sudo systemctl restart httpd 2>/dev/null; then
        msg_error "Apache no levantó — revise: sudo journalctl -u httpd -n 30"
        return 1
    fi
    sleep 2

    if ! sudo systemctl is-active --quiet httpd; then
        msg_error "Apache inactivo tras el reinicio"
        return 1
    fi
    msg_success "Apache activo con SSL"

    _ssl_apache_abrir_firewall "$https_port"
    echo ""

    local resp_code
    resp_code=$(curl -sk -o /dev/null -w "%{http_code}" \
                "https://localhost:${https_port}" 2>/dev/null)
    if [[ "$resp_code" =~ ^(200|301|302|400|404)$ ]]; then
        msg_success "HTTPS responde: HTTP ${resp_code}"
    else
        msg_alert "HTTPS devolvió ${resp_code} — verifique: curl -kv https://localhost:${https_port}"
    fi

    separator
    msg_success "SSL/TLS configurado en Apache"
    separator
    echo ""
    printf "    Certificado : %s/%s\n" "$SSL_DIR_APACHE" "$SSL_CERT_FILE"
    printf "    Config SSL  : %s\n"    "$_SSL_APACHE_CONF"
    printf "    HTTP  :%s  → redirect HTTPS\n" "$http_port"
    printf "    HTTPS :%s  (activo)\n" "$https_port"
    echo ""

    # Exportar puertos para que el hook SSL actualice el index.html
    export _SSL_LAST_HTTP_PORT="$http_port"
    export _SSL_LAST_HTTPS_PORT="$https_port"
    return 0
}

ssl_desactivar_apache() {
    msg_alert "Desactivando SSL en Apache..."
    if [[ -f "$_SSL_APACHE_CONF" ]]; then
        sudo mv "$_SSL_APACHE_CONF" "${_SSL_APACHE_CONF}.disabled_$(date +%Y%m%d_%H%M%S)"
        msg_success "ssl-reprobados.conf desactivado"
    fi
    _ssl_apache_verificar_sintaxis && sudo systemctl restart httpd &>/dev/null \
        && msg_success "Apache reiniciado sin SSL"
}

export -f ssl_configurar_apache
export -f ssl_desactivar_apache
export -f ssl_apache_actualizar_puertos
export -f _ssl_apache_leer_puerto_http
export -f _ssl_apache_leer_puerto_https
export -f _ssl_apache_verificar_mod_ssl
export -f _ssl_apache_escribir_conf
export -f _ssl_apache_verificar_sintaxis
export -f _ssl_apache_abrir_firewall