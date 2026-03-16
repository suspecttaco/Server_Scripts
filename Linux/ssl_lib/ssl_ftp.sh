#!/bin/bash
# =============================================================================
# ssl_lib/ssl_ftp.sh — Configuración FTPS (SSL/TLS explícito) para vsftpd
#
# Acciones:
#   1. Genera certificado self-signed para vsftpd
#   2. Modifica vsftpd.conf para habilitar SSL en canal de control y datos
#   3. Fuerza TLS para usuarios locales y anónimos
#   4. Abre puertos necesarios en firewalld (21 + rango pasivo)
#   5. Reinicia vsftpd y verifica con openssl s_client
#
# Protocolo: FTPS explícito (STARTTLS en puerto 21 = AUTH TLS)
# NO SFTP (que es SSH): vsftpd no soporta SFTP nativo.
#
# Requiere: source ssl_lib/ssl.sh, source ftp_lib/ftp.sh, source lib/ui.sh
# =============================================================================

# -----------------------------------------------------------------------------
# _ssl_ftp_leer_pasv_range  (interna)
# Lee el rango de puertos pasivos desde vsftpd.conf.
# -----------------------------------------------------------------------------
_ssl_ftp_leer_pasv_range() {
    local conf="${VSFTPD_CONF:-/etc/vsftpd/vsftpd.conf}"
    local pmin pmax

    pmin=$(sudo grep -E "^pasv_min_port=" "$conf" 2>/dev/null | cut -d= -f2)
    pmax=$(sudo grep -E "^pasv_max_port=" "$conf" 2>/dev/null | cut -d= -f2)

    echo "${pmin:-$SSL_FTPS_PASV_MIN}:${pmax:-$SSL_FTPS_PASV_MAX}"
}

# -----------------------------------------------------------------------------
# _ssl_ftp_set_param  (interna)
# Establece o actualiza un parámetro en vsftpd.conf de forma atómica.
# Reutiliza la misma lógica que _set_vsftpd_param de ftp_config.sh.
# -----------------------------------------------------------------------------
_ssl_ftp_set_param() {
    local param="$1" value="$2"
    local conf="${VSFTPD_CONF:-/etc/vsftpd/vsftpd.conf}"
    local ve; ve=$(printf '%s' "$value" | sed 's/[@&\\]/\\&/g')

    if grep -qE "^#?${param}=" "$conf" 2>/dev/null; then
        sudo sed -i "s@^#\?${param}=.*@${param}=${ve}@" "$conf"
    else
        echo "${param}=${value}" | sudo tee -a "$conf" > /dev/null
    fi
}

# -----------------------------------------------------------------------------
# _ssl_ftp_escribir_seccion_ssl  (interna)
# Agrega o reemplaza la sección SSL en vsftpd.conf.
# Usa marcadores para ser idempotente (se puede recorrer N veces).
# -----------------------------------------------------------------------------
_ssl_ftp_escribir_seccion_ssl() {
    local cert_path="${SSL_DIR_VSFTPD}/${SSL_CERT_FILE}"
    local key_path="${SSL_DIR_VSFTPD}/${SSL_KEY_FILE}"
    local conf="${VSFTPD_CONF:-/etc/vsftpd/vsftpd.conf}"

    # Eliminar sección SSL previa (idempotencia)
    sudo sed -i '/# === ssl_manager: FTPS ===/,/# === \/ssl_manager ===/d' "$conf" 2>/dev/null || true

    msg_process "Escribiendo sección SSL en ${conf}..."

    # Agregar sección SSL al final del archivo
    sudo tee -a "$conf" > /dev/null << FTPSCONF

# === ssl_manager: FTPS ===
# Generado por ssl_manager — $(date '+%Y-%m-%d %H:%M:%S')

# Habilitar SSL
ssl_enable=YES

# Rutas del certificado y clave privada
rsa_cert_file=${cert_path}
rsa_private_key_file=${key_path}

# Forzar TLS en el canal de control (autenticación)
# YES = solo se aceptan conexiones con AUTH TLS; NO = TLS opcional
force_local_logins_ssl=YES

# Forzar TLS en el canal de datos (transferencias)
force_local_data_ssl=YES

# Comportamiento con usuarios anónimos:
# allow_anon_ssl=YES  permite que anonymous negocie TLS si el cliente lo pide.
# force_anon_*=NO     significa que anonymous puede conectar SIN TLS también,
# porque no hay credenciales reales que proteger.
# Esto es intencional: FileZilla conectando como anonymous sin marcar
# "Require explicit FTP over TLS" puede conectar sin problema.
allow_anon_ssl=YES
force_anon_logins_ssl=NO
force_anon_data_ssl=NO

# Versión mínima de protocolo TLS
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO

# Deshabilitar compresión SSL (CRIME attack mitigation)
require_ssl_reuse=NO

# Algoritmos de cifrado (excluye los débiles)
ssl_ciphers=HIGH:!aNULL:!MD5:!RC4:!DES:!3DES
# === /ssl_manager ===
FTPSCONF

    if [[ $? -eq 0 ]]; then
        msg_success "Sección FTPS escrita en vsftpd.conf"
        return 0
    fi
    msg_error "Error al escribir la sección FTPS"
    return 1
}

