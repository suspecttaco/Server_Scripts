#!/bin/bash
# =============================================================================
# ssh_manager.sh — Gestor de OpenSSH Server (Fedora Server 43)
#
# Uso interactivo:    sudo ./ssh_manager.sh
# Uso por parametros: sudo ./ssh_manager.sh [COMANDO] [OPCIONES]
#
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

# =============================================================================
# CONSTANTES
# =============================================================================

readonly SSH_SERVICE="sshd"
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_CONFIG_BAK="/etc/ssh/sshd_config.bak"
readonly SSHD_HARDENING_CONF="/etc/ssh/sshd_config.d/99-hardening.conf"
readonly SSH_DEFAULT_PORT=22

MAX_ATTEMPTS=${MAX_ATTEMPTS:-100}

# =============================================================================
# VERIFICACION DE PRIVILEGIOS
# =============================================================================

_check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_error "Este script debe ejecutarse como root."
        msg_info  "Usa: sudo $0"
        exit 1
    fi
}

# =============================================================================
# INSTALACION (idempotente)
# =============================================================================

instalar_ssh() {
    separator
    echo -e "${WHITE}=== INSTALACION OpenSSH Server ===${NC}"
    separator
    echo ""

    msg_process "Verificando openssh-server..."

    if rpm -q openssh-server &>/dev/null; then
        msg_success "openssh-server ya esta instalado"
        local version
        version=$(rpm -q --queryformat '%{VERSION}' openssh-server)
        msg_info "Version instalada: $version"
    else
        msg_process "Instalando openssh-server..."
        if dnf install -y openssh-server &>/dev/null; then
            msg_success "openssh-server instalado correctamente"
        else
            msg_error "Fallo la instalacion de openssh-server"
            return 1
        fi
    fi

    # Asegurar que el servicio este habilitado
    if ! systemctl is-enabled --quiet "$SSH_SERVICE" 2>/dev/null; then
        msg_process "Habilitando servicio $SSH_SERVICE al arranque..."
        systemctl enable "$SSH_SERVICE" &>/dev/null
        msg_success "Servicio habilitado"
    else
        msg_info "Servicio ya habilitado en el arranque"
    fi

    # Iniciar si no corre
    if ! systemctl is-active --quiet "$SSH_SERVICE"; then
        msg_process "Iniciando servicio $SSH_SERVICE..."
        systemctl start "$SSH_SERVICE" && msg_success "Servicio iniciado" || {
            msg_error "No se pudo iniciar el servicio"
            return 1
        }
    else
        msg_info "Servicio ya en ejecucion"
    fi

    echo ""
    msg_success "Instalacion completada"
    echo ""
}

# =============================================================================
# FIREWALL
# =============================================================================

# $1 = puerto SSH (default 22)
# $2 = interfaz (opcional — si se omite aplica a todas)
configurar_firewall_ssh() {
    local puerto="${1:-$SSH_DEFAULT_PORT}"
    local interfaz="$2"

    separator
    echo -e "${WHITE}=== CONFIGURACION FIREWALL ===${NC}"
    separator
    echo ""

    if ! check_dependency firewall-cmd; then
        msg_alert "firewalld no esta instalado, omitiendo configuracion de firewall"
        return 0
    fi

    if ! systemctl is-active --quiet firewalld; then
        msg_process "Iniciando firewalld..."
        systemctl start firewalld
    fi

    # Determinar zona
    local zona
    if [[ -n "$interfaz" ]] && check_interface_exists "$interfaz"; then
        zona=$(get_interface_firewall_zone "$interfaz")
        msg_info "Zona detectada para $interfaz: $zona"
    else
        zona=$(firewall-cmd --get-default-zone 2>/dev/null)
        msg_info "Usando zona por defecto: $zona"
    fi

    # Puerto 22 → servicio ssh; otro puerto → puerto directo
    if [[ "$puerto" -eq 22 ]]; then
        msg_process "Habilitando servicio ssh en zona '$zona'..."
        firewall-cmd --zone="$zona" --permanent --add-service=ssh &>/dev/null
    else
        # Mantener tambien el servicio ssh para no bloquear conexiones activas
        firewall-cmd --zone="$zona" --permanent --add-service=ssh &>/dev/null
        msg_process "Habilitando puerto $puerto/tcp en zona '$zona'..."
        firewall-cmd --zone="$zona" --permanent --add-port="${puerto}/tcp" &>/dev/null
    fi

    firewall-cmd --reload &>/dev/null
    msg_success "Firewall configurado — zona: $zona, puerto: $puerto"
    echo ""
}

# Elimina la regla de un puerto SSH previo cuando se cambia el puerto
_firewall_eliminar_puerto() {
    local puerto="$1" zona="$2"
    [[ "$puerto" -eq 22 ]] && return 0
    firewall-cmd --zone="$zona" --permanent --remove-port="${puerto}/tcp" &>/dev/null || true
    firewall-cmd --reload &>/dev/null
}

# =============================================================================
# CONFIGURACION DE SSHD
# =============================================================================

