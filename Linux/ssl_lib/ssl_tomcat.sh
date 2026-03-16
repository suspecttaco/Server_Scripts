#!/bin/bash
# =============================================================================
# ssl_lib/ssl_tomcat.sh — SSL/TLS para Apache Tomcat
# =============================================================================

_SSL_TOMCAT_HOME="${CATALINA_HOME:-/usr/share/tomcat}"
_SSL_TOMCAT_SERVER_XML="${_SSL_TOMCAT_HOME}/conf/server.xml"
_SSL_TOMCAT_KEYSTORE="${SSL_DIR_TOMCAT}/keystore.p12"
_SSL_TOMCAT_KEYSTORE_PASS=""

_ssl_tomcat_leer_puerto_http() {
    sudo grep -oP 'Connector port="\K[0-9]+(?="[^>]*protocol="HTTP)' \
         "$_SSL_TOMCAT_SERVER_XML" 2>/dev/null | head -1 || echo "8080"
}

_ssl_tomcat_leer_puerto_https() {
    # Lee el puerto del Connector HTTPS insertado por ssl_manager
    sudo grep -A5 "ssl_manager: HTTPS Connector" "$_SSL_TOMCAT_SERVER_XML" 2>/dev/null \
        | grep -oP 'port="\K[0-9]+' | head -1 || echo "8443"
}

_ssl_tomcat_detectar_webroot() {
    local candidatos=(
        "/var/lib/tomcat/webapps/ROOT"
        "/usr/share/tomcat/webapps/ROOT"
        "${_SSL_TOMCAT_HOME}/webapps/ROOT"
    )
    local c
    for c in "${candidatos[@]}"; do
        [[ -d "$c" ]] && echo "$c" && return 0
    done
    echo "/var/lib/tomcat/webapps/ROOT"
}

