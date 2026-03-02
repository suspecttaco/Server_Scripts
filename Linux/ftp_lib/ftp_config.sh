#!/bin/bash
# =============================================================================
# lib/ftp_config.sh — Edicion de vsftpd.conf y gestion de firewall
# =============================================================================

ver_configuracion() {
    separator
    msg_info "Configuracion activa: $VSFTPD_CONF"
    separator
    if [ -f "$VSFTPD_CONF" ]; then
        grep -v '^\s*#' "$VSFTPD_CONF" | grep -v '^\s*$'
    else
        msg_alert "$VSFTPD_CONF no existe"
    fi
}

_set_vsftpd_param() {
    local param="$1" value="$2"
    local ve; ve=$(printf '%s' "$value" | sed 's/[@&\\]/\\&/g')
    if grep -qE "^#?${param}=" "$VSFTPD_CONF" 2>/dev/null; then
        sed -i "s@^#\?${param}=.*@${param}=${ve}@" "$VSFTPD_CONF"
    else
        echo "${param}=${value}" >> "$VSFTPD_CONF"
    fi
}

editar_configuracion() {
    [ ! -f "$VSFTPD_CONF" ] && msg_alert "Instala vsftpd primero" && return
    cp "$VSFTPD_CONF" "${VSFTPD_CONF}.bak.$(date +%s)"
    msg_info "Backup guardado. Enter = sin cambios."
    separator

    # Banner
    local banner_actual
    banner_actual=$(grep -E "^ftpd_banner=" "$VSFTPD_CONF" | cut -d= -f2-)
    msg_input "Banner [$banner_actual]: "; read -r nuevo_banner
    if [[ -n "$nuevo_banner" ]]; then
        _set_vsftpd_param "ftpd_banner" "${nuevo_banner//=/-}"
    fi

    # Puertos pasivos (validados juntos para garantizar min < max)
    local pmin pmax
    pmin=$(grep -E "^pasv_min_port=" "$VSFTPD_CONF" | cut -d= -f2)
    pmax=$(grep -E "^pasv_max_port=" "$VSFTPD_CONF" | cut -d= -f2)
    msg_input "Puerto pasivo minimo [$pmin]: "; read -r nmin
    msg_input "Puerto pasivo maximo [$pmax]: "; read -r nmax
    local fmin="${nmin:-$pmin}" fmax="${nmax:-$pmax}"
    if [[ -n "$nmin" || -n "$nmax" ]]; then
        if [[ "$fmin" =~ ^[0-9]+$ && "$fmax" =~ ^[0-9]+$ ]] && \
           [ "$fmin" -ge 1024 ] && [ "$fmax" -le 65535 ] && [ "$fmin" -lt "$fmax" ]; then
            [[ -n "$nmin" ]] && _set_vsftpd_param "pasv_min_port" "$nmin"
            [[ -n "$nmax" ]] && _set_vsftpd_param "pasv_max_port" "$nmax"
        else
            msg_error "Rango invalido o minimo >= maximo — sin cambios"
        fi
    fi

    # Acceso anonimo
    local anon_actual
    anon_actual=$(grep -E "^anonymous_enable=" "$VSFTPD_CONF" | cut -d= -f2)
    msg_input "Acceso anonimo YES/NO [$anon_actual]: "; read -r nuevo_anon
    if [[ -n "$nuevo_anon" ]]; then
        case "${nuevo_anon^^}" in
            YES|Y) _set_vsftpd_param "anonymous_enable" "YES" ;;
            NO|N)  _set_vsftpd_param "anonymous_enable" "NO"  ;;
            *)     msg_error "Usa YES o NO" ;;
        esac
    fi

    msg_input "Reiniciar vsftpd? [S/n]: "; read -r r
    [[ ! "$r" =~ ^[Nn]$ ]] && reiniciar_servicio
}

gestionar_firewall() {
    command -v firewall-cmd &>/dev/null || { msg_alert "firewalld no disponible"; return; }

    separator
    msg_info "Firewall — Puertos FTP"
    local pmin pmax
    pmin=$(grep -E "^pasv_min_port=" "$VSFTPD_CONF" 2>/dev/null | cut -d= -f2); pmin="${pmin:-30000}"
    pmax=$(grep -E "^pasv_max_port=" "$VSFTPD_CONF" 2>/dev/null | cut -d= -f2); pmax="${pmax:-31000}"

    msg_info "Puertos abiertos actualmente:"
    firewall-cmd --list-ports 2>/dev/null
    firewall-cmd --list-services 2>/dev/null

    separator
    echo "  1) Abrir puertos FTP (21 + ${pmin}-${pmax})"
    echo "  2) Cerrar puertos FTP"
    echo "  3) Ver reglas completas"
    echo "  0) Volver"
    separator
    msg_input "Opcion: "; read -r op

    case "$op" in
        1) firewall-cmd --permanent --add-service=ftp &>/dev/null
           firewall-cmd --permanent --add-port="${pmin}-${pmax}/tcp" &>/dev/null
           firewall-cmd --reload &>/dev/null && msg_success "Puertos abiertos" ;;
        2) firewall-cmd --permanent --remove-service=ftp &>/dev/null
           firewall-cmd --permanent --remove-port="${pmin}-${pmax}/tcp" &>/dev/null
           firewall-cmd --reload &>/dev/null && msg_success "Puertos cerrados" ;;
        3) firewall-cmd --list-all ;;
        0) return ;;
        *) msg_alert "Opcion invalida" ;;
    esac
}