# Lee el valor actual de una directiva en sshd_config
_leer_directiva() {
    local clave="$1"
    grep -i "^[[:space:]]*${clave}[[:space:]]" "$SSHD_CONFIG" 2>/dev/null \
        | awk '{print $2}' | tail -1
}

# Establece o reemplaza una directiva en sshd_config
_set_directiva() {
    local clave="$1" valor="$2"

    if grep -qi "^[[:space:]]*${clave}[[:space:]]" "$SSHD_CONFIG"; then
        # Reemplazar linea existente (comentada o no)
        sed -i "s|^[[:space:]#]*${clave}[[:space:]].*|${clave} ${valor}|I" "$SSHD_CONFIG"
    else
        echo "${clave} ${valor}" >> "$SSHD_CONFIG"
    fi
}

configurar_ssh() {
    separator
    echo -e "${WHITE}=== CONFIGURACION SSH ===${NC}"
    separator
    echo ""

    # Backup antes de tocar nada
    if [[ ! -f "$SSHD_CONFIG_BAK" ]]; then
        cp "$SSHD_CONFIG" "$SSHD_CONFIG_BAK"
        msg_info "Backup creado en $SSHD_CONFIG_BAK"
    fi

    local puerto_actual
    puerto_actual=$(_leer_directiva "Port")
    puerto_actual="${puerto_actual:-22}"

    # --- Puerto ---
    separator
    msg_info "Puerto actual: $puerto_actual"
    echo ""
    local nuevo_puerto intentos=0
    while [ $intentos -lt $MAX_ATTEMPTS ]; do
        msg_input "Nuevo puerto SSH [Enter = mantener $puerto_actual]: "
        read -r nuevo_puerto
        if [[ -z "$nuevo_puerto" ]]; then
            nuevo_puerto="$puerto_actual"; break
        fi
        if [[ "$nuevo_puerto" =~ ^[0-9]+$ ]] && [ "$nuevo_puerto" -ge 1 ] && [ "$nuevo_puerto" -le 65535 ]; then
            break
        fi
        msg_error "Puerto invalido (1-65535)"
        intentos=$((intentos + 1))
    done
    [ $intentos -ge $MAX_ATTEMPTS ] && { msg_error "Demasiados intentos"; return 1; }

    # --- Interfaz para firewall ---
    echo ""
    separator
    msg_process "Interfaces de red disponibles:"
    echo ""
    list_network_interfaces
    echo ""
    msg_input "Interfaz para firewall [Enter = zona por defecto]: "
    read -r INTERFAZ_SSH

    # --- Autenticacion por contraseña ---
    echo ""
    separator
    local passauth_actual
    passauth_actual=$(_leer_directiva "PasswordAuthentication")
    passauth_actual="${passauth_actual:-yes}"
    msg_info "PasswordAuthentication actual: $passauth_actual"
    echo ""
    msg_input "Permitir autenticacion por contrasena? (s/N) [actual: $passauth_actual]: "
    read -r resp_passauth
    local passauth="no"
    [[ "$resp_passauth" =~ ^[Ss]$ ]] && passauth="yes"

    # --- PermitRootLogin ---
    echo ""
    separator
    local rootlogin_actual
    rootlogin_actual=$(_leer_directiva "PermitRootLogin")
    rootlogin_actual="${rootlogin_actual:-yes}"
    msg_info "PermitRootLogin actual: $rootlogin_actual"
    echo ""
    echo -e "  ${GREEN}1.${NC} no               (recomendado)"
    echo -e "  ${GREEN}2.${NC} prohibit-password (solo claves)"
    echo -e "  ${GREEN}3.${NC} yes               (sin restriccion)"
    echo ""
    msg_input "Opcion [Enter = mantener $rootlogin_actual]: "
    read -r resp_root
    local rootlogin
    case "$resp_root" in
        1) rootlogin="no" ;;
        2) rootlogin="prohibit-password" ;;
        3) rootlogin="yes" ;;
        *) rootlogin="$rootlogin_actual" ;;
    esac

    # --- MaxAuthTries ---
    echo ""
    separator
    local maxtries_actual
    maxtries_actual=$(_leer_directiva "MaxAuthTries")
    maxtries_actual="${maxtries_actual:-6}"
    msg_info "MaxAuthTries actual: $maxtries_actual"
    echo ""
    intentos=0
    local maxtries
    while [ $intentos -lt $MAX_ATTEMPTS ]; do
        msg_input "MaxAuthTries [Enter = mantener $maxtries_actual]: "
        read -r maxtries
        if [[ -z "$maxtries" ]]; then maxtries="$maxtries_actual"; break; fi
        if [[ "$maxtries" =~ ^[0-9]+$ ]] && [ "$maxtries" -ge 1 ] && [ "$maxtries" -le 20 ]; then
            break
        fi
        msg_error "Valor invalido (1-20)"
        intentos=$((intentos + 1))
    done

    # --- ClientAliveInterval ---
    echo ""
    separator
    local alive_actual
    alive_actual=$(_leer_directiva "ClientAliveInterval")
    alive_actual="${alive_actual:-0}"
    msg_info "ClientAliveInterval actual: ${alive_actual}s (0=desactivado)"
    echo ""
    intentos=0
    local alive
    while [ $intentos -lt $MAX_ATTEMPTS ]; do
        msg_input "ClientAliveInterval en segundos [Enter = mantener $alive_actual]: "
        read -r alive
        if [[ -z "$alive" ]]; then alive="$alive_actual"; break; fi
        if [[ "$alive" =~ ^[0-9]+$ ]]; then break; fi
        msg_error "Debe ser un numero entero >= 0"
        intentos=$((intentos + 1))
    done

    # --- Banner (opcional) ---
    echo ""
    separator
    local banner_actual
    banner_actual=$(_leer_directiva "Banner")
    msg_info "Banner actual: ${banner_actual:-none}"
    echo ""
    msg_input "Activar banner de advertencia en /etc/ssh/banner? (s/N): "
    read -r resp_banner
    local banner_valor="none"
    if [[ "$resp_banner" =~ ^[Ss]$ ]]; then
        banner_valor="/etc/ssh/banner"
        if [[ ! -f /etc/ssh/banner ]]; then
            cat > /etc/ssh/banner <<'BANNER'
