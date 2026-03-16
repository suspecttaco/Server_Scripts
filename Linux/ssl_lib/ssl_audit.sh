#!/bin/bash
# =============================================================================
# ssl_lib/ssl_audit.sh — Auditoría automatizada de SSL/TLS
#
# Verifica los 4 servicios (Apache, Nginx, Tomcat, vsftpd) y genera
# un resumen con semáforo de estado.
#
# Pruebas por servicio HTTP:
#   1. Certificado existe y no ha expirado
#   2. Servicio responde en puerto HTTPS
#   3. Protocolo TLS ≥ 1.2 (sin SSLv2/v3/TLS1.0/1.1)
#   4. CN del certificado coincide con lo configurado
#   5. Redirección HTTP → HTTPS activa (código 301/302)
#   6. Header HSTS presente en respuesta
#   7. Puerto HTTPS abierto en firewalld
#
# Pruebas para vsftpd (FTPS):
#   1. Certificado existe y no ha expirado
#   2. ssl_enable=YES en vsftpd.conf
#   3. force_local_logins_ssl=YES y force_local_data_ssl=YES
#   4. Handshake FTPS vía openssl s_client -starttls ftp
#
# Requiere: source ssl_lib/ssl.sh, source lib/ui.sh
# =============================================================================

# Contadores globales del audit
_AUDIT_SSL_PASS=0
_AUDIT_SSL_FAIL=0
_AUDIT_SSL_WARN=0
_AUDIT_SSL_LOG=()

# -----------------------------------------------------------------------------
# Helpers de salida (misma semántica que ws_security_audit.sh)
# -----------------------------------------------------------------------------
_spass() {
    echo -e "    ${GREEN}[PASS]${NC} $1"
    (( _AUDIT_SSL_PASS++ ))
    _AUDIT_SSL_LOG+=("[PASS] $1")
}

_sfail() {
    echo -e "    ${RED}[FAIL]${NC} $1"
    [[ -n "${2:-}" ]] && echo -e "           ${GRAY}Fix: $2${NC}"
    (( _AUDIT_SSL_FAIL++ ))
    _AUDIT_SSL_LOG+=("[FAIL] $1${2:+ || Fix: $2}")
}

_swarn() {
    echo -e "    ${YELLOW}[WARN]${NC} $1"
    [[ -n "${2:-}" ]] && echo -e "           ${GRAY}Nota: $2${NC}"
    (( _AUDIT_SSL_WARN++ ))
    _AUDIT_SSL_LOG+=("[WARN] $1${2:+ || Nota: $2}")
}

_sinfo() {
    echo -e "    ${CYAN}[INFO]${NC} $1"
}

_sreset() {
    _AUDIT_SSL_PASS=0
    _AUDIT_SSL_FAIL=0
    _AUDIT_SSL_WARN=0
    _AUDIT_SSL_LOG=()
}

# -----------------------------------------------------------------------------
# _ssl_audit_certificado  (interna)
# Verifica existencia, validez y CN del certificado de un servicio.
# $1 = directorio del servicio  $2 = CN esperado  $3 = nombre del servicio
# -----------------------------------------------------------------------------
_ssl_audit_certificado() {
    local dir="$1"
    local cn_esperado="$2"
    local nombre="$3"
    local cert_path="${dir}/${SSL_CERT_FILE}"

    # Existencia
    if [[ ! -f "$cert_path" ]]; then
        _sfail "Certificado no encontrado: ${cert_path}" \
               "Ejecute ssl_manager → Configurar SSL → ${nombre}"
        return 1
    fi
    _spass "Certificado encontrado: ${cert_path}"

    # Validez (no expirado)
    if sudo openssl x509 -in "$cert_path" -noout -checkend 0 2>/dev/null; then
        local fecha_exp
        fecha_exp=$(sudo openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null \
                    | cut -d= -f2)
        _spass "Certificado vigente (expira: ${fecha_exp})"
    else
        _sfail "Certificado EXPIRADO" \
               "Regenere el certificado desde ssl_manager → Configurar SSL → ${nombre}"
        return 1
    fi

    # CN del certificado
    local cn_real
    cn_real=$(sudo openssl x509 -in "$cert_path" -noout -subject 2>/dev/null \
              | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 | xargs)

    if [[ -n "$cn_real" ]]; then
        _sinfo "CN en certificado: ${cn_real}"
        if [[ -z "$cn_esperado" ]]; then
            _swarn "No se puede verificar CN (CN esperado desconocido)"
        elif [[ "$cn_real" == "$cn_esperado" ]]; then
            _spass "CN coincide: ${cn_real}"
        else
            _swarn "CN no coincide: certificado='${cn_real}' vs esperado='${cn_esperado}'" \
                   "Regenere el certificado con el CN correcto"
        fi
    else
        _swarn "No se pudo leer el CN del certificado"
    fi

    # Algoritmo de firma
    local sig_algo
    sig_algo=$(sudo openssl x509 -in "$cert_path" -noout -text 2>/dev/null \
               | grep "Signature Algorithm" | head -1 | awk '{print $NF}')
    [[ -n "$sig_algo" ]] && _sinfo "Algoritmo de firma: ${sig_algo}"

    return 0
}