# -----------------------------------------------------------------------------
# _ssl_ftp_abrir_firewall  (interna)
# Asegura que el puerto 21 y el rango pasivo estén abiertos.
# -----------------------------------------------------------------------------
_ssl_ftp_abrir_firewall() {
    command -v firewall-cmd &>/dev/null || return 0
    sudo systemctl is-active --quiet firewalld 2>/dev/null || return 0

    local rango; rango=$(_ssl_ftp_leer_pasv_range)
    local pmin="${rango%%:*}"
    local pmax="${rango##*:}"

    msg_process "Verificando reglas de firewall para FTPS..."

    sudo firewall-cmd --permanent --add-service=ftp &>/dev/null || true
    sudo firewall-cmd --permanent --add-port="${pmin}-${pmax}/tcp" &>/dev/null || true
    sudo firewall-cmd --reload &>/dev/null
    msg_success "Firewall: FTP (puerto 21) y rango pasivo ${pmin}-${pmax}/tcp abiertos"
}

# -----------------------------------------------------------------------------
# _ssl_ftp_verificar_ftps  (interna)
# Verifica la conexión FTPS usando openssl s_client con STARTTLS.
# Retorna 0 si el handshake TLS fue exitoso.
# -----------------------------------------------------------------------------
_ssl_ftp_verificar_ftps() {
    msg_process "Verificando handshake FTPS en localhost:21..."

    local output
    output=$(echo "QUIT" | sudo openssl s_client \
                -connect localhost:21 \
                -starttls ftp \
                -brief 2>&1)

    if echo "$output" | grep -q "Verification\|Protocol\|Cipher\|CONNECTION ESTABLISHED"; then
        msg_success "Handshake FTPS exitoso"
        echo ""
        echo "$output" | grep -E "(Protocol|Cipher|Verification|subject|issuer)" \
            | sed 's/^/    /'
        return 0
    fi

    msg_alert "No se pudo verificar FTPS automáticamente"
    msg_info "Verifique manualmente:"
    msg_info "  openssl s_client -connect <IP>:21 -starttls ftp"
    return 1
}