*******************************************************************************
*  ACCESO RESTRINGIDO — Solo usuarios autorizados.                            *
*  Toda actividad puede ser registrada y monitoreada.                         *
*******************************************************************************
BANNER
            msg_success "Banner creado en /etc/ssh/banner"
        fi
    fi

    # --- Resumen ---
    echo ""
    separator
    echo -e "${WHITE}Resumen de configuracion SSH${NC}"
    echo ""
    echo -e "  ${CYAN}Puerto:${NC}                   $nuevo_puerto"
    echo -e "  ${CYAN}Interfaz firewall:${NC}        ${INTERFAZ_SSH:-zona por defecto}"
    echo -e "  ${CYAN}PasswordAuthentication:${NC}   $passauth"
    echo -e "  ${CYAN}PermitRootLogin:${NC}          $rootlogin"
    echo -e "  ${CYAN}MaxAuthTries:${NC}             $maxtries"
    echo -e "  ${CYAN}ClientAliveInterval:${NC}      $alive"
    echo -e "  ${CYAN}Banner:${NC}                   $banner_valor"
    echo ""
    separator
    echo ""
    msg_input "${YELLOW}Aplicar esta configuracion? (s/N): ${NC}"
    read -r confirmar
    [[ ! "$confirmar" =~ ^[Ss]$ ]] && { msg_alert "Configuracion cancelada"; return 1; }

    # --- Aplicar ---
    _set_directiva "Port"                    "$nuevo_puerto"
    _set_directiva "PasswordAuthentication"  "$passauth"
    _set_directiva "PermitRootLogin"         "$rootlogin"
    _set_directiva "MaxAuthTries"            "$maxtries"
    _set_directiva "ClientAliveInterval"     "$alive"
    _set_directiva "ClientAliveCountMax"     "3"
    _set_directiva "Banner"                  "$banner_valor"

    msg_success "sshd_config actualizado"

    # Configurar firewall con el nuevo puerto
    configurar_firewall_ssh "$nuevo_puerto" "$INTERFAZ_SSH"

    _recargar_servicio
}

# =============================================================================
# HARDENING
# =============================================================================

aplicar_hardening() {
    separator
    echo -e "${WHITE}=== HARDENING SSH ===${NC}"
    separator
    echo ""
    msg_info "Se aplicara un perfil de hardening recomendado para Fedora Server."
    msg_info "Se guardara en: $SSHD_HARDENING_CONF"
    echo ""
    msg_input "${YELLOW}Confirmar aplicacion de hardening? (s/N): ${NC}"
    read -r confirmar
    [[ ! "$confirmar" =~ ^[Ss]$ ]] && { msg_alert "Operacion cancelada"; return 0; }

    # Backup del config principal si no existe
    [[ ! -f "$SSHD_CONFIG_BAK" ]] && cp "$SSHD_CONFIG" "$SSHD_CONFIG_BAK" \
        && msg_info "Backup creado en $SSHD_CONFIG_BAK"

    mkdir -p /etc/ssh/sshd_config.d

    cat > "$SSHD_HARDENING_CONF" <<'EOF'
# =============================================================================
# Hardening SSH — generado por ssh_manager.sh
# =============================================================================

# Protocolo y cifrado
Protocol 2

# Autenticacion
PermitRootLogin no
PermitEmptyPasswords no
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30

# Solo autenticacion por clave (deshabilitar password)
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes

# Reenvio y tunel (deshabilitar si no se necesita)
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no

# Keepalive para detectar clientes caidos
ClientAliveInterval 300
ClientAliveCountMax 2

# Logging
SyslogFacility AUTHPRIV
LogLevel VERBOSE

# Criptografia moderna (Fedora 43 soporta estos algoritmos)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com

# Claves del host aceptadas
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256

# Otros
StrictModes yes
IgnoreRhosts yes
HostbasedAuthentication no
PrintLastLog yes
EOF

    msg_success "Perfil de hardening escrito en $SSHD_HARDENING_CONF"

    # Validar y recargar
    if sshd -t &>/dev/null; then
        msg_success "Configuracion valida"
        _recargar_servicio
    else
        msg_error "La configuracion generada tiene errores — revisa manualmente"
        sshd -t
        return 1
    fi
    echo ""
    msg_alert "IMPORTANTE: PasswordAuthentication se desactivo."
    msg_info  "Asegurate de tener al menos una clave SSH en authorized_keys antes de cerrar sesion."
    echo ""
}

