#!/bin/bash
# =============================================================================
# lib_net.sh — Funciones de calculo y validacion de redes IP
# Uso: source lib_net.sh
# Requiere: source lib_ui.sh (para msg_*)
# =============================================================================

# Numero maximo de reintentos en bucles de entrada
MAX_ATTEMPTS=${MAX_ATTEMPTS:-100}

# -----------------------------------------------------------------------------
# Conversion IP <-> entero
# -----------------------------------------------------------------------------

# Convierte una IP en notacion decimal punteada a entero de 32 bits.
# Imprime el entero o cadena vacia si la IP es invalida.
ip_a_entero() {
    local ip=$1
    local a b c d

    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo ""
        return 1
    fi

    IFS='.' read -r a b c d <<< "$ip"

    if [ "$a" -gt 255 ] || [ "$b" -gt 255 ] || [ "$c" -gt 255 ] || [ "$d" -gt 255 ]; then
        echo ""
        return 1
    fi

    echo $((a * 16777216 + b * 65536 + c * 256 + d))
}

# Convierte un entero de 32 bits a notacion decimal punteada.
entero_a_ip() {
    local num=$1

    if [ "$num" -lt 0 ] || [ "$num" -gt 4294967295 ]; then
        echo ""
        return 1
    fi

    echo "$((num >> 24 & 255)).$((num >> 16 & 255)).$((num >> 8 & 255)).$((num & 255))"
}

# -----------------------------------------------------------------------------
# Mascara / CIDR
# -----------------------------------------------------------------------------

# Convierte prefijo CIDR (/8-/32) a mascara de subred.
cidr_a_mascara() {
    local cidr=$1

    if [ "$cidr" -lt 1 ] || [ "$cidr" -gt 32 ]; then
        echo ""
        return 1
    fi

    if command -v ipcalc &>/dev/null; then
        local result
        result=$(ipcalc -m "0.0.0.0/$cidr" 2>/dev/null | cut -d= -f2)
        [ -n "$result" ] && echo "$result" && return 0
    fi

    local mask=0
    for ((i = 0; i < cidr; i++)); do
        mask=$((mask | (1 << (31 - i))))
    done
    entero_a_ip $mask
}

# Convierte mascara de subred a prefijo CIDR.
mascara_a_cidr() {
    local mascara=$1
    local mask_int
    mask_int=$(ip_a_entero "$mascara")

    [ -z "$mask_int" ] && echo "" && return 1

    local cidr=0
    for ((i = 31; i >= 0; i--)); do
        if [ $((mask_int & (1 << i))) -ne 0 ]; then
            cidr=$((cidr + 1))
        else
            break
        fi
    done
    echo "$cidr"
}

# Detecta la clase clasica de una IP y devuelve la mascara natural.
# Mantenida por compatibilidad; preferir CIDR explicito.
detectar_clase_y_calcular_mascara() {
    local ip=$1
    local primer_octeto
    IFS='.' read -r primer_octeto _ _ _ <<< "$ip"

    if   [ "$primer_octeto" -ge 1   ] && [ "$primer_octeto" -le 126 ]; then echo "255.0.0.0"
    elif [ "$primer_octeto" -ge 128 ] && [ "$primer_octeto" -le 191 ]; then echo "255.255.0.0"
    elif [ "$primer_octeto" -ge 192 ] && [ "$primer_octeto" -le 223 ]; then echo "255.255.255.0"
    else echo ""; return 1
    fi
}

# -----------------------------------------------------------------------------
# Validacion
# -----------------------------------------------------------------------------

# Valida que un prefijo CIDR sea usable para DHCP (/8 - /30).
validar_cidr() {
    local cidr=$1
    [[ "$cidr" =~ ^[0-9]+$ ]] || return 1
    [ "$cidr" -ge 8 ] && [ "$cidr" -le 30 ]
}

