#!/bin/bash
# =============================================================================
# ssl_lib/ssl_nginx.sh — SSL/TLS para Nginx
#
# Estrategia: python3 modifica nginx.conf insertando el bloque HTTPS dentro
# de http{} y agregando return 301 en el server block HTTP existente.
#
# Redirect: usa https://$host:PUERTO$request_uri donde $host es la variable
# Nginx que refleja exactamente el header Host: del cliente — funciona
# correctamente independientemente de cuántas interfaces tenga el servidor.
# =============================================================================

readonly _SSL_NGINX_CONF="/etc/nginx/nginx.conf"
readonly _SSL_NGINX_MARCA="# === ssl_manager: SSL block ==="

# -----------------------------------------------------------------------------
# _ssl_nginx_leer_puerto_http  (interna)
# -----------------------------------------------------------------------------
_ssl_nginx_leer_puerto_http() {
    local puerto
    puerto=$(sudo grep -E "^\s+listen\s+[0-9]+;" "$_SSL_NGINX_CONF" 2>/dev/null \
             | grep -oP '\d+' | head -1)
    echo "${puerto:-80}"
}

# -----------------------------------------------------------------------------
# _ssl_nginx_leer_puerto_https  (interna)
# -----------------------------------------------------------------------------
_ssl_nginx_leer_puerto_https() {
    local puerto
    puerto=$(sudo grep -A3 "$_SSL_NGINX_MARCA" "$_SSL_NGINX_CONF" 2>/dev/null \
             | grep -oP "listen\s+\K[0-9]+" | head -1)
    echo "${puerto:-443}"
}

# -----------------------------------------------------------------------------
# _ssl_nginx_webroot  (interna)
# -----------------------------------------------------------------------------
_ssl_nginx_webroot() {
    local root
    root=$(sudo grep -E "^\s+root\s+" "$_SSL_NGINX_CONF" 2>/dev/null \
           | awk '{print $2}' | tr -d ';' | head -1)
    echo "${root:-/usr/share/nginx/html}"
}

# -----------------------------------------------------------------------------
# _ssl_nginx_ssl_activo  (interna)
# Verifica si el bloque SSL de ssl_manager está en nginx.conf.
# Más fiable que buscar la marca desde ws_config.sh.
# -----------------------------------------------------------------------------
_ssl_nginx_ssl_activo() {
    sudo grep -q "$_SSL_NGINX_MARCA" "$_SSL_NGINX_CONF" 2>/dev/null
}

# -----------------------------------------------------------------------------
# _ssl_nginx_registrar_selinux  (interna)
# Registra el puerto HTTPS en SELinux como http_port_t.
# Sin esto Nginx falla con bind() Permission denied en puertos no estándar.
# -----------------------------------------------------------------------------
_ssl_nginx_registrar_selinux() {
    local puerto="$1"

    command -v getenforce &>/dev/null || return 0
    [[ "$(getenforce 2>/dev/null)" == "Disabled" ]] && return 0

    local puertos_default=(80 443 8008 8009 8080 8443)
    local p
    for p in "${puertos_default[@]}"; do
        [[ "$puerto" == "$p" ]] && return 0
    done

    if sudo semanage port -l 2>/dev/null \
       | grep -E "^http_port_t\s" | grep -qw "$puerto"; then
        msg_info "Puerto ${puerto} ya registrado en SELinux como http_port_t"
        return 0
    fi

    if ! command -v semanage &>/dev/null; then
        msg_alert "Instalando policycoreutils-python-utils..."
        sudo dnf install -y policycoreutils-python-utils &>/dev/null || {
            msg_error "No se pudo instalar semanage — Nginx fallará en puerto ${puerto}"
            return 1
        }
    fi

    msg_process "Registrando puerto ${puerto}/tcp en SELinux como http_port_t..."
    if sudo semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
       sudo semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null; then
        msg_success "Puerto ${puerto}/tcp registrado en SELinux"
        return 0
    fi

    msg_error "No se pudo registrar puerto ${puerto} en SELinux"
    return 1
}