# =============================================================================
# GESTION DE CLAVES
# =============================================================================

_home_usuario() {
    local user="$1"
    getent passwd "$user" | cut -d: -f6
}

_ssh_dir_usuario() {
    echo "$(_home_usuario "$1")/.ssh"
}

generar_clave_ssh() {
    separator
    echo -e "${WHITE}=== GENERAR PAR DE CLAVES SSH ===${NC}"
    separator
    echo ""

    # Usuario destino
    msg_input "Usuario destino [Enter = $SUDO_USER]: "
    read -r usuario
    [[ -z "$usuario" ]] && usuario="${SUDO_USER:-root}"

    if ! id "$usuario" &>/dev/null; then
        msg_error "El usuario '$usuario' no existe"
        return 1
    fi

    local ssh_dir
    ssh_dir=$(_ssh_dir_usuario "$usuario")

    # Tipo de clave
    echo ""
    echo -e "  ${GREEN}1.${NC} ed25519    (recomendado)"
    echo -e "  ${GREEN}2.${NC} rsa 4096"
    echo -e "  ${GREEN}3.${NC} ecdsa 521"
    echo ""
    msg_input "Tipo de clave [1]: "
    read -r tipo_num
    local tipo bits
    case "$tipo_num" in
        2) tipo="rsa";   bits="-b 4096" ;;
        3) tipo="ecdsa"; bits="-b 521"  ;;
        *) tipo="ed25519"; bits=""      ;;
    esac

    # Nombre del archivo
    echo ""
    local nombre_archivo="${ssh_dir}/id_${tipo}"
    msg_input "Ruta del archivo [Enter = $nombre_archivo]: "
    read -r ruta_custom
    [[ -n "$ruta_custom" ]] && nombre_archivo="$ruta_custom"

    if [[ -f "$nombre_archivo" ]]; then
        msg_alert "Ya existe una clave en $nombre_archivo"
        msg_input "Sobreescribir? (s/N): "
        read -r sobreescribir
        [[ ! "$sobreescribir" =~ ^[Ss]$ ]] && { msg_alert "Operacion cancelada"; return 0; }
    fi

    # Comentario
    echo ""
    msg_input "Comentario para la clave [Enter = ${usuario}@$(hostname)]: "
    read -r comentario
    [[ -z "$comentario" ]] && comentario="${usuario}@$(hostname)"

    # Passphrase
    echo ""
    msg_input "Passphrase (Enter para sin passphrase): "
    read -rs passphrase
    echo ""

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    # shellcheck disable=SC2086
    if ssh-keygen -t "$tipo" $bits -C "$comentario" -f "$nombre_archivo" \
            -N "$passphrase" &>/dev/null; then
        chown -R "${usuario}:${usuario}" "$ssh_dir"
        chmod 600 "${nombre_archivo}"
        chmod 644 "${nombre_archivo}.pub"
        msg_success "Par de claves generado:"
        echo -e "  ${CYAN}Privada:${NC}  $nombre_archivo"
        echo -e "  ${CYAN}Publica:${NC}  ${nombre_archivo}.pub"
        echo ""
        msg_info "Clave publica:"
        cat "${nombre_archivo}.pub"
        echo ""
    else
        msg_error "Error al generar las claves"
        return 1
    fi
}

agregar_clave_autorizada() {
    separator
    echo -e "${WHITE}=== AGREGAR CLAVE AUTORIZADA ===${NC}"
    separator
    echo ""

    msg_input "Usuario destino [Enter = $SUDO_USER]: "
    read -r usuario
    [[ -z "$usuario" ]] && usuario="${SUDO_USER:-root}"

    if ! id "$usuario" &>/dev/null; then
        msg_error "El usuario '$usuario' no existe"
        return 1
    fi

    local ssh_dir; ssh_dir=$(_ssh_dir_usuario "$usuario")
    local auth_keys="${ssh_dir}/authorized_keys"

    echo ""
    msg_info "Pega la clave publica (ssh-ed25519 / ssh-rsa / ...):"
    msg_input "> "
    read -r clave_publica

    if [[ -z "$clave_publica" ]]; then
        msg_error "No se ingreso ninguna clave"
        return 1
    fi

    # Validacion basica del formato
    local tipo_clave
    tipo_clave=$(echo "$clave_publica" | awk '{print $1}')
    case "$tipo_clave" in
        ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com)
            ;;
        *)
            msg_error "Formato de clave no reconocido: $tipo_clave"
            return 1
            ;;
    esac

    # Verificar duplicados
    if [[ -f "$auth_keys" ]] && grep -qF "$clave_publica" "$auth_keys"; then
        msg_alert "Esta clave ya existe en $auth_keys"
        return 0
    fi

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    echo "$clave_publica" >> "$auth_keys"
    chown -R "${usuario}:${usuario}" "$ssh_dir"
    chmod 600 "$auth_keys"

    msg_success "Clave agregada a $auth_keys"
    echo ""
}