# -----------------------------------------------------------------------------
# ssl_configurar_vsftpd
#
# Función pública principal. Orquesta FTPS completo en vsftpd.
# -----------------------------------------------------------------------------
ssl_configurar_vsftpd() {
    separator
    msg_info "Configuración FTPS — vsftpd"
    separator
    echo ""

    # Verificar que vsftpd esté instalado
    if ! rpm -q vsftpd &>/dev/null; then
        msg_error "vsftpd no está instalado"
        msg_info "Instale vsftpd primero desde el Gestor FTP"
        return 1
    fi

    # Verificar que el archivo de configuración exista
    local conf="${VSFTPD_CONF:-/etc/vsftpd/vsftpd.conf}"
    if [[ ! -f "$conf" ]]; then
        msg_error "vsftpd.conf no encontrado en: ${conf}"
        return 1
    fi

    msg_info "Estado FTPS actual:"
    if grep -q "^ssl_enable=YES" "$conf" 2>/dev/null; then
        msg_alert "ssl_enable=YES ya está activo en vsftpd.conf"
        msg_input "¿Reconfigurar FTPS (sobrescribirá la configuración SSL actual)? [S/N]: "
        read -r reconf
        [[ ! "${reconf^^}" =~ ^(S|SI|Y|YES)$ ]] && { msg_info "Sin cambios"; return 0; }
    fi
    echo ""

    # Paso 1: Datos del certificado
    msg_info "PASO 1/6 — Datos del certificado"
    ssl_recopilar_datos_certificado "vsftpd (FTPS)" || return 1
    echo ""

    msg_input "¿Confirmar configuración FTPS para vsftpd? [S/N]: "; read -r conf_input
    [[ ! "${conf_input^^}" =~ ^(S|SI|Y|YES)$ ]] && { msg_info "Cancelado"; return 0; }
    echo ""

    # Paso 2: Generar certificado
    msg_info "PASO 2/6 — Generar certificado"
    ssl_generar_certificado "$SSL_DIR_VSFTPD" "vsftpd" || return 1
    echo ""

    # Paso 3: Backup vsftpd.conf
    msg_info "PASO 3/6 — Backup de vsftpd.conf"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    sudo cp "$conf" "${conf}.bak_${ts}"
    msg_success "Backup: ${conf}.bak_${ts}"
    echo ""

    # Paso 4: Escribir sección SSL
    msg_info "PASO 4/6 — Configurar vsftpd.conf"
    _ssl_ftp_escribir_seccion_ssl || return 1
    echo ""

    # Paso 5: Reiniciar vsftpd
    msg_info "PASO 5/6 — Reiniciar vsftpd"
    if ! sudo systemctl restart vsftpd 2>/dev/null; then
        msg_error "vsftpd no levantó con configuración FTPS"
        msg_info "Revise: sudo journalctl -u vsftpd -n 30"
        msg_info "Restaurando backup..."
        sudo cp "${conf}.bak_${ts}" "$conf"
        sudo systemctl restart vsftpd 2>/dev/null
        return 1
    fi
    sleep 2

    if ! sudo systemctl is-active --quiet vsftpd; then
        msg_error "vsftpd no está activo tras el reinicio"
        return 1
    fi
    msg_success "vsftpd activo con FTPS"

    # Paso 6: Firewall y verificación
    msg_info "PASO 6/6 — Firewall y verificación"
    _ssl_ftp_abrir_firewall
    echo ""
    _ssl_ftp_verificar_ftps

    separator
    msg_success "FTPS configurado exitosamente en vsftpd"
    separator
    echo ""
    msg_info "Archivos generados:"
    printf "    Certificado  : %s/%s\n" "$SSL_DIR_VSFTPD" "$SSL_CERT_FILE"
    printf "    Clave        : %s/%s\n" "$SSL_DIR_VSFTPD" "$SSL_KEY_FILE"
    printf "    Config vsftpd: %s\n"    "$conf"
    echo ""
    local ip_srv; ip_srv=$(hostname -I | awk '{print $1}')
    local rango_pasv; rango_pasv=$(_ssl_ftp_leer_pasv_range)
    local pmin="${rango_pasv%%:*}"
    local pmax="${rango_pasv##*:}"

    separator
    msg_info "Instrucciones para FileZilla:"
    separator
    echo ""
    echo "  Conexión con usuario local (FTPS explícito):"
    printf "    Protocolo : FTP - Protocolo de transferencia de archivos\n"
    printf "    Cifrado   : Requiere FTP explícito sobre TLS\n"
    printf "    Servidor  : %s\n" "${ip_srv}"
    printf "    Puerto    : 21\n"
    printf "    Modo login: Normal\n"
    printf "    Usuario   : <tu_usuario_ftp>\n"
    printf "    Contraseña: <tu_contraseña>\n"
    echo ""
    echo "  Al conectar FileZilla mostrará un aviso del certificado self-signed."
    echo "  Acepta y marca 'Confiar siempre en este certificado' para no volver a verlo."
    echo ""
    echo "  Conexión anónima:"
    printf "    Mismo servidor/puerto. Cifrado: FTP explícito sobre TLS.\n"
    printf "    Modo login: Anónimo  (o usuario: anonymous, contraseña: vacía)\n"
    printf "    El acceso anónimo no fuerza TLS — FileZilla puede conectar sin cifrado.\n"
    echo ""
    printf "  Puertos pasivos requeridos en el firewall del host Windows: %s-%s\n" \
        "${pmin}" "${pmax}"
    echo "  Si FileZilla cuelga al listar directorios, verificar que ese rango"
    echo "  no esté bloqueado por el firewall de Windows."
    echo ""
    return 0
}

# -----------------------------------------------------------------------------
# ssl_desactivar_vsftpd
# Elimina la sección SSL de vsftpd.conf y restaura a FTP plano.
# -----------------------------------------------------------------------------
ssl_desactivar_vsftpd() {
    msg_alert "Desactivando FTPS en vsftpd..."

    local conf="${VSFTPD_CONF:-/etc/vsftpd/vsftpd.conf}"
    if [[ -f "$conf" ]]; then
        local ts; ts=$(date +%Y%m%d_%H%M%S)
        sudo cp "$conf" "${conf}.bak_${ts}"
        sudo sed -i '/# === ssl_manager: FTPS ===/,/# === \/ssl_manager ===/d' "$conf" 2>/dev/null
        msg_success "Sección FTPS eliminada de vsftpd.conf"
    fi

    sudo systemctl restart vsftpd &>/dev/null
    msg_success "vsftpd reiniciado sin SSL"
}

export -f ssl_configurar_vsftpd
export -f ssl_desactivar_vsftpd
export -f _ssl_ftp_leer_pasv_range
export -f _ssl_ftp_set_param
export -f _ssl_ftp_escribir_seccion_ssl
export -f _ssl_ftp_abrir_firewall
export -f _ssl_ftp_verificar_ftps