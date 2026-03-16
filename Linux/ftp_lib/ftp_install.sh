#!/bin/bash
# =============================================================================
# ftp_lib/ftp_install.sh — Instalacion, configuracion inicial y desinstalacion
#
# Autenticacion: usuarios locales del sistema via /etc/shadow
# =============================================================================

instalar_vsftpd() {
    separator
    msg_process "Verificando paquetes necesarios..."

    local pkgs=()
    rpm -q vsftpd  &>/dev/null || pkgs+=("vsftpd")
    command -v openssl &>/dev/null || pkgs+=("openssl")

    if [ ${#pkgs[@]} -gt 0 ]; then
        msg_process "Instalando: ${pkgs[*]}..."
        dnf install -y "${pkgs[@]}" &>/dev/null || {
            msg_error "No se pudieron instalar los paquetes requeridos"
            return 1
        }
        msg_success "Paquetes instalados"
    else
        msg_info "Dependencias ya presentes"
    fi

    _pedir_grupos_iniciales
    _crear_grupos_sistema
    _crear_grupo_ssh
    _crear_estructura_directorios
    _inicializar_archivos_meta
    _bloquear_ftp_en_ssh
    _escribir_vsftpd_conf
    _escribir_pam_vsftpd
    _configurar_selinux
    _abrir_firewall

    systemctl enable --now vsftpd &>/dev/null
    systemctl restart vsftpd

    if systemctl is-active --quiet vsftpd; then
        msg_success "vsftpd activo"
    else
        msg_error "vsftpd no inicio — revisa: journalctl -u vsftpd -n 30"
        return 1
    fi

    # -------------------------------------------------------------------------
    # Hook SSL/FTPS — se ejecuta al final de la instalación exitosa
    # -------------------------------------------------------------------------
    _ftp_ssl_hook
}

# -----------------------------------------------------------------------------
# _ftp_ssl_hook
#
# Pregunta al usuario si desea activar FTPS inmediatamente después de instalar
# vsftpd. No es fatal: si se rechaza o ssl_lib no está disponible, vsftpd
# sigue funcionando en modo FTP plano.
# -----------------------------------------------------------------------------
_ftp_ssl_hook() {
    local _ssl_lib="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/ssl_lib/ssl.sh"

    echo ""
    separator
    msg_info "Configuracion FTPS (SSL/TLS)"
    separator
    echo ""
    msg_input "¿Desea activar FTPS (SSL/TLS) en vsftpd ahora? [S/N]: "
    read -r _resp_ftps

    if [[ ! "${_resp_ftps^^}" =~ ^(S|SI|Y|YES)$ ]]; then
        msg_info "FTPS omitido. Puede activarlo despues desde ftp_manager.sh → opcion 6"
        return 0
    fi

    if [[ ! -f "$_ssl_lib" ]]; then
        msg_error "ssl_lib/ssl.sh no encontrado en: ${_ssl_lib}"
        msg_info  "Copie ssl_lib/ en el directorio raiz del proyecto para habilitar FTPS"
        return 0
    fi

    # Cargar ws_lib/ws_utils.sh si no está en el entorno (ssl_lib lo requiere)
    local _ws_utils="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/ws_lib/ws_utils.sh"
    if ! declare -f http_get_webroot &>/dev/null && [[ -f "$_ws_utils" ]]; then
        source "$_ws_utils" 2>/dev/null || true
    fi

    if source "$_ssl_lib" 2>/dev/null; then
        ssl_configurar_vsftpd || msg_alert "FTPS no se completo correctamente — revise los logs"
    else
        msg_error "No se pudo cargar ssl_lib — FTPS omitido"
    fi

    return 0
}

_crear_grupos_sistema() {
    for grupo in "${FTP_GROUPS[@]}"; do
        if ! getent group "$grupo" &>/dev/null; then
            groupadd --system "$grupo"
            msg_success "Grupo '$grupo' creado"
        else
            msg_info "Grupo '$grupo' ya existe"
        fi
    done
}

_crear_grupo_ssh() {
    if ! getent group "$FTP_SSH_GROUP" &>/dev/null; then
        groupadd --system "$FTP_SSH_GROUP"
        msg_success "Grupo SSH '$FTP_SSH_GROUP' creado"
    else
        msg_info "Grupo SSH '$FTP_SSH_GROUP' ya existe"
    fi
}

_bloquear_ftp_en_ssh() {
    local sshd_conf="/etc/ssh/sshd_config"
    [ ! -f "$sshd_conf" ] && return 0

    local patron="DenyGroups ${FTP_SSH_GROUP}"
    if ! grep -qF "$patron" "$sshd_conf"; then
        echo "" >> "$sshd_conf"
        echo "# Usuarios FTP — bloqueados para SSH via grupo ${FTP_SSH_GROUP}" >> "$sshd_conf"
        echo "$patron" >> "$sshd_conf"
        systemctl reload sshd 2>/dev/null || true
        msg_success "SSH: DenyGroups ${FTP_SSH_GROUP} agregado"
    else
        msg_info "SSH: DenyGroups ${FTP_SSH_GROUP} ya configurado"
    fi
}

_escribir_vsftpd_conf() {
    msg_process "Escribiendo $VSFTPD_CONF..."
    [ -f "$VSFTPD_CONF" ] && cp "$VSFTPD_CONF" "${VSFTPD_CONF}.bak.$(date +%s)"

    cat > "$VSFTPD_CONF" <<CONF
# vsftpd.conf — generado por ftp_manager.sh

listen=YES
listen_ipv6=NO

# --- Anonimo: chroot en /srv/ftp/ftp_anonymous (root:root 755, no escribible)
# con bind mount de general dentro — vsftpd rechaza chroot escribible
anonymous_enable=YES
anon_root=$FTP_ROOT/ftp_anonymous
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO

# --- Usuarios locales del sistema (autenticacion via /etc/shadow) ---
# El cliente conecta con su nombre FTP .
local_enable=YES
write_enable=YES
local_umask=007

# --- Chroot: cada usuario confinado a su directorio ---
chroot_local_user=YES
allow_writeable_chroot=NO
user_sub_token=\$USER
local_root=$FTP_ROOT/${FTP_USER_PREFIX}\$USER

# --- Banner y log ---
ftpd_banner=$FTP_BANNER
xferlog_enable=YES
xferlog_std_format=YES
log_ftp_protocol=NO

# --- Modo pasivo ---
pasv_enable=YES
pasv_min_port=30000
pasv_max_port=31000

# --- Rendimiento y compatibilidad ---
reverse_lookup_enable=NO

# --- PAM: autentica via /etc/shadow ---
pam_service_name=vsftpd
tcp_wrappers=NO
userlist_enable=NO
CONF
    msg_success "vsftpd.conf escrito"
}

_escribir_pam_vsftpd() {
    msg_process "Configurando PAM..."
    [ -f "$PAM_FILE" ] && cp "$PAM_FILE" "${PAM_FILE}.bak.$(date +%s)"

    cat > "$PAM_FILE" <<PAM
#%PAM-1.0
auth     include  password-auth
account  include  password-auth
PAM
    msg_success "PAM: autenticacion via /etc/shadow"
}

_configurar_selinux() {
    if ! command -v semanage &>/dev/null; then
        msg_alert "semanage no disponible — omitiendo configuracion SELinux"
        msg_info "Si SELinux esta activo, instala: dnf install policycoreutils-python-utils"
        return 0
    fi

    msg_process "Configurando SELinux para FTP..."

    semanage fcontext -a -t public_content_rw_t "${FTP_ROOT}(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t public_content_rw_t "${FTP_ROOT}(/.*)?" 2>/dev/null
    restorecon -Rv "$FTP_ROOT" &>/dev/null

    setsebool -P ftpd_full_access on &>/dev/null

    msg_success "SELinux configurado para FTP (public_content_rw_t + ftpd_full_access)"
}

_abrir_firewall() {
    command -v firewall-cmd &>/dev/null || return 0
    msg_process "Configurando firewall..."
    firewall-cmd --permanent --add-service=ftp &>/dev/null
    firewall-cmd --permanent --add-port=30000-31000/tcp &>/dev/null
    firewall-cmd --reload &>/dev/null
    msg_success "Firewall configurado"
}

desinstalar_vsftpd() {
    msg_input "Confirma desinstalacion de vsftpd [s/N]: "; read -r r
    [[ "$r" =~ ^[Ss]$ ]] || return

    systemctl stop    vsftpd &>/dev/null
    systemctl disable vsftpd &>/dev/null
    dnf remove -y vsftpd &>/dev/null
    msg_success "vsftpd desinstalado"

    msg_process "Eliminando bind mounts FTP..."
    while IFS=: read -r u _; do
        [ -z "$u" ] && continue
        _eliminar_mounts_usuario "$u" 2>/dev/null || true
    done < "$VSFTPD_USERS_META" 2>/dev/null
    _eliminar_bind_mount "$FTP_ROOT/ftp_anonymous/general" 2>/dev/null || true
    rmdir "$FTP_ROOT/ftp_anonymous" 2>/dev/null || true
    find /etc/systemd/system/ -name "srv-ftp-*.mount" -delete 2>/dev/null
    systemctl daemon-reload
    msg_success "Bind mounts eliminados"

    msg_input "Eliminar usuarios FTP del sistema? [s/N]: "; read -r ru
    if [[ "$ru" =~ ^[Ss]$ ]]; then
        while IFS=: read -r u _; do
            [ -z "$u" ] && continue
            id "$u" &>/dev/null && userdel "$u" && \
                msg_success "Usuario '$u' eliminado"
        done < "$VSFTPD_USERS_META" 2>/dev/null
    fi

    msg_input "Eliminar datos ($FTP_ROOT y archivos de configuracion)? [s/N]: "; read -r rd
    if [[ "$rd" =~ ^[Ss]$ ]]; then
        rm -rf "$FTP_ROOT" "$VSFTPD_USERS_META" "$VSFTPD_GROUPS_FILE"
        msg_success "Datos eliminados"
    fi

    local sshd_conf="/etc/ssh/sshd_config"
    if [ -f "$sshd_conf" ]; then
        sed -i "/# Usuarios FTP/d;/DenyGroups ${FTP_SSH_GROUP}/d" "$sshd_conf"
        systemctl reload sshd 2>/dev/null || true
        msg_success "SSH: DenyGroups removido"
    fi

    if command -v semanage &>/dev/null; then
        semanage fcontext -d "${FTP_ROOT}(/.*)?" 2>/dev/null || true
        setsebool -P ftpd_full_access off &>/dev/null || true
        msg_success "SELinux: contexto FTP revertido"
    fi

    local pam_bak
    pam_bak=$(ls -t "${PAM_FILE}.bak."* 2>/dev/null | head -1)
    [ -n "$pam_bak" ] && cp "$pam_bak" "$PAM_FILE" && msg_success "PAM restaurado"
}