listar_claves_autorizadas() {
    separator
    echo -e "${WHITE}=== CLAVES AUTORIZADAS ===${NC}"
    separator
    echo ""

    msg_input "Usuario [Enter = $SUDO_USER]: "
    read -r usuario
    [[ -z "$usuario" ]] && usuario="${SUDO_USER:-root}"

    local auth_keys
    auth_keys="$(_ssh_dir_usuario "$usuario")/authorized_keys"

    if [[ ! -f "$auth_keys" ]]; then
        msg_info "No hay claves autorizadas para '$usuario'"
        return 0
    fi

    local total
    total=$(grep -c "ssh-" "$auth_keys" 2>/dev/null || echo 0)
    msg_info "Claves autorizadas para '$usuario' ($total):"
    echo ""

    local i=1
    while IFS= read -r linea; do
        [[ -z "$linea" || "$linea" == \#* ]] && continue
        local tipo clave_b64 comentario_k
        tipo=$(echo "$linea" | awk '{print $1}')
        comentario_k=$(echo "$linea" | awk '{print $3}')
        echo -e "  ${CYAN}[$i]${NC} $tipo  ${comentario_k:-(sin comentario)}"
        i=$((i + 1))
    done < "$auth_keys"
    echo ""
}

eliminar_clave_autorizada() {
    separator
    echo -e "${WHITE}=== ELIMINAR CLAVE AUTORIZADA ===${NC}"
    separator
    echo ""

    msg_input "Usuario [Enter = $SUDO_USER]: "
    read -r usuario
    [[ -z "$usuario" ]] && usuario="${SUDO_USER:-root}"

    local auth_keys
    auth_keys="$(_ssh_dir_usuario "$usuario")/authorized_keys"

    if [[ ! -f "$auth_keys" ]]; then
        msg_info "No hay claves autorizadas para '$usuario'"
        return 0
    fi

    # Mostrar claves numeradas
    local claves=()
    while IFS= read -r linea; do
        [[ -z "$linea" || "$linea" == \#* ]] && continue
        claves+=("$linea")
    done < "$auth_keys"

    if [[ ${#claves[@]} -eq 0 ]]; then
        msg_info "No hay claves autorizadas para '$usuario'"
        return 0
    fi

    echo ""
    for i in "${!claves[@]}"; do
        local tipo_k comentario_k
        tipo_k=$(echo "${claves[$i]}" | awk '{print $1}')
        comentario_k=$(echo "${claves[$i]}" | awk '{print $3}')
        echo -e "  ${CYAN}[$((i+1))]${NC} $tipo_k  ${comentario_k:-(sin comentario)}"
    done
    echo ""

    local num
    msg_input "Numero de clave a eliminar [0 = cancelar]: "
    read -r num

    if [[ "$num" == "0" || -z "$num" ]]; then
        msg_alert "Operacion cancelada"; return 0
    fi

    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#claves[@]} ]; then
        msg_error "Numero invalido"; return 1
    fi

    local clave_a_eliminar="${claves[$((num-1))]}"

    # Escapar caracteres especiales para grep
    local tmp_file; tmp_file=$(mktemp)
    grep -vF "$clave_a_eliminar" "$auth_keys" > "$tmp_file"
    mv "$tmp_file" "$auth_keys"
    chown "${usuario}:${usuario}" "$auth_keys"
    chmod 600 "$auth_keys"

    msg_success "Clave eliminada"
    echo ""
}

menu_claves() {
    while true; do
        clear; separator; echo ""
        echo -e "${WHITE}--- GESTION DE CLAVES SSH ---${NC}"; echo ""
        echo -e "  ${GREEN}1.${NC} Generar par de claves"
        echo -e "  ${GREEN}2.${NC} Agregar clave autorizada"
        echo -e "  ${GREEN}3.${NC} Listar claves autorizadas"
        echo -e "  ${GREEN}4.${NC} Eliminar clave autorizada"
        echo -e "  ${GREEN}5.${NC} Volver"
        echo ""; separator; echo ""
        msg_input "Seleccione una opcion: "
        read -r op
        echo ""
        case "$op" in
            1) generar_clave_ssh ;;
            2) agregar_clave_autorizada ;;
            3) listar_claves_autorizadas ;;
            4) eliminar_clave_autorizada ;;
            5) return 0 ;;
            *) msg_error "Opcion invalida" ;;
        esac
        echo ""; read -rp "Presione ENTER para continuar..."
    done
}

# =============================================================================
# CONTROL DEL SERVICIO
# =============================================================================

_recargar_servicio() {
    msg_process "Validando configuracion..."
    if sshd -t &>/dev/null; then
        msg_success "Configuracion valida"
        msg_process "Recargando servicio $SSH_SERVICE..."
        if systemctl reload "$SSH_SERVICE" 2>/dev/null || systemctl restart "$SSH_SERVICE"; then
            msg_success "Servicio recargado correctamente"
        else
            msg_error "No se pudo recargar el servicio"
            return 1
        fi
    else
        msg_error "Configuracion invalida — no se recargara el servicio"
        sshd -t
        return 1
    fi
}

control_servicio() {
    local accion="$1"
    case "$accion" in
        start)
            msg_process "Iniciando $SSH_SERVICE..."
            systemctl start "$SSH_SERVICE" \
                && msg_success "Servicio iniciado" \
                || msg_error "No se pudo iniciar"
            ;;
        stop)
            msg_alert "Detener SSH desconectara sesiones activas."
            msg_input "Confirmar? (s/N): "
            read -r c; [[ ! "$c" =~ ^[Ss]$ ]] && { msg_alert "Cancelado"; return 0; }
            systemctl stop "$SSH_SERVICE" \
                && msg_success "Servicio detenido" \
                || msg_error "No se pudo detener"
            ;;
        restart)
            msg_process "Reiniciando $SSH_SERVICE..."
            systemctl restart "$SSH_SERVICE" \
                && msg_success "Servicio reiniciado" \
                || msg_error "No se pudo reiniciar"
            ;;
        enable)
            systemctl enable "$SSH_SERVICE" &>/dev/null \
                && msg_success "Servicio habilitado en el arranque" \
                || msg_error "No se pudo habilitar"
            ;;
        disable)
            msg_alert "Deshabilitar SSH impedira que arranque automaticamente."
            msg_input "Confirmar? (s/N): "
            read -r c; [[ ! "$c" =~ ^[Ss]$ ]] && { msg_alert "Cancelado"; return 0; }
            systemctl disable "$SSH_SERVICE" &>/dev/null \
                && msg_success "Servicio deshabilitado" \
                || msg_error "No se pudo deshabilitar"
            ;;
        reload)
            _recargar_servicio
            ;;
    esac
}