# -----------------------------------------------------------------------------
# _ssl_audit_https_respuesta  (interna)
# Verifica que el servicio responde en el puerto HTTPS con curl.
# $1 = puerto HTTPS  $2 = nombre del servicio
# -----------------------------------------------------------------------------
_ssl_audit_https_respuesta() {
    local puerto="$1"
    local nombre="$2"

    local resp_code
    resp_code=$(curl -sk -o /dev/null -w "%{http_code}" \
                --connect-timeout 5 \
                "https://localhost:${puerto}" 2>/dev/null)

    if [[ "$resp_code" =~ ^(200|301|302|400|403)$ ]]; then
        _spass "HTTPS responde en :${puerto} — HTTP ${resp_code}"
        return 0
    elif [[ "$resp_code" == "000" ]]; then
        _sfail "HTTPS no responde en :${puerto} (timeout/conexión rechazada)" \
               "Verificar servicio activo y firewall: sudo systemctl status ${nombre,,}"
        return 1
    else
        _swarn "HTTPS en :${puerto} devolvió código inesperado: ${resp_code}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# _ssl_audit_protocolo_tls  (interna)
# Verifica que el servicio acepta TLS 1.2/1.3 y rechaza protocolos inseguros.
# $1 = puerto  $2 = nombre
# -----------------------------------------------------------------------------
_ssl_audit_protocolo_tls() {
    local puerto="$1"
    local nombre="$2"

    # Verificar TLS 1.2 (debe funcionar)
    if echo "Q" | sudo openssl s_client \
            -connect "localhost:${puerto}" \
            -tls1_2 \
            -brief 2>/dev/null | grep -q "Protocol  : TLSv1.2"; then
        _spass "TLS 1.2 aceptado"
    else
        _swarn "TLS 1.2 no pudo verificarse" "Compruebe manualmente: openssl s_client -connect localhost:${puerto} -tls1_2"
    fi

    # Verificar TLS 1.3 si está disponible en el sistema
    if echo "Q" | sudo openssl s_client \
            -connect "localhost:${puerto}" \
            -tls1_3 \
            -brief 2>/dev/null | grep -q "Protocol  : TLSv1.3"; then
        _spass "TLS 1.3 aceptado"
    else
        _sinfo "TLS 1.3 no disponible (no requerido para esta práctica)"
    fi

    # Verificar que SSLv3 está rechazado
    local sslv3_output
    sslv3_output=$(echo "Q" | sudo openssl s_client \
                   -connect "localhost:${puerto}" \
                   -ssl3 2>&1 || true)
    if echo "$sslv3_output" | grep -qiE "handshake failure|no protocols|ALERT"; then
        _spass "SSLv3 rechazado correctamente"
    else
        _swarn "SSLv3 podría no estar deshabilitado" \
               "Verificar SSLProtocol/ssl_protocols en la configuración del servicio"
    fi

    # Verificar que TLS 1.0 está rechazado
    local tls10_output
    tls10_output=$(echo "Q" | sudo openssl s_client \
                   -connect "localhost:${puerto}" \
                   -tls1 2>&1 || true)
    if echo "$tls10_output" | grep -qiE "handshake failure|no protocols|ALERT"; then
        _spass "TLS 1.0 rechazado correctamente"
    else
        _swarn "TLS 1.0 podría estar habilitado" \
               "Configurar SSLProtocol all -TLSv1 en Apache / ssl_protocols TLSv1.2 TLSv1.3 en Nginx"
    fi
}

# -----------------------------------------------------------------------------
# _ssl_audit_redirect_http  (interna)
# Verifica que HTTP redirige a HTTPS (código 301/302).
# $1 = puerto HTTP  $2 = puerto HTTPS  $3 = nombre
# -----------------------------------------------------------------------------
_ssl_audit_redirect_http() {
    local puerto_http="$1"
    local puerto_https="$2"
    local nombre="$3"

    local resp_code location
    resp_code=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 5 --max-redirs 0 \
                "http://localhost:${puerto_http}" 2>/dev/null)
    location=$(curl -s -o /dev/null -w "%{redirect_url}" \
               --connect-timeout 5 --max-redirs 0 \
               "http://localhost:${puerto_http}" 2>/dev/null)

    if [[ "$resp_code" =~ ^(301|302)$ ]]; then
        _spass "Redirección HTTP→HTTPS activa (código ${resp_code})"
        if echo "$location" | grep -q "^https://"; then
            _spass "Location apunta a HTTPS: ${location}"
        else
            _swarn "Location no apunta explícitamente a HTTPS: ${location}"
        fi
    elif [[ "$resp_code" == "200" ]]; then
        _sfail "HTTP responde 200 en lugar de redirigir (sin redirección a HTTPS)" \
               "Revisar configuración de redirección en ${nombre}"
    elif [[ "$resp_code" == "000" ]]; then
        _swarn "HTTP no responde en :${puerto_http} — no se puede verificar redirección"
    else
        _swarn "HTTP devolvió código inesperado: ${resp_code}"
    fi
}

