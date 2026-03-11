#!/bin/bash
# =============================================================================
# lib/utils.sh — Utilidades de sistema reutilizables
# Uso: source lib/utils.sh
# Requiere: source lib/ui.sh (para msg_*)
# =============================================================================

# Verifica privilegios sudo
check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        msg_alert "Detectado ejecucion directa como root o sudo"
        return 0
    fi
    if ! sudo -n true 2>/dev/null; then
        msg_error "Se requieren privilegios de sudo"
        msg_info "Ejecute: sudo -v"
        return 1
    fi
    return 0
}

# Verifica si un paquete RPM está instalado
check_package_installed() {
    local package="$1"
    rpm -qa | grep -q "^${package}-[0-9]"
}

# Verifica si un servicio systemd está activo
check_service_active() {
    local service="$1"
    sudo systemctl is-active --quiet "$service" 2>/dev/null
}

# Verifica si un servicio systemd está habilitado
check_service_enabled() {
    local service="$1"
    sudo systemctl is-enabled --quiet "$service" 2>/dev/null
}

# Verifica conectividad con ping
check_connectivity() {
    local host="${1:-8.8.8.8}"
    ping -c 1 -W 2 "$host" &>/dev/null
}

# Verifica si un puerto TCP está en escucha
check_port_listening() {
    local port="$1"
    sudo ss -tlnp 2>/dev/null | grep -q ":${port} "
}

# Verifica si un usuario existe en el sistema
check_user_exists() {
    local user="$1"
    id "$user" &>/dev/null
}

export -f check_privileges
export -f check_package_installed
export -f check_service_active
export -f check_service_enabled
export -f check_connectivity
export -f check_port_listening
export -f check_user_exists