menu_servicio() {
    while true; do
        clear; separator; echo ""
        echo -e "${WHITE}--- CONTROL DEL SERVICIO SSH ---${NC}"; echo ""
        local estado color_estado
        if systemctl is-active --quiet "$SSH_SERVICE"; then
            estado="ACTIVO"; color_estado=$GREEN
        else
            estado="INACTIVO"; color_estado=$RED
        fi
        local arrq_estado
        systemctl is-enabled --quiet "$SSH_SERVICE" 2>/dev/null \
            && arrq_estado="${GREEN}habilitado${NC}" \
            || arrq_estado="${RED}deshabilitado${NC}"
        echo -e "  Estado actual: ${color_estado}${estado}${NC} | Arranque: ${arrq_estado}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Iniciar"
        echo -e "  ${GREEN}2.${NC} Detener"
        echo -e "  ${GREEN}3.${NC} Reiniciar"
        echo -e "  ${GREEN}4.${NC} Recargar configuracion"
        echo -e "  ${GREEN}5.${NC} Habilitar en arranque"
        echo -e "  ${GREEN}6.${NC} Deshabilitar en arranque"
        echo -e "  ${GREEN}7.${NC} Volver"
        echo ""; separator; echo ""
        msg_input "Seleccione una opcion: "
        read -r op
        echo ""
        case "$op" in
            1) control_servicio start   ;;
            2) control_servicio stop    ;;
            3) control_servicio restart ;;
            4) control_servicio reload  ;;
            5) control_servicio enable  ;;
            6) control_servicio disable ;;
            7) return 0 ;;
            *) msg_error "Opcion invalida" ;;
        esac
        echo ""; read -rp "Presione ENTER para continuar..."
    done
}

# =============================================================================
# MONITOR
# =============================================================================