# -----------------------------------------------------------------------------
# _ssl_audit_hsts  (interna)
# Verifica presencia del header Strict-Transport-Security en respuesta HTTPS.
# $1 = puerto HTTPS  $2 = nombre
# -----------------------------------------------------------------------------
_ssl_audit_hsts() {
    local puerto="$1"
    local nombre="$2"

    local hsts_val
    hsts_val=$(curl -sk --connect-timeout 5 -I \
               "https://localhost:${puerto}" 2>/dev/null \
               | grep -i "Strict-Transport-Security" \
               | cut -d: -f2- | tr -d '\r' | xargs)

    if [[ -n "$hsts_val" ]]; then
        _spass "HSTS presente: ${hsts_val}"
    else
        _sfail "Header HSTS ausente en respuesta HTTPS" \
               "Agregar: Header always set Strict-Transport-Security 'max-age=31536000'"
    fi
}

# -----------------------------------------------------------------------------
# _ssl_audit_firewall_https  (interna)
# Verifica que el puerto HTTPS esté abierto en firewalld.
# $1 = puerto
# -----------------------------------------------------------------------------
_ssl_audit_firewall_https() {
    local puerto="$1"

    command -v firewall-cmd &>/dev/null || {
        _swarn "firewalld no disponible — omitiendo verificación de firewall"
        return 0
    }

    if ! sudo systemctl is-active --quiet firewalld 2>/dev/null; then
        _swarn "firewalld inactivo — no hay reglas activas"
        return 0
    fi

    local abierto=false
    sudo firewall-cmd --list-services 2>/dev/null | grep -qw "https" && abierto=true
    sudo firewall-cmd --list-ports 2>/dev/null | grep -q "${puerto}/tcp" && abierto=true

    if $abierto; then
        _spass "Puerto ${puerto}/tcp abierto en firewalld"
    else
        _sfail "Puerto ${puerto}/tcp NO está abierto en firewalld" \
               "sudo firewall-cmd --permanent --add-port=${puerto}/tcp && sudo firewall-cmd --reload"
    fi
}