# Valida una direccion IP.
# $2 = "allow_reserved" para permitir rangos especiales (loopback, multicast, etc.)
validar_ip() {
    local ip=$1
    local allow_reserved=${2:-}

    [ -z "$ip" ] && return 1

    if command -v ipcalc &>/dev/null; then
        ipcalc -c "$ip" &>/dev/null || return 1
    else
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
        IFS='.' read -ra OCTETOS <<< "$ip"
        [ ${#OCTETOS[@]} -ne 4 ] && return 1
        for octeto in "${OCTETOS[@]}"; do
            [[ "$octeto" =~ ^[0-9]+$ ]] || return 1
            [ "$octeto" -lt 0 ] || [ "$octeto" -gt 255 ] && return 1
        done
    fi

    if [ "$allow_reserved" != "allow_reserved" ]; then
        IFS='.' read -ra OCTETOS <<< "$ip"
        local p=${OCTETOS[0]} q=${OCTETOS[1]}

        [ "$p" -eq 0   ] && return 1                                   # 0.0.0.0/8
        [ "$p" -eq 127 ] && return 1                                   # Loopback
        [ "$p" -eq 169 ] && [ "$q" -eq 254 ] && return 1              # APIPA
        [ "$p" -ge 224 ] && [ "$p" -le 239 ] && return 1              # Multicast
        [ "$p" -ge 240 ] && return 1                                   # Reservado/Experimental
        [ "$ip" = "255.255.255.255" ] && return 1                     # Broadcast global
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Calculo de red
# -----------------------------------------------------------------------------

# Devuelve la direccion de red para una IP y mascara dadas.
obtener_direccion_red() {
    local ip=$1 mascara=$2

    if command -v ipcalc &>/dev/null; then
        local cidr
        cidr=$(mascara_a_cidr "$mascara")
        if [ -n "$cidr" ]; then
            local result
            result=$(ipcalc -n "$ip/$cidr" 2>/dev/null | cut -d= -f2)
            [ -n "$result" ] && echo "$result" && return 0
        fi
    fi

    local ip_int mask_int
    ip_int=$(ip_a_entero "$ip")
    mask_int=$(ip_a_entero "$mascara")
    [ -z "$ip_int" ] || [ -z "$mask_int" ] && echo "" && return 1

    entero_a_ip $((ip_int & mask_int))
}

# Devuelve la direccion de broadcast para una red y mascara dadas.
obtener_broadcast() {
    local red=$1 mascara=$2

    if command -v ipcalc &>/dev/null; then
        local cidr
        cidr=$(mascara_a_cidr "$mascara")
        if [ -n "$cidr" ]; then
            local result
            result=$(ipcalc -b "$red/$cidr" 2>/dev/null | cut -d= -f2)
            [ -n "$result" ] && echo "$result" && return 0
        fi
    fi

    local red_int mask_int
    red_int=$(ip_a_entero "$red")
    mask_int=$(ip_a_entero "$mascara")
    [ -z "$red_int" ] || [ -z "$mask_int" ] && echo "" && return 1

    entero_a_ip $((red_int | (~mask_int & 0xFFFFFFFF)))
}

# -----------------------------------------------------------------------------
# Predicados
# -----------------------------------------------------------------------------

# Devuelve 0 si la IP pertenece a la red (IP/mascara).
ip_en_red() {
    local ip=$1 red=$2 mascara=$3

    if command -v grepcidr &>/dev/null; then
        local cidr
        cidr=$(mascara_a_cidr "$mascara")
        [ -n "$cidr" ] && echo "$ip" | grepcidr "$red/$cidr" &>/dev/null && return $?
    fi

    local ip_int red_int mask_int
    ip_int=$(ip_a_entero "$ip")
    red_int=$(ip_a_entero "$red")
    mask_int=$(ip_a_entero "$mascara")
    [ -z "$ip_int" ] || [ -z "$red_int" ] || [ -z "$mask_int" ] && return 1

    [ $((ip_int & mask_int)) -eq $((red_int & mask_int)) ]
}

# Devuelve 0 si la IP es igual a la direccion de red.
ip_es_red() { [ "${1:-}" = "${2:-}" ]; }

# Devuelve 0 si la IP es igual al broadcast.
ip_es_broadcast() { [ "${1:-}" = "${2:-}" ]; }

# Devuelve 0 si la IP esta dentro del rango [inicio, fin].
ip_en_rango() {
    local ip=$1 inicio=$2 fin=$3
    local ip_int inicio_int fin_int

    ip_int=$(ip_a_entero "$ip")
    inicio_int=$(ip_a_entero "$inicio")
    fin_int=$(ip_a_entero "$fin")
    [ -z "$ip_int" ] || [ -z "$inicio_int" ] || [ -z "$fin_int" ] && return 1

    [ $ip_int -ge $inicio_int ] && [ $ip_int -le $fin_int ]
}

# -----------------------------------------------------------------------------
# Validacion compuesta (requiere NETWORK_ADDRESS, MASCARA, BROADCAST_ADDRESS,
# CIDR definidos en el entorno llamador)
# -----------------------------------------------------------------------------

# Valida que una IP sea utilizable dentro del segmento activo:
#   formato correcto → pertenece al segmento → no es red → no es broadcast.
# $1 = ip   $2 = etiqueta para mensajes de error
validar_ip_en_segmento() {
    local ip=$1 etiqueta=${2:-}

    if ! validar_ip "$ip"; then
        msg_error "IP $etiqueta invalida o en segmento no usable"
        return 1
    fi
    if ! ip_en_red "$ip" "$NETWORK_ADDRESS" "$MASCARA"; then
        msg_error "La IP $etiqueta no pertenece al segmento $NETWORK_ADDRESS/$CIDR"
        return 1
    fi
    if ip_es_red "$ip" "$NETWORK_ADDRESS"; then
        msg_error "La IP $etiqueta no puede ser la direccion de red ($NETWORK_ADDRESS)"
        return 1
    fi
    if ip_es_broadcast "$ip" "$BROADCAST_ADDRESS"; then
        msg_error "La IP $etiqueta no puede ser la direccion de broadcast ($BROADCAST_ADDRESS)"
        return 1
    fi
    return 0
}

# Solicita una IP con reintentos hasta MAX_ATTEMPTS.
# Permite vacio (Enter) para omitir — la variable destino queda en "".
# $1 = nombre de variable destino   $2 = prompt   $3 = funcion de validacion extra (opcional)
pedir_ip_loop() {
    local __var=$1 prompt=$2 validador=${3:-}
    local ip_leida intentos=0

    while [ $intentos -lt $MAX_ATTEMPTS ]; do
        msg_input "$prompt"
        read -r ip_leida

        if [ -z "$ip_leida" ]; then
            printf -v "$__var" ""
            return 0
        fi

        if ! validar_ip "$ip_leida"; then
            msg_error "IP invalida o en segmento no usable"
            intentos=$((intentos + 1))
            continue
        fi

        if [ -n "$validador" ] && ! $validador "$ip_leida"; then
            intentos=$((intentos + 1))
            continue
        fi

        printf -v "$__var" "%s" "$ip_leida"
        return 0
    done

    msg_error "Demasiados intentos fallidos"
    return 1
}

# -----------------------------------------------------------------------------
# Funciones de validacion adicionales (usadas por dns_manager)
# -----------------------------------------------------------------------------

# Verifica si un comando esta disponible en el PATH.
check_dependency() {
    command -v "$1" &>/dev/null
}

# Extrae la IP de una cadena IP/CIDR.
extract_ip_from_cidr()      { echo "$1" | cut -d'/' -f1; }

# Extrae el prefijo de una cadena IP/CIDR.
extract_prefix_from_cidr()  { echo "$1" | cut -d'/' -f2; }

# Valida una cadena IP/CIDR (ej: 192.168.1.10/24).
validar_ip_cidr() {
    local ip_cidr="$1"
    [[ "$ip_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || return 1
    command -v ipcalc &>/dev/null && ipcalc -c "$ip_cidr" &>/dev/null || return 1
    return 0
}

# Valida IP sola o IP/CIDR.
validar_ip_o_cidr() {
    local input="$1"
    if [[ "$input" =~ / ]]; then
        validar_ip_cidr "$input"
    else
        validar_ip "$input"
    fi
}