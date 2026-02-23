#!/bin/bash
# =============================================================================
# lib_iface.sh — Gestion de interfaces de red y herramientas auxiliares
# Uso: source lib_iface.sh
# Requiere: source lib_ui.sh, source lib_net.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Herramientas de red
# -----------------------------------------------------------------------------

# Verifica e instala ipcalc, sipcalc y grepcidr si no estan presentes.
verificar_herramientas_red() {
    local herramientas_faltantes=()

    command -v ipcalc  &>/dev/null || herramientas_faltantes+=("ipcalc")
    { command -v sipcalc  &>/dev/null || rpm -q sipcalc  &>/dev/null; } || herramientas_faltantes+=("sipcalc")
    { command -v grepcidr &>/dev/null || rpm -q grepcidr &>/dev/null; } || herramientas_faltantes+=("grepcidr")

    if [ ${#herramientas_faltantes[@]} -gt 0 ]; then
        msg_alert "Herramientas de red no encontradas: ${herramientas_faltantes[*]}"
        msg_process "Instalando herramientas de red..."

        if sudo dnf install -y ipcalc sipcalc grepcidr &>/dev/null; then
            msg_success "Herramientas de red instaladas correctamente"
        else
            msg_alert "No se pudieron instalar algunas herramientas"
            msg_info "El script usara metodos alternativos"
        fi
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Configuracion de interfaz
# -----------------------------------------------------------------------------

# Asigna IP_ADAPTADOR/CIDR a INTERFAZ y persiste la configuracion en NetworkManager.
# La funcion siempre intenta asignar la IP; si ya esta configurada exactamente
# igual, lo trata como exito sin cortar el flujo.
# Variables requeridas: INTERFAZ, IP_ADAPTADOR, CIDR
configurar_ip_interfaz() {
    msg_process "Configurando IP $IP_ADAPTADOR/$CIDR en $INTERFAZ..."

    # Eliminar cualquier IP previa en la interfaz
    sudo ip addr flush dev "$INTERFAZ" 2>/dev/null

    # Asignar la nueva IP; ignorar "RTNETLINK: File exists" (ya configurada)
    local add_output
    add_output=$(sudo ip addr add "$IP_ADAPTADOR/$CIDR" dev "$INTERFAZ" 2>&1)
    local add_rc=$?

    if [ $add_rc -ne 0 ] && ! echo "$add_output" | grep -qi "file exists"; then
        msg_error "No se pudo configurar la IP: $add_output"
        return 1
    fi

    sudo ip link set "$INTERFAZ" up
    msg_success "IP configurada correctamente"
    INTERFAZ_IP="$IP_ADAPTADOR"

    # Persistir con NetworkManager
    msg_process "Guardando configuracion en NetworkManager..."
    local CONN_NAME
    CONN_NAME=$(nmcli -t -f NAME,DEVICE con show 2>/dev/null \
        | grep ":${INTERFAZ}$" | cut -d: -f1 | head -1)

    if [ -n "$CONN_NAME" ]; then
        sudo nmcli con mod "$CONN_NAME" \
            ipv4.addresses "$IP_ADAPTADOR/$CIDR" \
            ipv4.method manual &>/dev/null
        sudo nmcli con up "$CONN_NAME" &>/dev/null 2>&1
        msg_success "Configuracion guardada en NetworkManager"
    else
        msg_alert "No se pudo hacer persistente (no hay conexion NetworkManager)"
    fi

    return 0
}



# -----------------------------------------------------------------------------
# Consulta de interfaces (usadas por dns_manager)
# -----------------------------------------------------------------------------

# Devuelve IP/CIDR actual de una interfaz (ej: 192.168.1.10/24).
get_interface_ip_cidr() {
    ip addr show "$1" 2>/dev/null | grep "inet " | awk '{print $2}' | head -n1
}

# Devuelve solo la IP de una interfaz.
get_interface_ip() {
    local ip_cidr
    ip_cidr=$(get_interface_ip_cidr "$1")
    [[ -n "$ip_cidr" ]] && extract_ip_from_cidr "$ip_cidr"
}

# Lista interfaces disponibles (excluye loopback).
list_network_interfaces() {
    nmcli device status | awk 'NR>1 {printf "  %s - %s (%s)\n", $1, $2, $3}'
}

# Devuelve 0 si la interfaz existe.
check_interface_exists() {
    ip link show "$1" &>/dev/null
}

# Devuelve la zona de firewalld de una interfaz (fallback: public).
get_interface_firewall_zone() {
    local interface="$1"
    if ! command -v firewall-cmd &>/dev/null; then echo "public"; return 0; fi
    local zone
    zone=$(firewall-cmd --get-zone-of-interface="$interface" 2>/dev/null)
    [[ -z "$zone" || "$zone" == "no zone" ]] && zone=$(firewall-cmd --get-default-zone 2>/dev/null)
    echo "${zone:-public}"
}

# Devuelve 0 si la interfaz tiene IP estatica (metodo manual en NetworkManager).
check_static_ip() {
    local interface="$1"
    [[ -z "$interface" ]] && return 1
    local connection
    connection=$(nmcli -t -f NAME,DEVICE connection show --active \
        | grep ":${interface}$" | cut -d':' -f1)
    [[ -z "$connection" ]] && return 1
    nmcli -f ipv4.method connection show "$connection" | grep -q "manual"
}

# Configura IP estatica en una interfaz via NetworkManager.
# $1=interfaz  $2=IP/CIDR  $3=DNS
configure_static_ip() {
    local interface="$1" ip_cidr="$2" dns="$3"

    check_interface_exists "$interface" || { msg_error "La interfaz $interface no existe"; return 1; }
    validar_ip_cidr "$ip_cidr"          || { msg_error "IP/CIDR invalida: $ip_cidr";       return 1; }
    validar_ip "$dns"                   || { msg_error "DNS invalida: $dns";                return 1; }

    local connection
    connection=$(nmcli -t -f NAME,DEVICE connection show --active \
        | grep ":${interface}$" | cut -d':' -f1)
    [[ -z "$connection" ]] && { msg_error "No se encontro conexion activa para $interface"; return 1; }

    msg_info "Configurando IP estatica en $interface..."
    nmcli connection modify "$connection" ipv4.addresses "$ip_cidr" || return 1
    nmcli connection modify "$connection" ipv4.dns       "$dns"     || return 1
    nmcli connection modify "$connection" ipv4.method    manual     || return 1
    nmcli connection up "$connection"                               || return 1

    msg_success "IP estatica configurada: $ip_cidr"
}