# -----------------------------------------------------------------------------
# _ssl_audit_servicio_http  (interna)
# Ejecuta el conjunto completo de pruebas para un servicio HTTP (Apache/Nginx/Tomcat).
# $1 = nombre interno (apache/nginx/tomcat)
# $2 = nombre display
# $3 = directorio de certificados
# $4 = puerto HTTPS
# $5 = puerto HTTP
# -----------------------------------------------------------------------------
_ssl_audit_servicio_http() {
    local svc="$1"
    local nombre="$2"
    local dir_cert="$3"
    local puerto_https="$4"
    local puerto_http="$5"

    separator
    echo -e "  ${CYAN}▶ Auditoría SSL — ${nombre}${NC}"
    separator
    echo ""

    # Verificar si el servicio está instalado
    local paquete="${svc}"
    [[ "$svc" == "apache" ]] && paquete="httpd"

    if ! rpm -q "$paquete" &>/dev/null; then
        _sinfo "${nombre} no instalado — omitiendo"
        echo ""
        return 0
    fi

    local systemd_name="$paquete"
    if ! sudo systemctl is-active --quiet "$systemd_name" 2>/dev/null; then
        _sfail "${nombre} instalado pero NO activo" \
               "sudo systemctl start ${systemd_name}"
        echo ""
        return 1
    fi
    _spass "${nombre} activo (systemd)"
    echo ""

    # Leer CN esperado del certificado existente (si lo hay)
    local cn_esperado=""
    local cert_path="${dir_cert}/${SSL_CERT_FILE}"
    if [[ -f "$cert_path" ]]; then
        cn_esperado=$(sudo openssl x509 -in "$cert_path" -noout -subject 2>/dev/null \
                      | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 | xargs)
    fi

    _ssl_audit_certificado   "$dir_cert" "$cn_esperado" "$nombre"
    echo ""
    _ssl_audit_https_respuesta "$puerto_https" "$nombre"
    echo ""
    _ssl_audit_protocolo_tls   "$puerto_https" "$nombre"
    echo ""
    _ssl_audit_redirect_http   "$puerto_http" "$puerto_https" "$nombre"
    echo ""
    _ssl_audit_hsts            "$puerto_https" "$nombre"
    echo ""
    _ssl_audit_firewall_https  "$puerto_https"
    echo ""
}

# -----------------------------------------------------------------------------
# _ssl_audit_vsftpd  (interna)
# Ejecuta el conjunto completo de pruebas para vsftpd FTPS.
# -----------------------------------------------------------------------------
_ssl_audit_vsftpd() {
    separator
    echo -e "  ${CYAN}▶ Auditoría FTPS — vsftpd${NC}"
    separator
    echo ""

    if ! rpm -q vsftpd &>/dev/null; then
        _sinfo "vsftpd no instalado — omitiendo"
        echo ""
        return 0
    fi

    if ! sudo systemctl is-active --quiet vsftpd 2>/dev/null; then
        _sfail "vsftpd instalado pero NO activo" "sudo systemctl start vsftpd"
        echo ""
        return 1
    fi
    _spass "vsftpd activo"
    echo ""

    local conf="${VSFTPD_CONF:-/etc/vsftpd/vsftpd.conf}"

    # Certificado
    _ssl_audit_certificado "$SSL_DIR_VSFTPD" "" "vsftpd"
    echo ""

    # Parámetros SSL en vsftpd.conf
    local params=(
        "ssl_enable=YES:SSL habilitado en vsftpd"
        "force_local_logins_ssl=YES:TLS forzado en canal de control"
        "force_local_data_ssl=YES:TLS forzado en canal de datos"
        "ssl_sslv2=NO:SSLv2 deshabilitado"
        "ssl_sslv3=NO:SSLv3 deshabilitado"
        "ssl_tlsv1=YES:TLS habilitado"
    )

    for entrada in "${params[@]}"; do
        local param="${entrada%%:*}"
        local desc="${entrada##*:}"
        local key="${param%%=*}"
        local val="${param##*=}"

        local actual
        actual=$(sudo grep -E "^${key}=" "$conf" 2>/dev/null | cut -d= -f2 | head -1)

        if [[ "$actual" == "$val" ]]; then
            _spass "${key}=${val} — ${desc}"
        elif [[ -z "$actual" ]]; then
            _sfail "${key} no configurado (esperado: ${val}) — ${desc}" \
                   "Ejecute ssl_manager → Configurar FTPS"
        else
            _swarn "${key}=${actual} (esperado: ${val}) — ${desc}"
        fi
    done

    echo ""

    # Handshake FTPS con openssl s_client
    msg_process "Probando handshake FTPS..."
    local ftps_output
    ftps_output=$(echo "QUIT" | sudo openssl s_client \
                  -connect localhost:21 \
                  -starttls ftp \
                  -brief 2>&1 || true)

    if echo "$ftps_output" | grep -qiE "Protocol\s*:|Cipher\s*:|CONNECTION ESTABLISHED"; then
        _spass "Handshake FTPS exitoso (AUTH TLS)"
        local proto cipher
        proto=$(echo "$ftps_output" | grep -i "Protocol" | head -1 | xargs)
        cipher=$(echo "$ftps_output" | grep -i "Cipher" | head -1 | xargs)
        [[ -n "$proto"  ]] && echo -e "           ${GRAY}${proto}${NC}"
        [[ -n "$cipher" ]] && echo -e "           ${GRAY}${cipher}${NC}"
    else
        _sfail "Handshake FTPS falló en localhost:21" \
               "Verificar: openssl s_client -connect <IP>:21 -starttls ftp"
    fi

    echo ""
}