# -----------------------------------------------------------------------------
# _ssl_nginx_aplicar_python  (interna)
#
# Modifica nginx.conf via python3. Idempotente.
#
# Redirect: usa $host (header Host: del cliente sin puerto).
# El server block HTTP usa server_name con todas las IPs del servidor
# para que Nginx capture la petición independientemente del adaptador.
# -----------------------------------------------------------------------------
_ssl_nginx_aplicar_python() {
    local http_port="$1"
    local https_port="$2"
    local cert_path="$3"
    local key_path="$4"
    local server_name="$5"
    local webroot="$6"
    local marca="$7"
    # Obtener todas las IPs del servidor para server_name del bloque HTTP
    local server_ips
    server_ips=$(hostname -I 2>/dev/null | tr " " "\n" | grep -v "^$" | tr "\n" " " | xargs)
    [[ -z "$server_ips" ]] && server_ips="localhost"

    local ts; ts=$(date +%Y%m%d_%H%M%S)
    sudo cp "$_SSL_NGINX_CONF" "${_SSL_NGINX_CONF}.bak_${ts}"
    msg_success "Backup: ${_SSL_NGINX_CONF}.bak_${ts}"

    local tmpconf; tmpconf=$(mktemp /tmp/nginx_conf_XXXXXX.conf)
    sudo cp "$_SSL_NGINX_CONF" "$tmpconf"
    sudo chmod 644 "$tmpconf"

    python3 - "$tmpconf" \
              "$http_port" "$https_port" \
              "$cert_path" "$key_path" \
              "$server_name" "$webroot" "$marca" "$server_ips" << 'PYEOF'
import sys, re

conf_file   = sys.argv[1]
http_port   = sys.argv[2]
https_port  = sys.argv[3]
cert_path   = sys.argv[4]
key_path    = sys.argv[5]
server_name = sys.argv[6]
webroot     = sys.argv[7]
marca       = sys.argv[8]
server_ips  = sys.argv[9]  # IPs del servidor separadas por espacio

with open(conf_file) as f:
    content = f.read()

# 1. Eliminar bloques SSL anteriores (idempotencia)
marca_esc = re.escape(marca)
content = re.sub(
    r'\n?\s*' + marca_esc + r'.*?' + marca_esc,
    '',
    content,
    flags=re.DOTALL
)

# 2. Eliminar return 301 anterior del server block HTTP
def remove_redirect_from_server(text, port):
    result = []
    i = 0
    while i < len(text):
        m = re.search(r'\bserver\s*\{', text[i:])
        if not m:
            result.append(text[i:])
            break
        result.append(text[i:i+m.end()])
        i += m.end()
        depth = 1
        start = i
        while i < len(text) and depth > 0:
            if text[i] == '{': depth += 1
            elif text[i] == '}': depth -= 1
            i += 1
        block = text[start:i-1]
        if re.search(r'listen\s+' + re.escape(port) + r'[;\s]', block):
            block = re.sub(r'\n\s*return 301[^\n]*', '', block)
        result.append(block + '}')
    return ''.join(result)

content = remove_redirect_from_server(content, http_port)

# 3. Agregar return 301 en el server block HTTP existente
# $server_addr = IP local del servidor en la que llegó la conexión.
# Es la variable correcta cuando se accede desde fuera por IP:
# - No incluye el puerto (a diferencia de $http_host)
# - Siempre refleja la IP real del adaptador, no _ ni el CN
redirect_line = f'        return 301 https://$host:{https_port}$request_uri;'

def add_redirect_to_server(text, port, redirect, ips):
    result = []
    i = 0
    modified = False
    while i < len(text):
        m = re.search(r'\bserver\s*\{', text[i:])
        if not m:
            result.append(text[i:])
            break
        result.append(text[i:i+m.end()])
        i += m.end()
        depth = 1
        start = i
        while i < len(text) and depth > 0:
            if text[i] == '{': depth += 1
            elif text[i] == '}': depth -= 1
            i += 1
        block = text[start:i-1]
        if re.search(r'listen\s+' + re.escape(port) + r'[;\s]', block) and not modified:
            # Reemplazar server_name _ por todas las IPs del servidor
            # $host con server_name _ devuelve "_" — con IPs reales devuelve
            # el hostname/IP que el cliente uso para conectarse
            block = re.sub(r'server_name\s+[^;]+;', f'server_name {ips};', block)
            loc = re.search(r'\blocation\s*[/\w]', block)
            if loc:
                block = block[:loc.start()] + redirect + '\n\n        ' + block[loc.start():]
            else:
                block = block.rstrip() + '\n' + redirect + '\n    '
            modified = True
        result.append(block + '}')
    if not modified:
        print(f'WARN: no se encontro server block con listen {port}')
    return ''.join(result)

content = add_redirect_to_server(content, http_port, redirect_line, server_ips)

# 4. Bloque HTTPS
ssl_block = f"""
    {marca}
    server {{
        listen {https_port} ssl;
        listen [::]:{https_port} ssl;
        server_name {server_name};
        root        {webroot};
        index       index.html index.htm;

        ssl_certificate     {cert_path};
        ssl_certificate_key {key_path};

        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5:!RC4:!DES:!3DES;
        ssl_prefer_server_ciphers on;
        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 10m;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header X-XSS-Protection "1; mode=block" always;

        server_tokens off;

        location / {{
            try_files $uri $uri/ =404;
        }}

        error_log  /var/log/nginx/ssl_error.log;
        access_log /var/log/nginx/ssl_access.log;
    }}
    {marca}
"""

# 5. Insertar antes del cierre de http{}
m_http = re.search(r'\bhttp\s*\{', content)
if not m_http:
    print('ERROR: no se encontro bloque http{} en nginx.conf')
    sys.exit(1)

depth = 1
pos = m_http.end()
while pos < len(content) and depth > 0:
    if content[pos] == '{': depth += 1
    elif content[pos] == '}': depth -= 1
    pos += 1

close_pos = pos - 1
content = content[:close_pos] + ssl_block + content[close_pos:]

with open(conf_file, 'w') as f:
    f.write(content)

print('OK')
PYEOF

    local py_rc=$?
    if [[ $py_rc -ne 0 ]]; then
        msg_error "Error en python3 — restaurando nginx.conf"
        sudo cp "${_SSL_NGINX_CONF}.bak_${ts}" "$_SSL_NGINX_CONF"
        rm -f "$tmpconf"
        return 1
    fi

    sudo cp "$tmpconf" "$_SSL_NGINX_CONF"
    sudo chown root:root "$_SSL_NGINX_CONF"
    sudo chmod 644 "$_SSL_NGINX_CONF"
    rm -f "$tmpconf"
    return 0
}