_ssl_tomcat_pedir_keystore_pass() {
    local __var="$1"
    while true; do
        echo ""
        msg_info "Contraseña del KeyStore PKCS12 (mínimo 6 caracteres)"
        msg_input "Contraseña: "; read -rs p1; echo
        [[ ${#p1} -lt 6 ]] && { msg_error "Mínimo 6 caracteres"; continue; }
        msg_input "Confirmar : "; read -rs p2; echo
        [[ "$p1" != "$p2" ]] && { msg_error "No coinciden"; continue; }
        printf -v "$__var" "%s" "$p1"
        return 0
    done
}

_ssl_tomcat_crear_keystore() {
    local cert_path="${SSL_DIR_TOMCAT}/${SSL_CERT_FILE}"
    local key_path="${SSL_DIR_TOMCAT}/${SSL_KEY_FILE}"
    local pass="$_SSL_TOMCAT_KEYSTORE_PASS"
    local alias="${SSL_CERT_CN:-tomcat}"

    msg_process "Generando KeyStore PKCS12..."
    [[ -f "$_SSL_TOMCAT_KEYSTORE" ]] && sudo rm -f "$_SSL_TOMCAT_KEYSTORE"

    if sudo openssl pkcs12 -export \
            -in  "$cert_path" -inkey "$key_path" \
            -out "$_SSL_TOMCAT_KEYSTORE" \
            -name "$alias" -passout "pass:${pass}" 2>/dev/null; then
        if getent group tomcat &>/dev/null; then
            sudo chown root:tomcat "$_SSL_TOMCAT_KEYSTORE"
            sudo chmod 640 "$_SSL_TOMCAT_KEYSTORE"
            msg_success "KeyStore: ${_SSL_TOMCAT_KEYSTORE} (root:tomcat 640)"
        else
            sudo chmod 644 "$_SSL_TOMCAT_KEYSTORE"
            msg_success "KeyStore: ${_SSL_TOMCAT_KEYSTORE} (644)"
        fi
        return 0
    fi

    msg_error "Error al generar KeyStore PKCS12"
    return 1
}

# -----------------------------------------------------------------------------
# _ssl_tomcat_modificar_server_xml  (interna)
# Python3 — idempotente, elimina Connector anterior antes de insertar.
# -----------------------------------------------------------------------------
_ssl_tomcat_modificar_server_xml() {
    local https_port="$1"
    local pass="$2"

    if [[ ! -f "$_SSL_TOMCAT_SERVER_XML" ]]; then
        msg_error "server.xml no encontrado: ${_SSL_TOMCAT_SERVER_XML}"
        return 1
    fi

    msg_process "Modificando server.xml..."

    local ts; ts=$(date +%Y%m%d_%H%M%S)
    sudo cp "$_SSL_TOMCAT_SERVER_XML" "${_SSL_TOMCAT_SERVER_XML}.bak_${ts}"
    msg_success "Backup: ${_SSL_TOMCAT_SERVER_XML}.bak_${ts}"

    local tmpxml; tmpxml=$(mktemp /tmp/server_xml_XXXXXX.xml)
    sudo cp "$_SSL_TOMCAT_SERVER_XML" "$tmpxml"
    sudo chmod 644 "$tmpxml"

    python3 - "$tmpxml" "$https_port" "$_SSL_TOMCAT_KEYSTORE" "$pass" << 'PYEOF'
import sys, re

xml_path   = sys.argv[1]
https_port = sys.argv[2]
keystore   = sys.argv[3]
ks_pass    = sys.argv[4]

with open(xml_path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Eliminar Connector HTTPS anterior (idempotencia)
content = re.sub(
    r'\s*<!-- ssl_manager: HTTPS Connector -->.*?<!-- /ssl_manager -->',
    '',
    content,
    flags=re.DOTALL
)

# 2. Actualizar redirectPort en el Connector HTTP
content = re.sub(
    r'(redirectPort=")[0-9]+(")',
    rf'\g<1>{https_port}\g<2>',
    content
)

# 3. Nuevo Connector HTTPS con PKCS12
connector = (
    '\n    <!-- ssl_manager: HTTPS Connector -->'
    f'\n    <Connector port="{https_port}"'
    '\n               protocol="org.apache.coyote.http11.Http11NioProtocol"'
    '\n               SSLEnabled="true"'
    '\n               maxThreads="150"'
    '\n               scheme="https"'
    '\n               secure="true">'
    '\n        <SSLHostConfig protocols="TLSv1.2+TLSv1.3">'
    f'\n            <Certificate certificateKeystoreFile="{keystore}"'
    f'\n                         certificateKeystorePassword="{ks_pass}"'
    '\n                         certificateKeystoreType="PKCS12"'
    '\n                         type="RSA" />'
    '\n        </SSLHostConfig>'
    '\n    </Connector>'
    '\n    <!-- /ssl_manager -->'
)

if '</Service>' not in content:
    print('ERROR: no se encontro </Service>')
    sys.exit(1)

content = content.replace('</Service>', connector + '\n  </Service>', 1)

with open(xml_path, 'w', encoding='utf-8') as f:
    f.write(content)

print('OK')
PYEOF

    local py_rc=$?
    if [[ $py_rc -ne 0 ]]; then
        msg_error "Error en python3 — restaurando server.xml"
        sudo cp "${_SSL_TOMCAT_SERVER_XML}.bak_${ts}" "$_SSL_TOMCAT_SERVER_XML"
        rm -f "$tmpxml"
        return 1
    fi

    sudo cp "$tmpxml" "$_SSL_TOMCAT_SERVER_XML"
    if getent group tomcat &>/dev/null; then
        sudo chown root:tomcat "$_SSL_TOMCAT_SERVER_XML"
        sudo chmod 640 "$_SSL_TOMCAT_SERVER_XML"
    else
        sudo chmod 644 "$_SSL_TOMCAT_SERVER_XML"
    fi
    rm -f "$tmpxml"

    msg_success "Connector HTTPS en server.xml (puerto ${https_port})"
    return 0
}

_ssl_tomcat_configurar_webxml() {
    local webroot; webroot=$(_ssl_tomcat_detectar_webroot)
    local webxml="${webroot}/WEB-INF/web.xml"

    msg_process "Configurando redirect CONFIDENTIAL en web.xml..."

    if [[ ! -f "$webxml" ]]; then
        msg_info "web.xml no encontrado — creando estructura mínima..."
        sudo mkdir -p "$(dirname "$webxml")"
        sudo tee "$webxml" > /dev/null << 'WEBBASE'
<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns="https://jakarta.ee/xml/ns/jakartaee"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="https://jakarta.ee/xml/ns/jakartaee
         https://jakarta.ee/xml/ns/jakartaee/web-app_6_0.xsd"
         version="6.0">
</web-app>
WEBBASE
    fi

    if sudo grep -q "ssl_manager: redirect" "$webxml" 2>/dev/null; then
        msg_info "Redirect CONFIDENTIAL ya configurado"
        return 0
    fi

    local ts; ts=$(date +%Y%m%d_%H%M%S)
    sudo cp "$webxml" "${webxml}.bak_${ts}"

    local tmpwebxml; tmpwebxml=$(mktemp /tmp/web_xml_XXXXXX.xml)
    sudo cp "$webxml" "$tmpwebxml"
    sudo chmod 644 "$tmpwebxml"

    python3 - "$tmpwebxml" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

block = """
  <!-- ssl_manager: redirect HTTP→HTTPS -->
  <security-constraint>
    <web-resource-collection>
      <web-resource-name>Redirect HTTP to HTTPS</web-resource-name>
      <url-pattern>/*</url-pattern>
    </web-resource-collection>
    <user-data-constraint>
      <transport-guarantee>CONFIDENTIAL</transport-guarantee>
    </user-data-constraint>
  </security-constraint>
  <!-- /ssl_manager: redirect -->
"""

if '</web-app>' not in content:
    print('ERROR: no se encontro </web-app>')
    sys.exit(1)

content = content.replace('</web-app>', block + '</web-app>', 1)
with open(path, 'w') as f:
    f.write(content)
print('OK')
PYEOF

    if [[ $? -ne 0 ]]; then
        msg_error "Error al modificar web.xml"
        sudo cp "${webxml}.bak_${ts}" "$webxml"
        rm -f "$tmpwebxml"
        return 1
    fi

    sudo cp "$tmpwebxml" "$webxml"
    rm -f "$tmpwebxml"
    msg_success "Redirect CONFIDENTIAL en web.xml"
    return 0
}

_ssl_tomcat_abrir_firewall() {
    local puerto="$1"
    command -v firewall-cmd &>/dev/null || return 0
    sudo systemctl is-active --quiet firewalld 2>/dev/null || return 0
    msg_process "Abriendo ${puerto}/tcp en firewalld..."
    sudo firewall-cmd --permanent --add-port="${puerto}/tcp" &>/dev/null || true
    sudo firewall-cmd --reload &>/dev/null
    msg_success "Puerto ${puerto}/tcp abierto"
}

_ssl_tomcat_reiniciar_esperar() {
    local https_port="$1"
    msg_process "Reiniciando Tomcat (puede tardar hasta 30s)..."
    sudo systemctl stop tomcat 2>/dev/null || true
    sleep 2
    if ! sudo systemctl start tomcat 2>/dev/null; then
        msg_error "Tomcat no levantó — revise: sudo journalctl -u tomcat -n 30"
        return 1
    fi

    local intentos=0 listo=false
    while (( intentos < 15 )); do
        sleep 2
        (( intentos++ ))
        if sudo ss -tlnp 2>/dev/null | grep -q ":${https_port}"; then
            listo=true; break
        fi
        printf "    Intento %d/15 — puerto %s aún no disponible...\n" \
               "$intentos" "$https_port"
    done

    if $listo; then
        msg_success "Tomcat activo — puerto ${https_port} listo"
    else
        msg_alert "Tomcat arrancó pero ${https_port} no responde aún"
        msg_info "Verifique: sudo journalctl -u tomcat -n 20"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# ssl_tomcat_actualizar_puertos  (pública)
# Actualiza el puerto HTTPS de Tomcat.
# Regenera el keystore con la nueva contraseña que proporciona el usuario.
# El certificado existente se reutiliza — no se regenera.
# -----------------------------------------------------------------------------
ssl_tomcat_actualizar_puertos() {
    local https_port="$1"

    msg_info "Actualizando puerto HTTPS Tomcat → ${https_port}/tcp"

    # Verificar que el certificado existe
    if [[ ! -f "${SSL_DIR_TOMCAT}/${SSL_CERT_FILE}" ]]; then
        msg_error "No se encontró certificado en ${SSL_DIR_TOMCAT}"
        msg_info  "Configure SSL desde cero: ssl_manager → Configurar SSL → Tomcat"
        return 1
    fi

    # Pedir nueva contraseña para el keystore
    # No reutilizamos la anterior — el usuario debe ingresarla de nuevo
    # para evitar el error "keystore password was incorrect"
    local pass
    _ssl_tomcat_pedir_keystore_pass pass || return 1
    _SSL_TOMCAT_KEYSTORE_PASS="$pass"

    # Regenerar el keystore PKCS12 con la nueva contraseña
    # Esto garantiza que Tomcat pueda abrirlo correctamente
    msg_info "Regenerando KeyStore PKCS12 con nueva contraseña..."
    _ssl_tomcat_crear_keystore || return 1
    echo ""

    _ssl_tomcat_modificar_server_xml "$https_port" "$pass" || return 1
    _ssl_tomcat_abrir_firewall "$https_port"
    _ssl_tomcat_reiniciar_esperar "$https_port"

    msg_success "Puerto HTTPS Tomcat actualizado: ${https_port}/tcp"
    return 0
}

# -----------------------------------------------------------------------------
# ssl_configurar_tomcat  (pública)
# -----------------------------------------------------------------------------
ssl_configurar_tomcat() {
    separator
    msg_info "Configuración SSL/TLS — Tomcat"
    separator
    echo ""

    if ! rpm -q tomcat &>/dev/null; then
        msg_error "Tomcat no está instalado"
        return 1
    fi

    _SSL_TOMCAT_HOME="${CATALINA_HOME:-/usr/share/tomcat}"
    _SSL_TOMCAT_SERVER_XML="${_SSL_TOMCAT_HOME}/conf/server.xml"
    _SSL_TOMCAT_KEYSTORE="${SSL_DIR_TOMCAT}/keystore.p12"

    local http_port; http_port=$(_ssl_tomcat_leer_puerto_http)

    msg_info "PASO 1/7 — Datos del certificado"
    ssl_recopilar_datos_certificado "Tomcat" || return 1
    echo ""

    msg_info "PASO 2/7 — Puerto HTTPS"
    local https_port
    ssl_seleccionar_puerto_https "Tomcat" "$http_port" https_port || return 1
    echo ""

    msg_info "PASO 3/7 — Contraseña del KeyStore"
    _ssl_tomcat_pedir_keystore_pass _SSL_TOMCAT_KEYSTORE_PASS || return 1
    echo ""

    msg_input "¿Confirmar configuración SSL para Tomcat? [S/N]: "; read -r _conf
    [[ ! "${_conf^^}" =~ ^(S|SI|Y|YES)$ ]] && { msg_info "Cancelado"; return 0; }
    echo ""

    msg_info "PASO 4/7 — Generar certificado"
    ssl_generar_certificado "$SSL_DIR_TOMCAT" "Tomcat" || return 1
    sudo chown root:tomcat "${SSL_DIR_TOMCAT}" 2>/dev/null || true
    sudo chmod 750 "${SSL_DIR_TOMCAT}"
    sudo chown root:tomcat "${SSL_DIR_TOMCAT}/${SSL_CERT_FILE}" \
                           "${SSL_DIR_TOMCAT}/${SSL_KEY_FILE}" 2>/dev/null || true
    sudo chmod 640 "${SSL_DIR_TOMCAT}/${SSL_CERT_FILE}" \
                   "${SSL_DIR_TOMCAT}/${SSL_KEY_FILE}"
    msg_success "Permisos ajustados para usuario tomcat"
    echo ""

    msg_info "PASO 5/7 — Generar KeyStore PKCS12"
    _ssl_tomcat_crear_keystore || return 1
    echo ""

    msg_info "PASO 6/7 — Modificar server.xml"
    _ssl_tomcat_modificar_server_xml "$https_port" "$_SSL_TOMCAT_KEYSTORE_PASS" || return 1
    echo ""

    msg_info "PASO 7/7 — Configurar redirect en web.xml y reiniciar"
    _ssl_tomcat_configurar_webxml || return 1
    _ssl_tomcat_abrir_firewall "$https_port"
    echo ""
    _ssl_tomcat_reiniciar_esperar "$https_port"

    separator
    msg_success "SSL/TLS configurado en Tomcat"
    separator
    echo ""
    printf "    Certificado : %s/%s\n" "$SSL_DIR_TOMCAT" "$SSL_CERT_FILE"
    printf "    KeyStore    : %s\n"    "$_SSL_TOMCAT_KEYSTORE"
    printf "    HTTP  :%s  → redirect HTTPS (web.xml CONFIDENTIAL)\n" "$http_port"
    printf "    HTTPS :%s  (activo)\n" "$https_port"
    echo ""

    export _SSL_LAST_HTTP_PORT="$http_port"
    export _SSL_LAST_HTTPS_PORT="$https_port"
    return 0
}

ssl_desactivar_tomcat() {
    msg_alert "Desactivando SSL en Tomcat..."

    local bak; bak=$(ls -t "${_SSL_TOMCAT_SERVER_XML}.bak_"* 2>/dev/null | head -1)
    [[ -n "$bak" ]] && sudo cp "$bak" "$_SSL_TOMCAT_SERVER_XML" \
        && msg_success "server.xml restaurado"

    local webroot; webroot=$(_ssl_tomcat_detectar_webroot)
    local bak_web; bak_web=$(ls -t "${webroot}/WEB-INF/web.xml.bak_"* 2>/dev/null | head -1)
    [[ -n "$bak_web" ]] && sudo cp "$bak_web" "${webroot}/WEB-INF/web.xml" \
        && msg_success "web.xml restaurado"

    sudo systemctl restart tomcat &>/dev/null
    msg_success "Tomcat reiniciado sin SSL"
}

export -f ssl_configurar_tomcat
export -f ssl_desactivar_tomcat
export -f ssl_tomcat_actualizar_puertos
export -f _ssl_tomcat_leer_puerto_http
export -f _ssl_tomcat_leer_puerto_https
export -f _ssl_tomcat_detectar_webroot
export -f _ssl_tomcat_pedir_keystore_pass
export -f _ssl_tomcat_crear_keystore
export -f _ssl_tomcat_modificar_server_xml
export -f _ssl_tomcat_configurar_webxml
export -f _ssl_tomcat_abrir_firewall
export -f _ssl_tomcat_reiniciar_esperar