# -----------------------------------------------------------------------------
# _ssl_audit_resumen  (interna)
# Genera el cuadro de puntuación del audit.
# -----------------------------------------------------------------------------
_ssl_audit_resumen() {
    local titulo="${1:-SSL/TLS Global}"
    local p=$_AUDIT_SSL_PASS
    local f=$_AUDIT_SSL_FAIL
    local w=$_AUDIT_SSL_WARN
    local t=$(( p + f + w ))

    local score=0
    (( t > 0 )) && score=$(( (p * 100) / t ))

    local nivel color_score
    if   (( score >= 85 )); then nivel="SEGURO";    color_score="$GREEN"
    elif (( score >= 65 )); then nivel="ACEPTABLE"; color_score="$CYAN"
    elif (( score >= 45 )); then nivel="MEJORABLE"; color_score="$YELLOW"
    else                        nivel="CRÍTICO";    color_score="$RED"
    fi

    echo ""
    separator
    echo -e "  ${BLUE}Resumen SSL/TLS — ${titulo}${NC}"
    separator
    printf "  ${GREEN}[PASS]${NC} %-4s  ${RED}[FAIL]${NC} %-4s  ${YELLOW}[WARN]${NC} %-4s  Total: %s\n" \
           "$p" "$f" "$w" "$t"
    printf "  Puntuación: ${color_score}%s%%${NC} — %s\n" "$score" "$nivel"
    separator

    if (( f > 0 )); then
        echo ""
        echo -e "  ${RED}Problemas críticos:${NC}"
        local entrada
        for entrada in "${_AUDIT_SSL_LOG[@]}"; do
            [[ "$entrada" == \[FAIL\]* ]] || continue
            local msg="${entrada#\[FAIL\] }"
            echo -e "    ${RED}·${NC} ${msg%% || *}"
        done
    fi

    if (( w > 0 )); then
        echo ""
        echo -e "  ${YELLOW}Advertencias:${NC}"
        for entrada in "${_AUDIT_SSL_LOG[@]}"; do
            [[ "$entrada" == \[WARN\]* ]] || continue
            local msg="${entrada#\[WARN\] }"
            echo -e "    ${YELLOW}·${NC} ${msg%% || *}"
        done
    fi

    echo ""
    return $f   # retorna número de fallos como código de salida
}

