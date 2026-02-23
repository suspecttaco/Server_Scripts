#!/bin/bash
# =============================================================================
# dhcp_manager.sh — Gestor de servidor DHCP (Fedora)
#
# Uso interactivo: sudo ./dhcp_manager.sh
# Uso por parametros: sudo ./dhcp_manager.sh [COMANDO] [OPCIONES]
# Usa: lib/ui.sh, lib/net.sh, lib/iface.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for lib in ui net iface; do
    lib_path="$SCRIPT_DIR/lib/${lib}.sh"
    if [[ ! -f "$lib_path" ]]; then
        echo "ERROR: No se encontro el modulo requerido: $lib_path"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$lib_path"
done

MAX_ATTEMPTS=100

# =============================================================================
# VERIFICACION DE PRIVILEGIOS
# =============================================================================

if [[ $EUID -ne 0 ]]; then
    msg_error "Este script debe ejecutarse con privilegios de superusuario (root)."
    msg_info  "Por favor, intenta usar: sudo $0"
    exit 1
fi

# =============================================================================
# INSTALACION DE DHCP
# =============================================================================

_instalar_paquete_dhcp() {
    msg_info "Instalando paquete dhcp-server"
    sudo dnf install -y dhcp-server &>/dev/null
    if [ $? -eq 0 ]; then
        msg_success "Instalado correctamente"
        verificar_herramientas_red
        sleep 5
        return 0
    else
        msg_error "Fallo en la instalacion"
        return 1
    fi
}

_reinstalar_dhcp() {
    echo -ne "${YELLOW}Desea reinstalar el paquete? (s/N): ${NC}"
    read -r CONFIRMAR
    if [[ ! "$CONFIRMAR" =~ ^[Ss]$ ]]; then
        msg_alert "Omitiendo instalacion..."
        return 0
    fi
    msg_info "Desinstalando paquete 'dhcp-server'..."
    sudo dnf remove -y dhcp-server &>/dev/null
    _instalar_paquete_dhcp
}

# Verifica si dhcp-server esta instalado.
# $1 = "1" → modo instalacion/reinstalacion interactiva
#      "0" → modo silencioso (falla si no esta instalado)
verificar_instalar_dhcp() {
    local flag=$1
    separator
    msg_process "Verificando presencia de dhcp-server..."
    sleep 1

    if rpm -q dhcp-server &>/dev/null; then
        msg_success "dhcp-server ya instalado"
        [ "$flag" -eq "1" ] && { sleep 1; _reinstalar_dhcp; }
        return 0
    fi

    msg_alert "dhcp-server no encontrado."

    if [ "$flag" -eq "1" ]; then
        sleep 1
        msg_input "${YELLOW}Desea instalar el paquete? (s/N): ${NC}"
        read -r CONFIRMAR
        if [[ "$CONFIRMAR" =~ ^[Ss]$ ]]; then
            _instalar_paquete_dhcp
        else
            msg_alert "Omitiendo instalacion..."
        fi
        return 0
    fi

    msg_error "Instale el servidor DHCP primero para configurar"
    return 1
}

# =============================================================================
# COLOREO DE LOGS (interno de DHCP)
# =============================================================================

_colorear_evento_dhcp() {
    local line=$1
    local evento color
    for evento in DHCPACK DHCPREQUEST DHCPDISCOVER DHCPRELEASE DHCPNAK DHCPOFFER; do
        if echo "$line" | grep -q "$evento"; then
            case "$evento" in
                DHCPACK)      color=$GREEN  ;;
                DHCPREQUEST)  color=$CYAN   ;;
                DHCPDISCOVER) color=$BLUE   ;;
                DHCPRELEASE)  color=$YELLOW ;;
                DHCPNAK)      color=$RED    ;;
                *)            color=$NC     ;;
            esac
            echo "$line" | sed "s/$evento/${color}${evento}${NC}/" | sed 's/^/  /'
            return
        fi
    done
    echo "  $line"
}