monitorear_ssh() {
    clear; separator; echo ""
    echo -e "${WHITE}--- MONITOR SSH ---${NC}"; echo ""

    # Estado del servicio
    sleep 1
    echo -e "${WHITE}Estado del servicio:${NC}"; echo ""
    if systemctl is-active --quiet "$SSH_SERVICE"; then
        local uptime pid
        uptime=$(systemctl show "$SSH_SERVICE" --property=ActiveEnterTimestamp --value)
        pid=$(systemctl show "$SSH_SERVICE" --property=MainPID --value)
        echo -e "  Estado:    ${GREEN}ACTIVO${NC}"
        echo -e "  Inicio:    $(echo "$uptime" | awk '{print $2, $3}')"
        echo -e "  PID:       $pid"
        local puerto_activo
        puerto_activo=$(ss -tlnp 2>/dev/null | grep "sshd" | awk '{print $4}' | grep -oP ':\K[0-9]+' | head -1)
        [[ -n "$puerto_activo" ]] && echo -e "  Puerto:    $puerto_activo"
    else
        echo -e "  Estado:    ${RED}INACTIVO${NC}"
        echo ""
        msg_alert "El servicio SSH no esta corriendo"
        echo ""; separator; return 1
    fi

    # Conexiones activas
    sleep 1; echo ""
    echo -e "${WHITE}Conexiones SSH activas:${NC}"; echo ""
    local conexiones
    conexiones=$(ss -tnp 2>/dev/null | grep -E ':22|sshd' | grep ESTAB)
    if [[ -n "$conexiones" ]]; then
        local total_conn
        total_conn=$(echo "$conexiones" | wc -l)
        msg_info "Conexiones establecidas: $total_conn"
        echo ""
        echo "$conexiones" | awk '{
            split($4, local, ":")
            split($5, remote, ":")
            printf "  Local: %-22s  Remoto: %s\n", $4, $5
        }'
    else
        msg_info "Sin conexiones activas"
    fi

    # Sesiones activas (w)
    sleep 1; echo ""
    echo -e "${WHITE}Sesiones de usuario activas:${NC}"; echo ""
    local sesiones_ssh
    sesiones_ssh=$(w -h 2>/dev/null | grep -i "ssh\|pts" || true)
    if [[ -n "$sesiones_ssh" ]]; then
        echo "$sesiones_ssh" | while read -r linea; do
            echo "  $linea"
        done
    else
        msg_info "Sin sesiones SSH detectadas por w"
    fi

    # Ultimos accesos
    sleep 1; echo ""
    echo -e "${WHITE}Ultimos 10 accesos (last):${NC}"; echo ""
    last -n 10 2>/dev/null | grep -v "^$\|^wtmp" | while read -r linea; do
        if echo "$linea" | grep -qiE "still logged|still running"; then
            echo -e "  ${GREEN}$linea${NC}"
        elif echo "$linea" | grep -qi "gone\|down\|crash"; then
            echo -e "  ${RED}$linea${NC}"
        else
            echo "  $linea"
        fi
    done

    # Intentos fallidos recientes
    sleep 1; echo ""
    echo -e "${WHITE}Intentos de acceso fallidos (ultimas 24h):${NC}"; echo ""
    local fallos
    fallos=$(journalctl -u "$SSH_SERVICE" --since "24h ago" --no-pager 2>/dev/null \
        | grep -iE "failed|invalid|error" | wc -l)
    if [[ "$fallos" -gt 0 ]]; then
        echo -e "  ${RED}$fallos intentos fallidos en las ultimas 24h${NC}"
        echo ""
        msg_info "Top IPs con fallos:"
        journalctl -u "$SSH_SERVICE" --since "24h ago" --no-pager 2>/dev/null \
            | grep -oP 'from \K[\d.]+' \
            | sort | uniq -c | sort -rn \
            | head -5 \
            | while read -r count ip; do
                echo -e "    ${YELLOW}$count${NC} intentos desde $ip"
            done
    else
        msg_success "Sin intentos fallidos en las ultimas 24h"
    fi

    # Logs recientes
    sleep 1; echo ""
    separator
    echo -e "${WHITE}Actividad reciente (ultimas 20 entradas):${NC}"; echo ""
    journalctl -u "$SSH_SERVICE" -n 20 --no-pager 2>/dev/null \
        | while read -r linea; do
            if echo "$linea" | grep -qi "accepted\|opened"; then
                echo -e "  ${GREEN}$linea${NC}"
            elif echo "$linea" | grep -qi "failed\|invalid\|error\|disconnect"; then
                echo -e "  ${RED}$linea${NC}"
            else
                echo "  $linea"
            fi
        done

    echo ""; separator; echo ""
}

# =============================================================================
# VER Y RECONFIGURAR CONFIGURACION ACTUAL
# =============================================================================

ver_configuracion() {
    clear; separator; echo ""
    echo -e "${WHITE}--- CONFIGURACION SSH ACTUAL ---${NC}"; echo ""

    if [[ ! -f "$SSHD_CONFIG" ]]; then
        msg_error "No se encuentra $SSHD_CONFIG"
        return 1
    fi

    sleep 1
    echo -e "${WHITE}Directivas activas en $SSHD_CONFIG:${NC}"; echo ""

    local directivas=(
        "Port" "ListenAddress" "Protocol"
        "PermitRootLogin" "PasswordAuthentication" "PubkeyAuthentication"
        "PermitEmptyPasswords" "ChallengeResponseAuthentication"
        "MaxAuthTries" "MaxSessions" "LoginGraceTime"
        "ClientAliveInterval" "ClientAliveCountMax"
        "X11Forwarding" "AllowTcpForwarding" "AllowAgentForwarding"
        "Banner" "LogLevel" "SyslogFacility"
        "UsePAM"
    )

    for d in "${directivas[@]}"; do
        local val
        val=$(_leer_directiva "$d")
        if [[ -n "$val" ]]; then
            printf "  ${CYAN}%-32s${NC} %s\n" "$d" "$val"
        fi
    done

    # Mostrar hardening conf si existe
    if [[ -f "$SSHD_HARDENING_CONF" ]]; then
        echo ""
        echo -e "${WHITE}Perfil de hardening activo ($SSHD_HARDENING_CONF):${NC}"; echo ""
        grep -v "^#\|^$" "$SSHD_HARDENING_CONF" | while read -r linea; do
            echo -e "  ${MAGENTA}$linea${NC}"
        done
    fi

    echo ""
    separator; echo ""
    msg_input "Desea reconfigurar SSH ahora? (s/N): "
    read -r resp
    [[ "$resp" =~ ^[Ss]$ ]] && configurar_ssh
}

