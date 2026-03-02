#!/bin/bash
# =============================================================================
# lib/ftp_service.sh — Control del servicio vsftpd
# =============================================================================

mostrar_estado() {
    separator
    msg_info "Estado de vsftpd:"
    systemctl status vsftpd --no-pager -l | head -20

    separator
    msg_info "Puertos en escucha:"
    ss -tlnp 2>/dev/null | grep -E ':(21|20|3[0-9]{4})\b' || \
        msg_alert "No se detectaron puertos FTP en escucha"

    separator
    msg_info "Conexiones activas:"
    ss -tnp 2>/dev/null | grep ':21' || msg_info "Sin conexiones activas"

    separator
    msg_info "Log reciente:"
    local logfile="/var/log/vsftpd.log"
    if [ -f "$logfile" ]; then
        tail -20 "$logfile"
    else
        journalctl -u vsftpd --no-pager -n 20 2>/dev/null
    fi

    separator
    listar_usuarios_ftp
}

iniciar_servicio() {
    msg_process "Iniciando vsftpd..."
    systemctl start vsftpd && msg_success "vsftpd iniciado" || msg_error "No se pudo iniciar"
}

detener_servicio() {
    msg_input "Confirma detener vsftpd [s/N]: "; read -r r
    [[ "$r" =~ ^[Ss]$ ]] || return
    systemctl stop vsftpd && msg_success "vsftpd detenido" || msg_error "No se pudo detener"
}

reiniciar_servicio() {
    msg_process "Reiniciando vsftpd..."
    systemctl restart vsftpd && msg_success "vsftpd reiniciado" || msg_error "No se pudo reiniciar"
}

toggle_arranque_automatico() {
    if systemctl is-enabled --quiet vsftpd; then
        systemctl disable vsftpd && msg_success "Arranque automatico deshabilitado"
    else
        systemctl enable  vsftpd && msg_success "Arranque automatico habilitado"
    fi
}