# =============================================================================
# CONFIGURACION INTERACTIVA
# =============================================================================

configurar_dhcp() {
    verificar_herramientas_red

    separator
    echo -e "${WHITE}=== CONFIGURACION SERVIDOR DHCP ===${NC}"
    separator
    echo ""

    # --- Nombre del scope ---
    while true; do
        msg_input "Nombre del scope: "
        read -r SCOPE_NAME
        [ -n "$SCOPE_NAME" ] && break
        msg_error "El nombre no puede estar vacio"
    done
    msg_success "Scope: $SCOPE_NAME"
    echo ""

    # --- Seleccion de interfaz ---
    separator
    msg_process "Interfaces de red disponibles:"
    echo ""
    mapfile -t INTERFACES < <(ip -o link show | awk -F': ' '{if ($2 != "lo") print $2}')
    if [ ${#INTERFACES[@]} -eq 0 ]; then
        msg_error "No se encontraron interfaces de red"; return 1
    fi
    for i in "${!INTERFACES[@]}"; do
        echo "  $((i+1)). ${INTERFACES[$i]}"
    done
    echo ""
    while true; do
        msg_input "Seleccione la interfaz (numero): "
        read -r INTERFAZ_NUM
        if [[ "$INTERFAZ_NUM" =~ ^[0-9]+$ ]] \
            && [ "$INTERFAZ_NUM" -ge 1 ] \
            && [ "$INTERFAZ_NUM" -le ${#INTERFACES[@]} ]; then
            INTERFAZ="${INTERFACES[$((INTERFAZ_NUM-1))]}"
            break
        fi
        msg_error "Seleccion invalida"
    done

    INTERFAZ_IP=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ -n "$INTERFAZ_IP" ]; then
        msg_success "Interfaz: $INTERFAZ (IP actual: $INTERFAZ_IP)"
    else
        msg_success "Interfaz: $INTERFAZ (sin IP configurada)"
    fi
    echo ""

    # --- Segmento de red ---
    separator
    msg_info "Ingrese el segmento de red en formato CIDR"
    msg_info "Ejemplos: 192.168.1.0/24, 172.16.0.0/16, 10.0.0.0/8"
    echo ""
    local intentos=0
    while [ $intentos -lt $MAX_ATTEMPTS ]; do
        msg_input "Segmento de red (IP/CIDR): "
        read -r NETWORK_INPUT
        if ! [[ "$NETWORK_INPUT" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            msg_error "Formato invalido. Use: IP/CIDR (ejemplo: 192.168.1.0/24)"
            intentos=$((intentos + 1)); continue
        fi
        IFS='/' read -r NETWORK_ADDRESS CIDR <<< "$NETWORK_INPUT"
        if ! validar_ip "$NETWORK_ADDRESS"; then
            msg_error "IP invalida o en segmento no usable"
            intentos=$((intentos + 1)); continue
        fi
        if ! validar_cidr "$CIDR"; then
            msg_error "CIDR invalido. Debe estar entre /8 y /30"
            intentos=$((intentos + 1)); continue
        fi
        MASCARA=$(cidr_a_mascara "$CIDR")
        [ -z "$MASCARA" ] && { msg_error "Error calculando mascara"; intentos=$((intentos + 1)); continue; }
        local red_calculada
        red_calculada=$(obtener_direccion_red "$NETWORK_ADDRESS" "$MASCARA")
        [ -z "$red_calculada" ] && { msg_error "Error calculando red"; intentos=$((intentos + 1)); continue; }
        if [ "$NETWORK_ADDRESS" != "$red_calculada" ]; then
            msg_error "La IP ($NETWORK_ADDRESS) no es la direccion de red del segmento"
            msg_info  "La direccion correcta es: $red_calculada/$CIDR"
            intentos=$((intentos + 1)); continue
        fi
        BROADCAST_ADDRESS=$(obtener_broadcast "$NETWORK_ADDRESS" "$MASCARA")
        [ -z "$BROADCAST_ADDRESS" ] && { msg_error "Error calculando broadcast"; intentos=$((intentos + 1)); continue; }
        break
    done
    [ $intentos -ge $MAX_ATTEMPTS ] && { msg_error "Demasiados intentos fallidos"; return 1; }
    msg_success "Red: $NETWORK_ADDRESS/$CIDR"
    msg_success "Mascara: $MASCARA"
    msg_success "Broadcast: $BROADCAST_ADDRESS"
    echo ""

    # --- IP de inicio del rango ---
    separator
    msg_info "La primera IP sera asignada al adaptador $INTERFAZ"
    msg_info "El rango DHCP iniciara desde la segunda IP"
    echo ""
    local IP_INICIO_INPUT; intentos=0
    while [ $intentos -lt $MAX_ATTEMPTS ]; do
        msg_input "IP de inicio del rango: "
        read -r IP_INICIO_INPUT
        if ! validar_ip_en_segmento "$IP_INICIO_INPUT" "de inicio del rango"; then
            intentos=$((intentos + 1)); continue
        fi
        IP_ADAPTADOR="$IP_INICIO_INPUT"
        local ip_adaptador_int
        ip_adaptador_int=$(ip_a_entero "$IP_ADAPTADOR")
        IP_INICIO=$(entero_a_ip $((ip_adaptador_int + 1)))
        break
    done
    [ $intentos -ge $MAX_ATTEMPTS ] && { msg_error "Demasiados intentos fallidos"; return 1; }
    msg_success "IP del adaptador: $IP_ADAPTADOR"
    msg_success "IP de inicio del rango DHCP: $IP_INICIO"
    echo ""

    # --- IP de fin del rango ---
    separator
    intentos=0
    while [ $intentos -lt $MAX_ATTEMPTS ]; do
        msg_input "IP de fin del rango: "
        read -r IP_FIN
        if ! validar_ip_en_segmento "$IP_FIN" "de fin del rango"; then
            intentos=$((intentos + 1)); continue
        fi
        local ip_inicio_int ip_fin_int
        ip_inicio_int=$(ip_a_entero "$IP_INICIO")
        ip_fin_int=$(ip_a_entero "$IP_FIN")
        if [ $ip_fin_int -le $ip_inicio_int ]; then
            msg_error "La IP de fin debe ser mayor que la IP de inicio ($IP_INICIO)"
            intentos=$((intentos + 1)); continue
        fi
        break
    done
    [ $intentos -ge $MAX_ATTEMPTS ] && { msg_error "Demasiados intentos fallidos"; return 1; }
    msg_success "Rango DHCP: $IP_INICIO → $IP_FIN"
    echo ""

    # --- DNS (opcional) ---
    separator
    msg_input "${YELLOW}Desea configurar servidores DNS? (s/N): ${NC}"
    read -r CONFIGURAR_DNS
    echo ""
    DNS_SERVER1="" DNS_SERVER2=""
    if [[ "$CONFIGURAR_DNS" =~ ^[Ss]$ ]]; then
        msg_info "Configuracion de DNS primario"
        echo ""
        if ! pedir_ip_loop DNS_SERVER1 "DNS primario (Enter para omitir): "; then return 1; fi
        if [ -z "$DNS_SERVER1" ]; then
            msg_alert "DNS primario omitido"
        else
            msg_success "DNS primario: $DNS_SERVER1"
            echo ""
            msg_input "${YELLOW}Desea agregar DNS secundario? (s/N): ${NC}"
            read -r AGREGAR_DNS2
            echo ""
            if [[ "$AGREGAR_DNS2" =~ ^[Ss]$ ]]; then
                if ! pedir_ip_loop DNS_SERVER2 "DNS secundario (Enter para omitir): "; then return 1; fi
                [ -z "$DNS_SERVER2" ] && msg_alert "DNS secundario omitido" || msg_success "DNS secundario: $DNS_SERVER2"
            fi
        fi
    else
        msg_alert "Configuracion de DNS omitida"
    fi
    echo ""

    # --- Gateway (opcional) ---
    separator
    msg_info "Gateway (puerta de enlace) - Dato opcional"
    echo ""
    intentos=0
    while [ $intentos -lt $MAX_ATTEMPTS ]; do
        msg_input "Gateway (Enter para omitir): "
        read -r GATEWAY
        if [ -z "$GATEWAY" ]; then msg_alert "Gateway omitido"; break; fi
        if ! validar_ip_en_segmento "$GATEWAY" "gateway"; then
            intentos=$((intentos + 1)); continue
        fi
        msg_success "Gateway: $GATEWAY"; break
    done
    [ $intentos -ge $MAX_ATTEMPTS ] && { msg_error "Demasiados intentos fallidos"; return 1; }
    echo ""

    # --- Lease time ---
    separator
    intentos=0
    while [ $intentos -lt $MAX_ATTEMPTS ]; do
        msg_input "Lease time en segundos [default=86400/24h]: "
        read -r LEASE_INPUT
        if [ -z "$LEASE_INPUT" ]; then LEASE_TIME=86400; break; fi
        if [[ "$LEASE_INPUT" =~ ^[0-9]+$ ]] && [ "$LEASE_INPUT" -gt 0 ] && [ "$LEASE_INPUT" -le 31536000 ]; then
            LEASE_TIME=$LEASE_INPUT; break
        fi
        msg_error "Debe ser un numero entero entre 1 y 31536000"
        intentos=$((intentos + 1))
    done
    [ $intentos -ge $MAX_ATTEMPTS ] && { msg_error "Demasiados intentos fallidos"; return 1; }
    msg_success "Lease time: $LEASE_TIME segundos"

    # --- Resumen y confirmacion ---
    echo ""
    separator
    echo -e "${WHITE}Resumen de configuracion${NC}"
    echo ""
    echo -e "  ${CYAN}Scope:${NC}              $SCOPE_NAME"
    echo -e "  ${CYAN}Interfaz:${NC}           $INTERFAZ"
    echo -e "  ${CYAN}IP de Interfaz:${NC}     $IP_ADAPTADOR"
    echo -e "  ${CYAN}Segmento:${NC}           $NETWORK_ADDRESS/$CIDR"
    echo -e "  ${CYAN}Mascara:${NC}            $MASCARA"
    echo -e "  ${CYAN}Broadcast:${NC}          $BROADCAST_ADDRESS"
    echo -e "  ${CYAN}Rango DHCP:${NC}         $IP_INICIO -> $IP_FIN"
    [ -n "$GATEWAY"     ] && echo -e "  ${CYAN}Gateway:${NC}            $GATEWAY"          || echo -e "  ${CYAN}Gateway:${NC}            ${YELLOW}(no configurado)${NC}"
    [ -n "$DNS_SERVER1" ] && echo -e "  ${CYAN}DNS Primario:${NC}       $DNS_SERVER1"      || echo -e "  ${CYAN}DNS Primario:${NC}       ${YELLOW}(no configurado)${NC}"
    [ -n "$DNS_SERVER2" ] && echo -e "  ${CYAN}DNS Secundario:${NC}     $DNS_SERVER2"      || echo -e "  ${CYAN}DNS Secundario:${NC}     ${YELLOW}(no configurado)${NC}"
    echo -e "  ${CYAN}Lease Time:${NC}         $LEASE_TIME segundos"
    echo ""
    separator
    echo ""

    msg_input "${YELLOW}Desea usar esta configuracion? (s/N): ${NC}"
    read -r CONFIRMAR
    if [[ ! "$CONFIRMAR" =~ ^[Ss]$ ]]; then
        msg_alert "Configuracion cancelada por el usuario"; return 1
    fi

    _aplicar_configuracion_dhcp
}

_aplicar_configuracion_dhcp() {
    echo ""
    msg_process "Generando archivo de configuracion..."

    local DNS_CONFIG="" GATEWAY_CONFIG=""
    if [ -n "$DNS_SERVER1" ]; then
        [ -n "$DNS_SERVER2" ] \
            && DNS_CONFIG="    option domain-name-servers $DNS_SERVER1, $DNS_SERVER2;" \
            || DNS_CONFIG="    option domain-name-servers $DNS_SERVER1;"
    fi
    [ -n "$GATEWAY" ] && GATEWAY_CONFIG="    option routers $GATEWAY;"

    sudo tee /etc/dhcp/dhcpd.conf > /dev/null <<EOF
# Configuracion DHCP - $SCOPE_NAME
# Generado: $(date)
# Interfaz: $INTERFAZ

authoritative;
default-lease-time $LEASE_TIME;
max-lease-time $((LEASE_TIME * 2));

subnet $NETWORK_ADDRESS netmask $MASCARA {
    range $IP_INICIO $IP_FIN;
    $GATEWAY_CONFIG
$DNS_CONFIG
    option subnet-mask $MASCARA;
}
EOF

    msg_success "Archivo de configuracion creado"
    msg_process "Validando configuracion..."
    if sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf 2>&1 | grep -q "Configuration file errors encountered"; then
        msg_error "Error en la configuracion"; return 1
    fi
    msg_success "Configuracion validada correctamente"

    msg_process "Configurando interfaz de red..."
    if [ -n "$INTERFAZ_IP" ] && ! ip_en_red "$INTERFAZ_IP" "$NETWORK_ADDRESS" "$MASCARA"; then
        echo ""
        msg_error "INCOMPATIBILIDAD DETECTADA"
        msg_alert "La interfaz '$INTERFAZ' tiene IP: $INTERFAZ_IP"
        msg_alert "Esta IP NO pertenece a la red DHCP: $NETWORK_ADDRESS/$CIDR"
    elif [ -z "$INTERFAZ_IP" ]; then
        msg_alert "La interfaz '$INTERFAZ' no tiene IP asignada"
    fi
    configurar_ip_interfaz || return 1

    echo "DHCPDARGS=\"$INTERFAZ\"" | sudo tee /etc/sysconfig/dhcpd > /dev/null
    msg_success "Interfaz de escucha configurada"

    msg_process "Configurando firewall..."
    if ! systemctl is-active --quiet firewalld; then
        msg_process "Iniciando firewalld..."
        sudo systemctl start firewalld
    fi
    sudo firewall-cmd --permanent --zone=internal --add-service=dhcp &>/dev/null
    sudo firewall-cmd --reload &>/dev/null
    msg_success "Reglas de firewall aplicadas"

    msg_process "Iniciando DHCP..."
    sudo systemctl enable dhcpd &>/dev/null
    sudo systemctl restart dhcpd
    sleep 1
    if systemctl is-active --quiet dhcpd; then
        echo ""; msg_success "Servidor DHCP configurado y activo"; echo ""; return 0
    else
        echo ""; msg_error "El servicio no pudo iniciarse"; echo ""
        msg_alert "Logs del servicio:"; echo ""
        sudo journalctl -u dhcpd -n 20 --no-pager
        return 1
    fi
}

# =============================================================================
# MONITOREO
# =============================================================================

monitorear_dhcp() {
    clear; separator; echo ""
    echo -e "${WHITE}--- ESTADO DE DHCP ---${NC}"; echo ""

    if [ ! -f /etc/dhcp/dhcpd.conf ]; then
        msg_error "No hay configuracion de DHCP"
        msg_info  "Configure el servidor DHCP primero (opcion 2)"
        echo ""; separator; return 1
    fi

    sleep 1; echo ""
    echo -e "${WHITE}Estado del servicio:${NC}"; echo ""

    if systemctl is-active --quiet dhcpd; then
        local uptime; uptime=$(systemctl show dhcpd --property=ActiveEnterTimestamp --value)
        echo -e "  Estado:          ${GREEN}ACTIVO${NC}"
        echo -e "  Inicio:          $(echo "$uptime" | awk '{print $2, $3}')"
        echo -e "  PID:             $(systemctl show dhcpd --property=MainPID --value)"
    else
        echo -e "  Estado:          ${RED}INACTIVO${NC}"; echo ""
        msg_alert "El servicio DHCP no esta corriendo"
        msg_info  "Inicie el servicio desde el menu principal"
        echo ""; separator; return 1
    fi

    sleep 1; echo ""
    echo -e "${WHITE}Configuracion actual:${NC}"; echo ""

    local subnet range router dns lease_time
    subnet=$(grep "^subnet" /etc/dhcp/dhcpd.conf | awk '{print $2"/"$4}' | head -1)
    range=$(grep "range" /etc/dhcp/dhcpd.conf | grep -v "^#" | awk '{print $2" - "$3}' | tr -d ';')
    router=$(grep "option routers" /etc/dhcp/dhcpd.conf | grep -v "^#" | awk '{print $3}' | tr -d ';')
    dns=$(grep "option domain-name-servers" /etc/dhcp/dhcpd.conf | grep -v "^#" \
        | awk '{for(i=3;i<=NF;i++) printf "%s ", $i}' | tr -d ';')
    lease_time=$(grep "default-lease-time" /etc/dhcp/dhcpd.conf | awk '{print $2}' | tr -d ';')

    echo -e "  ${CYAN}Red:${NC}             $subnet"
    echo -e "  ${CYAN}Rango DHCP:${NC}      $range"
    [ -n "$router"     ] && echo -e "  ${CYAN}Gateway:${NC}         $router"     || echo -e "  ${CYAN}Gateway:${NC}         ${YELLOW}(no configurado)${NC}"
    [ -n "$dns"        ] && echo -e "  ${CYAN}DNS:${NC}             $dns"         || echo -e "  ${CYAN}DNS:${NC}             ${YELLOW}(no configurado)${NC}"
    [ -n "$lease_time" ] && echo -e "  ${CYAN}Lease Time:${NC}      $((lease_time/3600))h ($lease_time seg)"
    echo ""

    sleep 1
    echo -e "${WHITE}Clientes activos (leases):${NC}"; echo ""

    if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
        local leases_info
        leases_info=$(sudo awk '
            /^lease/               { ip = $2; delete data }
            /binding state active/ { data["state"] = "active" }
            /hardware ethernet/    { data["mac"] = $3; gsub(/;/, "", data["mac"]) }
            /client-hostname/      { data["hostname"] = $2; gsub(/[";]/, "", data["hostname"]) }
            /ends/                 { data["ends"] = $3 " " $4; gsub(/;/, "", data["ends"]) }
            /}/ {
                if (data["state"] == "active")
                    printf "%s|%s|%s|%s\n",
                        ip,
                        (data["hostname"] ? data["hostname"] : "Sin nombre"),
                        (data["mac"]      ? data["mac"]      : "N/A"),
                        (data["ends"]     ? data["ends"]     : "N/A")
            }
        ' /var/lib/dhcpd/dhcpd.leases | sort -u -t'|' -k1,1)

        if [ -n "$leases_info" ]; then
            msg_info "Concesiones activas: $(echo "$leases_info" | wc -l)"; echo ""
            echo "$leases_info" | while IFS='|' read -r ip hostname mac expires; do
                echo "  IP     : $ip"
                echo "    Host   : $hostname"
                echo "    MAC    : $mac"
                echo "    Estado : ACTIVO"
                echo "    Expira : $expires"
                echo ""
            done
        else
            msg_info "Sin concesiones activas"; echo ""
        fi
    else
        msg_info "Sin concesiones activas"; echo ""
    fi

    sleep 1; separator; echo ""
    echo -e "${WHITE}Actividad reciente:${NC}"; echo ""

    sudo journalctl -u dhcpd -n 20 --no-pager 2>/dev/null \
        | grep -E "DHCPREQUEST|DHCPACK|DHCPDISCOVER|DHCPNAK|DHCPRELEASE|DHCPOFFER" \
        | tail -10 \
        | while read -r line; do _colorear_evento_dhcp "$line"; done

    [ -z "$(sudo journalctl -u dhcpd -n 1 --no-pager 2>/dev/null)" ] \
        && echo -e "  ${YELLOW}No hay actividad reciente${NC}"

    echo ""; separator; echo ""
}

# =============================================================================
# AYUDA
# =============================================================================

show_help() {
    cat <<EOF
DHCP Manager - Fedora

USO INTERACTIVO:
  sudo ./dhcp_manager.sh

USO POR PARAMETROS:
  sudo ./dhcp_manager.sh [COMANDO] [OPCIONES]

COMANDOS:
  install                        Instala/reinstala dhcp-server
  configure                      Configura el servidor DHCP (interactivo)
  status                         Muestra estado, leases y actividad reciente
  restart                        Reinicia el servicio dhcpd
  menu                           Abre el menu interactivo (por defecto si sin args)

  -h, --help                     Muestra esta ayuda

EJEMPLOS:
  sudo ./dhcp_manager.sh install
  sudo ./dhcp_manager.sh configure
  sudo ./dhcp_manager.sh status
  sudo ./dhcp_manager.sh restart
EOF
}

# =============================================================================
# MENU INTERACTIVO
# =============================================================================

menu() {
    while true; do
        clear; sleep 1; separator; echo ""
        echo -e "${WHITE}--- MENU PRINCIPAL ---${NC}"; echo ""
        echo -e "  ${GREEN}1.${NC} Instalar/Reinstalar DHCP"
        echo -e "  ${GREEN}2.${NC} Configurar servidor DHCP"
        echo -e "  ${GREEN}3.${NC} Ver estado y concesiones"
        echo -e "  ${GREEN}4.${NC} Reiniciar servicio"
        echo -e "  ${GREEN}5.${NC} Salir"
        echo ""; separator; echo ""
        msg_input "Seleccione una opcion: "
        read -r opcion
        sleep 1

        case $opcion in
            1) sleep 1; verificar_instalar_dhcp "1" ;;
            2) clear; sleep 1
               if verificar_instalar_dhcp "0"; then sleep 1; configurar_dhcp; fi ;;
            3) clear; monitorear_dhcp ;;
            4) msg_process "Reiniciando servicio DHCP..."
               sudo systemctl restart dhcpd; sleep 1
               [ $? -eq 0 ] && msg_success "Servicio reiniciado" || msg_error "No se pudo reiniciar el servicio" ;;
            5) msg_info "Saliendo..."; sleep 1; exit 0 ;;
            *) msg_error "Opcion invalida" ;;
        esac

        echo ""
        read -rp "Presione ENTER para continuar..."
    done
}

# =============================================================================
# ROUTER DE COMANDOS
# =============================================================================

main() {
    # Sin argumentos → menu interactivo
    if [[ $# -eq 0 ]]; then
        menu
        return
    fi

    local command="$1"; shift

    case "$command" in
        -h|--help) show_help ;;

        install)
            verificar_instalar_dhcp "1"
            ;;

        configure)
            if verificar_instalar_dhcp "0"; then
                configurar_dhcp
            fi
            ;;

        status)
            monitorear_dhcp
            ;;

        restart)
            msg_process "Reiniciando servicio DHCP..."
            sudo systemctl restart dhcpd
            sleep 1
            if [ $? -eq 0 ]; then
                msg_success "Servicio reiniciado"
            else
                msg_error "No se pudo reiniciar el servicio"
                exit 1
            fi
            ;;

        menu)
            menu
            ;;

        *)
            msg_error "Comando desconocido: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"