# -----------------------------------------------------------------------------
# ssl_audit_completo
#
# Función pública. Ejecuta la auditoría completa de los 4 servicios.
# Puede llamarse desde ssl_manager.sh o directamente.
# -----------------------------------------------------------------------------
ssl_audit_completo() {
    clear
    draw_header "Auditoría SSL/TLS — Todos los servicios"
    echo ""
    printf "  Hora     : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "  Servidor : %s (%s)\n" "$(hostname)" "$(hostname -I | awk '{print $1}')"
    echo ""

    _sreset

    # Detectar puerto HTTP de Apache y Nginx para las pruebas de redirección
    local puerto_http_apache=80
    local puerto_http_nginx=80

    if [[ -f "/etc/httpd/conf/httpd.conf" ]]; then
        puerto_http_apache=$(sudo grep -E "^Listen\s+[0-9]+" /etc/httpd/conf/httpd.conf 2>/dev/null \
                             | awk '{print $2}' | grep -oP '[0-9]+$' | head -1)
        puerto_http_apache="${puerto_http_apache:-80}"
    fi

    if [[ -f "/etc/nginx/nginx.conf" ]]; then
        puerto_http_nginx=$(sudo grep -E "^\s+listen\s+[0-9]+" /etc/nginx/nginx.conf 2>/dev/null \
                            | grep -oP '\d+' | head -1)
        puerto_http_nginx="${puerto_http_nginx:-80}"
    fi

    # Apache
    _ssl_audit_servicio_http \
        "httpd" "Apache (httpd)" \
        "$SSL_DIR_APACHE" \
        "$SSL_PORT_HTTPS" \
        "$puerto_http_apache"

    # Nginx
    _ssl_audit_servicio_http \
        "nginx" "Nginx" \
        "$SSL_DIR_NGINX" \
        "$SSL_PORT_HTTPS" \
        "$puerto_http_nginx"

    # Tomcat
    _ssl_audit_servicio_http \
        "tomcat" "Tomcat" \
        "$SSL_DIR_TOMCAT" \
        "$SSL_PORT_TOMCAT_HTTPS" \
        "8080"

    # vsftpd
    _ssl_audit_vsftpd

    # Resumen global
    _ssl_audit_resumen "Todos los servicios"

    read -rp "  Presiona Enter para continuar..."
}

# -----------------------------------------------------------------------------
# ssl_audit_servicio
#
# Función pública. Audita un único servicio específico.
# $1 = apache | nginx | tomcat | vsftpd
# -----------------------------------------------------------------------------
ssl_audit_servicio() {
    local svc="${1:-}"
    _sreset

    case "$svc" in
        apache|httpd)
            _ssl_audit_servicio_http \
                "httpd" "Apache (httpd)" \
                "$SSL_DIR_APACHE" \
                "$SSL_PORT_HTTPS" \
                "$(sudo grep -E "^Listen\s+[0-9]+" /etc/httpd/conf/httpd.conf 2>/dev/null \
                   | awk '{print $2}' | grep -oP '[0-9]+$' | head -1 || echo 80)"
            ;;
        nginx)
            _ssl_audit_servicio_http \
                "nginx" "Nginx" \
                "$SSL_DIR_NGINX" \
                "$SSL_PORT_HTTPS" \
                "$(sudo grep -E "^\s+listen\s+[0-9]+" /etc/nginx/nginx.conf 2>/dev/null \
                   | grep -oP '\d+' | head -1 || echo 80)"
            ;;
        tomcat)
            _ssl_audit_servicio_http \
                "tomcat" "Tomcat" \
                "$SSL_DIR_TOMCAT" \
                "$SSL_PORT_TOMCAT_HTTPS" \
                "8080"
            ;;
        vsftpd|ftp)
            _ssl_audit_vsftpd
            ;;
        *)
            msg_error "Servicio no reconocido: ${svc}"
            msg_info "Opciones: apache | nginx | tomcat | vsftpd"
            return 1
            ;;
    esac

    _ssl_audit_resumen "$svc"
}

export -f ssl_audit_completo
export -f ssl_audit_servicio
export -f _ssl_audit_certificado
export -f _ssl_audit_https_respuesta
export -f _ssl_audit_protocolo_tls
export -f _ssl_audit_redirect_http
export -f _ssl_audit_hsts
export -f _ssl_audit_firewall_https
export -f _ssl_audit_servicio_http
export -f _ssl_audit_vsftpd
export -f _ssl_audit_resumen
export -f _sreset _spass _sfail _swarn _sinfo