# =============================================================================
# AYUDA
# =============================================================================

show_help() {
    cat <<EOF

SSH Manager - OpenSSH Server (Fedora Server 43)

USO INTERACTIVO:
  sudo ./ssh_manager.sh

USO POR PARAMETROS:
  sudo ./ssh_manager.sh [COMANDO] [OPCIONES]

COMANDOS:
  install                        Instala/verifica openssh-server (idempotente)
  configure                      Configura sshd de forma interactiva
  harden                         Aplica perfil de hardening recomendado
  firewall [--port P] [--iface I] Configura firewall para SSH
  status                         Monitor: estado, conexiones, logs
  show                           Muestra configuracion actual
  keys                           Menu de gestion de claves
  start | stop | restart         Control del servicio
  reload                         Recarga configuracion sin desconectar
  enable | disable               Habilita/deshabilita en el arranque
  menu                           Abre el menu interactivo (por defecto)

  -h, --help                     Muestra esta ayuda

EJEMPLOS:
  sudo ./ssh_manager.sh install
  sudo ./ssh_manager.sh configure
  sudo ./ssh_manager.sh harden
  sudo ./ssh_manager.sh firewall --port 2222 --iface eth0
  sudo ./ssh_manager.sh status
  sudo ./ssh_manager.sh restart
EOF
}

# =============================================================================
# MENU PRINCIPAL
# =============================================================================

menu() {
    while true; do
        clear; sleep 1; separator; echo ""
        echo -e "${WHITE}--- SSH MANAGER ---${NC}"; echo ""

        local estado color_e
        systemctl is-active --quiet "$SSH_SERVICE" \
            && { estado="ACTIVO"; color_e=$GREEN; } \
            || { estado="INACTIVO"; color_e=$RED; }

        echo -e "  Servicio: ${color_e}${estado}${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC}  Instalar/verificar OpenSSH Server"
        echo -e "  ${GREEN}2.${NC}  Configurar SSH"
        echo -e "  ${GREEN}3.${NC}  Aplicar Hardening"
        echo -e "  ${GREEN}4.${NC}  Configurar Firewall"
        echo -e "  ${GREEN}5.${NC}  Gestion de Claves"
        echo -e "  ${GREEN}6.${NC}  Monitor / Estado"
        echo -e "  ${GREEN}7.${NC}  Ver y reconfigurar configuracion actual"
        echo -e "  ${GREEN}8.${NC}  Control del servicio"
        echo -e "  ${GREEN}9.${NC}  Salir"
        echo ""; separator; echo ""
        msg_input "Seleccione una opcion: "
        read -r opcion
        sleep 1

        case "$opcion" in
            1) instalar_ssh ;;
            2) configurar_ssh ;;
            3) aplicar_hardening ;;
            4)
                echo ""
                msg_process "Interfaces disponibles:"; echo ""
                list_network_interfaces; echo ""
                msg_input "Interfaz [Enter = zona por defecto]: "
                read -r iface_fw
                msg_input "Puerto [Enter = 22]: "
                read -r port_fw
                configurar_firewall_ssh "${port_fw:-22}" "$iface_fw"
                ;;
            5) menu_claves ;;
            6) monitorear_ssh ;;
            7) ver_configuracion ;;
            8) menu_servicio ;;
            9) msg_info "Saliendo..."; sleep 1; exit 0 ;;
            *) msg_error "Opcion invalida" ;;
        esac

        echo ""; read -rp "Presione ENTER para continuar..."
    done
}

# =============================================================================
# ROUTER DE COMANDOS
# =============================================================================

main() {
    _check_root

    [[ $# -eq 0 ]] && { menu; return; }

    local command="$1"; shift

    case "$command" in
        -h|--help) show_help ;;

        install)   instalar_ssh ;;
        configure) configurar_ssh ;;
        harden)    aplicar_hardening ;;

        firewall)
            local port=22 iface=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)  port="$2";  shift 2 ;;
                    --iface) iface="$2"; shift 2 ;;
                    *) msg_error "Opcion desconocida: $1"; exit 1 ;;
                esac
            done
            configurar_firewall_ssh "$port" "$iface"
            ;;

        status)  monitorear_ssh ;;
        show)    ver_configuracion ;;
        keys)    menu_claves ;;

        start)   control_servicio start   ;;
        stop)    control_servicio stop    ;;
        restart) control_servicio restart ;;
        reload)  control_servicio reload  ;;
        enable)  control_servicio enable  ;;
        disable) control_servicio disable ;;

        menu) menu ;;

        *)
            msg_error "Comando desconocido: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"