_ssl_nginx_verificar_sintaxis() {
    msg_process "Verificando sintaxis Nginx..."
    local out; out=$(sudo nginx -t 2>&1)
    if echo "$out" | grep -q "syntax is ok"; then
        msg_success "Sintaxis: OK"
        return 0
    fi
    msg_error "Error de sintaxis:"
    echo "$out" | sed 's/^/    /'
    return 1
}

_ssl_nginx_abrir_firewall() {
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
# ssl_nginx_actualizar_puertos  (pública)
# -----------------------------------------------------------------------------
ssl_nginx_actualizar_puertos() {
    local http_port="$1"
    local https_port="$2"

    msg_info "Actualizando puertos Nginx SSL..."
    msg_info "  HTTP  : ${http_port}/tcp"
    msg_info "  HTTPS : ${https_port}/tcp"

    if [[ -z "${SSL_CERT_CN:-}" ]]; then
        SSL_CERT_CN=$(sudo openssl x509 -in "${SSL_DIR_NGINX}/${SSL_CERT_FILE}" \
                      -noout -subject 2>/dev/null \
                      | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 | xargs)
    fi

    local webroot; webroot=$(_ssl_nginx_webroot)

    _ssl_nginx_registrar_selinux "$https_port" || return 1

    _ssl_nginx_aplicar_python \
        "$http_port" "$https_port" \
        "${SSL_DIR_NGINX}/${SSL_CERT_FILE}" \
        "${SSL_DIR_NGINX}/${SSL_KEY_FILE}" \
        "$SSL_CERT_CN" "$webroot" "$_SSL_NGINX_MARCA" || return 1

    if ! _ssl_nginx_verificar_sintaxis; then
        msg_error "Error de sintaxis — rollback"
        local bak; bak=$(ls -t "${_SSL_NGINX_CONF}.bak_"* 2>/dev/null | head -1)
        [[ -n "$bak" ]] && sudo cp "$bak" "$_SSL_NGINX_CONF"
        return 1
    fi

    # NO reiniciar aquí — ws_config.sh hace el restart único en PASO 4
    _ssl_nginx_abrir_firewall "$https_port"
    msg_success "Puertos Nginx SSL actualizados: HTTP=${http_port} HTTPS=${https_port}"
    return 0
}

# -----------------------------------------------------------------------------
# ssl_configurar_nginx  (pública)
# -----------------------------------------------------------------------------
ssl_configurar_nginx() {
    separator
    msg_info "Configuración SSL/TLS — Nginx"
    separator
    echo ""

    if ! rpm -q nginx &>/dev/null; then
        msg_error "Nginx no está instalado"
        return 1
    fi

    local http_port; http_port=$(_ssl_nginx_leer_puerto_http)
    local webroot;   webroot=$(_ssl_nginx_webroot)

    msg_info "PASO 1/6 — Datos del certificado"
    ssl_recopilar_datos_certificado "Nginx" || return 1
    echo ""

    msg_info "PASO 2/6 — Puerto HTTPS"
    local https_port
    ssl_seleccionar_puerto_https "Nginx" "$http_port" https_port || return 1
    echo ""

    msg_input "¿Confirmar configuración SSL para Nginx? [S/N]: "; read -r _conf
    [[ ! "${_conf^^}" =~ ^(S|SI|Y|YES)$ ]] && { msg_info "Cancelado"; return 0; }
    echo ""

    msg_info "PASO 3/6 — Generar certificado"
    ssl_generar_certificado "$SSL_DIR_NGINX" "Nginx" || return 1
    sudo chown root:nginx "${SSL_DIR_NGINX}" 2>/dev/null || true
    sudo chmod 750 "${SSL_DIR_NGINX}"
    sudo chown root:nginx "${SSL_DIR_NGINX}/${SSL_CERT_FILE}" \
                          "${SSL_DIR_NGINX}/${SSL_KEY_FILE}" 2>/dev/null || true
    sudo chmod 640 "${SSL_DIR_NGINX}/${SSL_CERT_FILE}" \
                   "${SSL_DIR_NGINX}/${SSL_KEY_FILE}"
    msg_success "Permisos ajustados para usuario nginx (dir:750 files:640)"
    echo ""

    msg_info "PASO 4/6 — Registrar puerto en SELinux"
    _ssl_nginx_registrar_selinux "$https_port" || return 1
    echo ""

    msg_info "PASO 5/6 — Modificar nginx.conf"
    _ssl_nginx_aplicar_python \
        "$http_port" "$https_port" \
        "${SSL_DIR_NGINX}/${SSL_CERT_FILE}" \
        "${SSL_DIR_NGINX}/${SSL_KEY_FILE}" \
        "$SSL_CERT_CN" "$webroot" "$_SSL_NGINX_MARCA" || return 1
    echo ""

    msg_info "PASO 6/6 — Verificar sintaxis y reiniciar"
    if ! _ssl_nginx_verificar_sintaxis; then
        msg_error "Rollback: restaurando nginx.conf"
        local bak; bak=$(ls -t "${_SSL_NGINX_CONF}.bak_"* 2>/dev/null | head -1)
        [[ -n "$bak" ]] && sudo cp "$bak" "$_SSL_NGINX_CONF"
        return 1
    fi

    if ! sudo systemctl restart nginx 2>/dev/null; then
        msg_error "Nginx no levantó — revise: sudo journalctl -u nginx -n 30"
        return 1
    fi
    sleep 2

    if ! sudo systemctl is-active --quiet nginx; then
        msg_error "Nginx inactivo tras el reinicio"
        return 1
    fi
    msg_success "Nginx activo con SSL"

    _ssl_nginx_abrir_firewall "$https_port"
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
    msg_success "SSL/TLS configurado en Nginx"
    separator
    echo ""
    printf "    Certificado : %s/%s\n" "$SSL_DIR_NGINX" "$SSL_CERT_FILE"
    printf "    HTTP  :%s  → redirect HTTPS\n" "$http_port"
    printf "    HTTPS :%s  (activo)\n" "$https_port"
    echo ""

    export _SSL_LAST_HTTP_PORT="$http_port"
    export _SSL_LAST_HTTPS_PORT="$https_port"
    return 0
}

# -----------------------------------------------------------------------------
# ssl_desactivar_nginx  (pública)
# -----------------------------------------------------------------------------
ssl_desactivar_nginx() {
    msg_alert "Desactivando SSL en Nginx..."
    local bak; bak=$(ls -t "${_SSL_NGINX_CONF}.bak_"* 2>/dev/null | head -1)
    if [[ -n "$bak" ]]; then
        sudo cp "$bak" "$_SSL_NGINX_CONF"
        msg_success "nginx.conf restaurado desde: $(basename "$bak")"
    else
        local tmpconf; tmpconf=$(mktemp)
        sudo cp "$_SSL_NGINX_CONF" "$tmpconf"
        sudo chmod 644 "$tmpconf"
        python3 - "$tmpconf" "$_SSL_NGINX_MARCA" << 'PYEOF'
import sys, re
path  = sys.argv[1]
marca = sys.argv[2]
with open(path) as f:
    content = f.read()
marca_esc = re.escape(marca)
content = re.sub(r'\n?\s*' + marca_esc + r'.*?' + marca_esc, '',
                 content, flags=re.DOTALL)
content = re.sub(r'\n\s*return 301[^\n]*', '', content)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        sudo cp "$tmpconf" "$_SSL_NGINX_CONF"
        rm -f "$tmpconf"
        msg_success "Bloques SSL eliminados de nginx.conf"
    fi

    _ssl_nginx_verificar_sintaxis && sudo systemctl restart nginx &>/dev/null \
        && msg_success "Nginx reiniciado sin SSL"
}

export -f ssl_configurar_nginx
export -f ssl_desactivar_nginx
export -f ssl_nginx_actualizar_puertos
export -f _ssl_nginx_ssl_activo
export -f _ssl_nginx_leer_puerto_http
export -f _ssl_nginx_leer_puerto_https
export -f _ssl_nginx_webroot
export -f _ssl_nginx_registrar_selinux
export -f _ssl_nginx_aplicar_python
export -f _ssl_nginx_verificar_sintaxis
export -f _ssl_nginx_abrir_firewall