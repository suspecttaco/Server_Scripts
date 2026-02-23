#!/bin/bash
# =============================================================================
# dns_manager.sh — Gestor de servidor DNS BIND9 (Fedora Server 43)
#
# Uso: sudo ./dns_manager.sh [COMANDO] [-o|--override] [OPCIONES]
# Usa: lib/ui.sh, lib/net.sh, lib/iface.sh
# =============================================================================

set -euo pipefail

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

readonly SCRIPT_VERSION="2.2.0"
readonly BIND_CONFIG="/etc/named.conf"
readonly BIND_ZONES_DIR="/var/named"
readonly SYSTEMD_SERVICE="named"

readonly BLACKLIST_DOMAINS=(
    "localhost" "local" "invalid" "test"
    "example.com" "example.net" "example.org" "example.edu"
)

readonly BLACKLIST_IPS=(
    "0.0.0.0" "255.255.255.255" "127.0.0.1" "127.0.0.53"
)

readonly DEFAULT_TTL=604800
readonly DEFAULT_REFRESH=604800
readonly DEFAULT_RETRY=86400
readonly DEFAULT_EXPIRE=2419200
readonly DEFAULT_NEGATIVE_CACHE=604800

OVERRIDE_MODE=false

# =============================================================================
# VALIDACIONES DNS
# =============================================================================

is_blacklisted_domain() {
    [[ "$OVERRIDE_MODE" == true ]] && return 1
    local domain="$1"
    for b in "${BLACKLIST_DOMAINS[@]}"; do
        [[ "$domain" == "$b" || "$domain" == *."$b" ]] && return 0
    done
    return 1
}

is_blacklisted_ip() {
    [[ "$OVERRIDE_MODE" == true ]] && return 1
    local ip="$1"
    for b in "${BLACKLIST_IPS[@]}"; do
        [[ "$ip" == "$b" ]] && return 0
    done
    local first_octet
    first_octet=$(echo "$ip" | cut -d'.' -f1)
    [[ "$first_octet" -ge 224 && "$first_octet" -le 239 ]] && return 0
    [[ "$first_octet" == 127 ]] && return 0
    return 1
}

validate_ip_dns() {
    local ip="$1"
    [[ "$OVERRIDE_MODE" == true ]] && return 0
    validar_ip "$ip" || return 1
    is_blacklisted_ip "$ip" && return 1
    return 0
}

validate_ip_cidr_dns() {
    local ip_cidr="$1"
    [[ "$OVERRIDE_MODE" == true ]] && return 0
    validar_ip_cidr "$ip_cidr" || return 1
    is_blacklisted_ip "$(extract_ip_from_cidr "$ip_cidr")" && return 1
    return 0
}

validate_ip_or_cidr_dns() {
    [[ "$1" =~ / ]] && validate_ip_cidr_dns "$1" || validate_ip_dns "$1"
}

validate_domain() {
    local domain="$1"
    [[ "$OVERRIDE_MODE" == true ]] && return 0
    local regex='^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    [[ $domain =~ $regex ]] || return 1
    is_blacklisted_domain "$domain" && return 1
    return 0
}

validate_hostname() {
    local hostname="$1"
    [[ "$OVERRIDE_MODE" == true ]] && return 0
    [[ $hostname =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]]
}

# =============================================================================
# UTILIDADES DE ZONA INVERSA
# =============================================================================

get_reverse_zone_from_ip() {
    local ip="$1"
    local octets
    IFS='.' read -ra octets <<< "$ip"
    echo "${octets[2]}.${octets[1]}.${octets[0]}.in-addr.arpa"
}

get_reverse_ptr_name() {
    local ip="$1"
    local octets
    IFS='.' read -ra octets <<< "$ip"
    echo "${octets[3]}"
}

get_zone_file_path()         { echo "${BIND_ZONES_DIR}/db.${1}"; }
get_reverse_zone_file_path() { echo "${BIND_ZONES_DIR}/db.${1}"; }

# =============================================================================
# IP ESTATICA — INTERACCION
# =============================================================================

prompt_interface_selection() {
    list_network_interfaces >&2
    local interface
    while true; do
        read -rp "Seleccione la interfaz para el servidor DNS: " interface >&2
        check_interface_exists "$interface" && { echo "$interface"; return 0; }
        msg_error "Interfaz invalida: $interface"
    done
}

prompt_dns_ip_selection() {
    local interface="$1"
    local current_ip_cidr
    current_ip_cidr=$(get_interface_ip_cidr "$interface")

    if [[ -n "$current_ip_cidr" ]]; then
        echo "IP/CIDR actual de $interface: $current_ip_cidr" >&2
        read -rp "¿Desea usar esta IP para el servidor DNS? (s/n): " response >&2
        [[ "$response" =~ ^[sS]$ ]] && { echo "$current_ip_cidr"; return 0; }
    fi

    local new_ip
    while true; do
        read -rp "Ingrese la IP para el servidor DNS (ej: 192.168.1.10/24): " new_ip >&2
        validate_ip_or_cidr_dns "$new_ip" && { echo "$new_ip"; return 0; }
        msg_error "IP invalida (formato: IP o IP/CIDR)"
    done
}

ensure_static_ip() {
    local interface="$1" dns_ip_input="$2"
    local dns_ip dns_ip_cidr

    if [[ "$dns_ip_input" =~ / ]]; then
        dns_ip=$(extract_ip_from_cidr "$dns_ip_input")
        dns_ip_cidr="$dns_ip_input"
    else
        dns_ip="$dns_ip_input"
        dns_ip_cidr=""
    fi

    local current_ip current_ip_cidr
    current_ip=$(get_interface_ip "$interface")
    current_ip_cidr=$(get_interface_ip_cidr "$interface")

    if [[ "$dns_ip" != "$current_ip" ]]; then
        msg_info "La IP del DNS ($dns_ip) es diferente a la IP actual ($current_ip)"

        if [[ -z "$dns_ip_cidr" ]]; then
            local cidr
            while true; do
                read -rp "Ingrese CIDR para $dns_ip (ej: 24): " cidr >&2
                [[ "$cidr" =~ ^[0-9]+$ ]] && [ "$cidr" -ge 1 ] && [ "$cidr" -le 32 ] && {
                    dns_ip_cidr="$dns_ip/$cidr"; break
                }
                msg_error "CIDR invalido"
            done
        fi

        local dns
        while true; do
            read -rp "DNS primario: " dns >&2
            validate_ip_dns "$dns" && break
            msg_error "DNS invalida"
        done

        configure_static_ip "$interface" "$dns_ip_cidr" "$dns" || return 1
        return 0
    fi

    if check_static_ip "$interface"; then
        msg_success "La interfaz $interface ya tiene IP estatica configurada"
        read -rp "¿Desea configurar/cambiar el DNS? (s/n): " response >&2

        if [[ "$response" =~ ^[sS]$ ]]; then
            local dns
            while true; do
                read -rp "DNS primario: " dns >&2
                validate_ip_dns "$dns" && break
                msg_error "DNS invalida"
            done
            configure_static_ip "$interface" "${dns_ip_cidr:-$current_ip_cidr}" "$dns" || return 1
        fi
        return 0
    fi

    msg_info "La interfaz $interface no tiene IP estatica configurada"
    read -rp "¿Desea configurar IP estatica? (s/n): " response >&2
    [[ ! "$response" =~ ^[sS]$ ]] && { msg_info "Continuando sin configurar IP estatica"; return 0; }

    local ip_cidr dns
    read -rp "IP/CIDR (actual: $current_ip_cidr, Enter para usar actual): " ip_cidr >&2
    [[ -z "$ip_cidr" ]] && ip_cidr="$current_ip_cidr"

    validate_ip_cidr_dns "$ip_cidr" || { msg_error "IP/CIDR invalida"; return 1; }

    while true; do
        read -rp "DNS primario: " dns >&2
        validate_ip_dns "$dns" && break
        msg_error "DNS invalida"
    done

    configure_static_ip "$interface" "$ip_cidr" "$dns"
}

# =============================================================================
# INSTALACION Y CONFIGURACION DE BIND9
# =============================================================================

check_bind_installed() { rpm -q bind &>/dev/null; }
check_bind_running()   { systemctl is-active --quiet "$SYSTEMD_SERVICE"; }

install_bind() {
    if check_bind_installed; then
        msg_info "BIND9 ya esta instalado"
        return 0
    fi
    msg_info "Instalando BIND9..."
    dnf install -y bind bind-utils &>/dev/null || { msg_error "Error al instalar BIND9"; return 1; }
    msg_success "BIND9 instalado correctamente"
}

fix_selinux_permissions() {
    msg_info "Configurando permisos SELinux..."
    check_dependency restorecon || { msg_error "restorecon no disponible"; return 1; }

    restorecon -rv /etc/named* &>/dev/null || true
    restorecon -rv /var/named  &>/dev/null || true

    if check_dependency semanage; then
        semanage fcontext -a -t named_zone_t "/var/named/db\\..*" &>/dev/null || true
        semanage fcontext -a -t named_conf_t "/etc/named/zones\\.conf" &>/dev/null || true
        restorecon -v /var/named/db.* /etc/named/zones.conf &>/dev/null || true
    fi

    msg_success "Permisos SELinux configurados"
}

configure_named_conf() {
    local listen_ip="$1"

    [[ ! -f "${BIND_CONFIG}.bak" ]] && cp "$BIND_CONFIG" "${BIND_CONFIG}.bak"

cat > "$BIND_CONFIG" <<'EOFCONFIG'
options {
    listen-on port 53 { 127.0.0.1; LISTEN_IP_PLACEHOLDER; };
    listen-on-v6 port 53 { ::1; };
    directory "/var/named";
    dump-file "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    secroots-file "/var/named/data/named.secroots";
    recursing-file "/var/named/data/named.recursing";
    allow-query { localhost; any; };
    recursion yes;
    dnssec-validation yes;
    managed-keys-directory "/var/named/dynamic";
    geoip-directory "/usr/share/GeoIP";
    pid-file "/run/named/named.pid";
    session-keyfile "/run/named/session.key";
    include "/etc/crypto-policies/back-ends/bind.config";
};

logging {
    channel default_debug {
        file "data/named.run";
        severity dynamic;
    };
};

zone "." IN {
    type hint;
    file "named.ca";
};

include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";
include "/etc/named/zones.conf";
EOFCONFIG

    sed -i "s/LISTEN_IP_PLACEHOLDER/${listen_ip}/g" "$BIND_CONFIG"

    mkdir -p /etc/named
    touch /etc/named/zones.conf

    chown root:named "$BIND_CONFIG" /etc/named/zones.conf
    chmod 640 "$BIND_CONFIG" /etc/named/zones.conf

    msg_success "named.conf configurado con IP: $listen_ip"
}

configure_firewall_dns() {
    local interface="$1"
    check_dependency firewall-cmd || { msg_info "firewalld no disponible"; return 0; }
    systemctl is-active --quiet firewalld || { msg_info "firewalld no activo"; return 0; }

    local zone
    zone=$(get_interface_firewall_zone "$interface")
    msg_info "Zona de firewall detectada: $zone"

    firewall-cmd --zone="$zone" --permanent --add-service=dns  &>/dev/null || true
    firewall-cmd --zone="$zone" --permanent --add-port=53/tcp  &>/dev/null || true
    firewall-cmd --zone="$zone" --permanent --add-port=53/udp  &>/dev/null || true
    firewall-cmd --reload &>/dev/null || true

    msg_success "Firewall configurado en zona $zone"
}

start_bind_service() {
    local interface="$1"
    fix_selinux_permissions
    configure_firewall_dns "$interface"
    systemctl enable "$SYSTEMD_SERVICE" &>/dev/null
    systemctl restart "$SYSTEMD_SERVICE" || {
        msg_error "Error al iniciar BIND9. Ejecute: sudo journalctl -xeu named.service"
        return 1
    }
    msg_success "Servicio BIND9 iniciado"
}

# =============================================================================
# GESTION DE ZONAS DNS
# =============================================================================

zone_exists() {
    grep -q "zone \"${1}\"" /etc/named/zones.conf 2>/dev/null
}

_write_zone_perms() {
    local file="$1"
    chown root:named "$file" /etc/named/zones.conf
    chmod 640 "$file" /etc/named/zones.conf
    check_dependency restorecon && {
        restorecon -v "$file" /etc/named/zones.conf &>/dev/null || true
    }
}

_check_bind_zone() {
    local zone="$1" file="$2"
    [[ "$OVERRIDE_MODE" == true ]] && return 0
    named-checkconf || {
        msg_error "Error en la configuracion de BIND"
        rm -f "$file"
        sed -i "/zone \"${zone}\"/,/^$/d" /etc/named/zones.conf
        return 1
    }
    named-checkzone "$zone" "$file" &>/dev/null || {
        msg_error "Error en el archivo de zona"
        rm -f "$file"
        sed -i "/zone \"${zone}\"/,/^$/d" /etc/named/zones.conf
        return 1
    }
}

create_zone() {
    local domain="$1" ip="$2"
    local ttl="${3:-$DEFAULT_TTL}" refresh="${4:-$DEFAULT_REFRESH}"
    local retry="${5:-$DEFAULT_RETRY}" expire="${6:-$DEFAULT_EXPIRE}"
    local negative="${7:-$DEFAULT_NEGATIVE_CACHE}"
    local serial; serial=$(date +%Y%m%d%H)

    validate_domain "$domain" || { msg_error "Dominio invalido o en blacklist: $domain"; return 1; }
    validate_ip_dns "$ip"     || { msg_error "IP invalida o en blacklist: $ip";          return 1; }
    zone_exists "$domain"     && { msg_error "La zona $domain ya existe";                return 1; }

    local zone_file; zone_file=$(get_zone_file_path "$domain")

    cat >> /etc/named/zones.conf <<EOF
zone "${domain}" {
    type master;
    file "${zone_file}";
    allow-update { none; };
};

EOF

    cat > "$zone_file" <<EOF
\$TTL    ${ttl}
@       IN      SOA     ns.${domain}. admin.${domain}. (
                        ${serial}       ; Serial
                        ${refresh}      ; Refresh
                        ${retry}        ; Retry
                        ${expire}       ; Expire
                        ${negative} )   ; Negative Cache TTL
;
@       IN      NS      ns.${domain}.
@       IN      A       ${ip}
ns      IN      A       ${ip}
www     IN      A       ${ip}
EOF

    _write_zone_perms "$zone_file"
    _check_bind_zone "$domain" "$zone_file" || return 1

    systemctl reload "$SYSTEMD_SERVICE" || { msg_error "Error al recargar BIND"; return 1; }
    msg_success "Zona $domain creada correctamente"
}

create_reverse_zone() {
    local ip="$1" domain="$2"
    local ttl="${3:-$DEFAULT_TTL}" refresh="${4:-$DEFAULT_REFRESH}"
    local retry="${5:-$DEFAULT_RETRY}" expire="${6:-$DEFAULT_EXPIRE}"
    local negative="${7:-$DEFAULT_NEGATIVE_CACHE}"
    local serial; serial=$(date +%Y%m%d%H)

    validate_ip_dns "$ip" || { msg_error "IP invalida o en blacklist: $ip"; return 1; }

    local reverse_zone ptr_name
    reverse_zone=$(get_reverse_zone_from_ip "$ip")
    ptr_name=$(get_reverse_ptr_name "$ip")

    if zone_exists "$reverse_zone"; then
        msg_info "Zona inversa $reverse_zone ya existe, añadiendo PTR"
        local zone_file; zone_file=$(get_reverse_zone_file_path "$reverse_zone")

        grep -q "^${ptr_name}[[:space:]]" "$zone_file" && {
            msg_error "El registro PTR para $ip ya existe"; return 1
        }

        echo "${ptr_name}    IN      PTR     ${domain}." >> "$zone_file"
        sed -i "s/[0-9]\{10\}.*; Serial/${serial}       ; Serial/" "$zone_file"
        _write_zone_perms "$zone_file"
        [[ "$OVERRIDE_MODE" != true ]] && ! named-checkzone "$reverse_zone" "$zone_file" &>/dev/null && {
            msg_error "Error en el archivo de zona inversa"; return 1
        }
        systemctl reload "$SYSTEMD_SERVICE" || { msg_error "Error al recargar BIND"; return 1; }
        msg_success "Registro PTR añadido a zona inversa existente"
        return 0
    fi

    local zone_file; zone_file=$(get_reverse_zone_file_path "$reverse_zone")

    cat >> /etc/named/zones.conf <<EOF
zone "${reverse_zone}" {
    type master;
    file "${zone_file}";
    allow-update { none; };
};

EOF

    cat > "$zone_file" <<EOF
\$TTL    ${ttl}
@       IN      SOA     ns.${domain}. admin.${domain}. (
                        ${serial}       ; Serial
                        ${refresh}      ; Refresh
                        ${retry}        ; Retry
                        ${expire}       ; Expire
                        ${negative} )   ; Negative Cache TTL
;
@       IN      NS      ns.${domain}.
${ptr_name}    IN      PTR     ${domain}.
EOF

    _write_zone_perms "$zone_file"
    _check_bind_zone "$reverse_zone" "$zone_file" || return 1

    systemctl reload "$SYSTEMD_SERVICE" || { msg_error "Error al recargar BIND"; return 1; }
    msg_success "Zona inversa $reverse_zone creada correctamente"
}

list_zones() {
    [[ ! -f /etc/named/zones.conf ]] && { msg_info "No hay zonas configuradas"; return 0; }
    msg_info "Zonas DNS configuradas:"
    grep "^zone" /etc/named/zones.conf | awk '{print $2}' | tr -d '"' | while read -r zone; do
        echo "  - $zone"
    done
}

show_zone() {
    local domain="$1"
    validate_domain "$domain" || { msg_error "Dominio invalido: $domain"; return 1; }
    zone_exists "$domain"     || { msg_error "La zona $domain no existe"; return 1; }
    msg_info "Contenido de la zona $domain:"
    cat "$(get_zone_file_path "$domain")"
}

delete_zone() {
    local domain="$1"
    validate_domain "$domain" || { msg_error "Dominio invalido: $domain"; return 1; }
    zone_exists "$domain"     || { msg_error "La zona $domain no existe"; return 1; }

    local zone_file; zone_file=$(get_zone_file_path "$domain")
    sed -i "/zone \"${domain}\"/,/^$/d" /etc/named/zones.conf
    rm -f "$zone_file"

    systemctl reload "$SYSTEMD_SERVICE" || { msg_error "Error al recargar BIND"; return 1; }
    msg_success "Zona $domain eliminada"
}

add_record() {
    local domain="$1" hostname="$2" type="$3" value="$4"
    local serial; serial=$(date +%Y%m%d%H)

    validate_domain   "$domain"   || { msg_error "Dominio invalido: $domain";   return 1; }
    validate_hostname "$hostname" || { msg_error "Hostname invalido: $hostname"; return 1; }
    zone_exists "$domain"         || { msg_error "La zona $domain no existe";   return 1; }

    local zone_file; zone_file=$(get_zone_file_path "$domain")

    case "$type" in
        A)
            validate_ip_dns "$value" || { msg_error "IP invalida: $value"; return 1; }
            echo "${hostname}      IN      A       ${value}" >> "$zone_file"
            ;;
        CNAME)
            if [[ "$OVERRIDE_MODE" != true ]]; then
                validate_domain "$value" || validate_hostname "$value" || {
                    msg_error "Valor CNAME invalido: $value"; return 1
                }
            fi
            echo "${hostname}      IN      CNAME   ${value}." >> "$zone_file"
            ;;
        *)
            msg_error "Tipo de registro no soportado: $type"; return 1
            ;;
    esac

    sed -i "s/[0-9]\{10\}.*; Serial/${serial}       ; Serial/" "$zone_file"
    _write_zone_perms "$zone_file"

    [[ "$OVERRIDE_MODE" != true ]] && ! named-checkzone "$domain" "$zone_file" &>/dev/null && {
        msg_error "Error en el archivo de zona"; return 1
    }

    systemctl reload "$SYSTEMD_SERVICE" || { msg_error "Error al recargar BIND"; return 1; }
    msg_success "Registro $hostname ($type) añadido a $domain"
}

# =============================================================================
# LOGS Y ESTADO
# =============================================================================

show_logs()        { msg_info "Ultimas ${1:-50} lineas:"; journalctl -u named.service -n "${1:-50}" --no-pager; }
show_logs_follow() { msg_info "Logs en tiempo real (Ctrl+C para salir):"; journalctl -u named.service -f; }
show_logs_errors() { msg_info "Solo errores:"; journalctl -u named.service -p err --no-pager; }

# =============================================================================
# PRUEBAS Y VALIDACION
# =============================================================================

test_resolution() {
    local domain="$1"
    validate_domain "$domain" || { msg_error "Dominio invalido: $domain"; return 1; }
    check_dependency dig       || { msg_error "dig no disponible";         return 1; }
    msg_info "Probando resolucion de $domain..."
    local result; result=$(dig @127.0.0.1 "$domain" +short)
    [[ -n "$result" ]] && { msg_success "Resolucion exitosa: $domain -> $result"; return 0; }
    msg_error "No se pudo resolver $domain"; return 1
}

test_www_resolution() {
    local domain="$1"
    validate_domain "$domain" || { msg_error "Dominio invalido: $domain"; return 1; }
    msg_info "Probando resolucion de www.$domain..."
    local result; result=$(dig @127.0.0.1 "www.$domain" +short)
    [[ -n "$result" ]] && { msg_success "Resolucion exitosa: www.$domain -> $result"; return 0; }
    msg_error "No se pudo resolver www.$domain"; return 1
}

test_reverse_resolution() {
    local ip="$1"
    validate_ip_dns "$ip" || { msg_error "IP invalida: $ip"; return 1; }
    check_dependency dig   || { msg_error "dig no disponible"; return 1; }
    msg_info "Probando resolucion inversa de $ip..."
    local result; result=$(dig @127.0.0.1 -x "$ip" +short)
    [[ -n "$result" ]] && { msg_success "Resolucion inversa exitosa: $ip -> $result"; return 0; }
    msg_error "No se pudo resolver inversamente $ip"; return 1
}

validate_bind_config() {
    msg_info "Validando configuracion de BIND..."
    named-checkconf && { msg_success "Configuracion valida"; return 0; }
    msg_error "Configuracion invalida"; return 1
}

check_bind_status() {
    if check_bind_running; then
        msg_success "BIND9 esta en ejecucion"
        systemctl status "$SYSTEMD_SERVICE" --no-pager
    else
        msg_error "BIND9 no esta en ejecucion"; return 1
    fi
}

# =============================================================================
# AYUDA
# =============================================================================

show_help() {
    cat <<EOF
DNS Server Manager v${SCRIPT_VERSION} - Fedora Server 43

USO: $0 [COMANDO] [-o|--override] [OPCIONES]

INSTALACION:
  install --interface IFACE [--ip IP[/CIDR]]

IP ESTATICA:
  list-interfaces
  check-static-ip --interface IFACE
  set-static-ip   --interface IFACE --ip IP/CIDR --dns DNS

ZONAS:
  create-zone         --domain DOM --ip IP [--ttl T] [--refresh R] [--retry R] [--expire E] [--negative N]
  create-reverse-zone --ip IP --domain DOM [opciones SOA]
  list-zones
  show-zone           --domain DOM
  delete-zone         --domain DOM

REGISTROS:
  add-record --domain DOM --hostname HOST --type A|CNAME --value VAL

LOGS:
  logs [--lines N]     logs-follow     logs-errors

VALIDACION:
  validate     test --domain DOM     test-reverse --ip IP     status

FLAGS:
  -o, --override    Omite validaciones y blacklist
  -h, --help        Muestra esta ayuda

VALORES SOA POR DEFECTO:
  TTL/Refresh/Negative: ${DEFAULT_TTL}s (7d) | Retry: ${DEFAULT_RETRY}s (1d) | Expire: ${DEFAULT_EXPIRE}s (28d)
EOF
}

# =============================================================================
# ROUTER PRINCIPAL
# =============================================================================

main() {
    [[ $# -eq 0 ]] && { show_help; exit 0; }

    [[ $EUID -ne 0 ]] && { msg_error "Este script requiere privilegios root"; exit 1; }

    local command="$1"; shift

    if [[ "$command" == "-o" || "$command" == "--override" ]]; then
        OVERRIDE_MODE=true
        [[ $# -eq 0 ]] && { show_help; exit 0; }
        command="$1"; shift
    fi

    case "$command" in
        -h|--help) show_help ;;

        install)
            local interface="" ip=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --interface) interface="$2"; shift 2 ;;
                    --ip)        ip="$2";        shift 2 ;;
                    *) msg_error "Opcion desconocida: $1"; exit 1 ;;
                esac
            done
            [[ -z "$interface" ]] && interface=$(prompt_interface_selection)
            check_interface_exists "$interface" || { msg_error "La interfaz $interface no existe"; exit 1; }
            [[ -z "$ip" ]] && ip=$(prompt_dns_ip_selection "$interface")
            validate_ip_or_cidr_dns "$ip" || { msg_error "IP invalida: $ip"; exit 1; }
            local bind_ip
            [[ "$ip" =~ / ]] && bind_ip=$(extract_ip_from_cidr "$ip") || bind_ip="$ip"
            ensure_static_ip "$interface" "$ip"
            install_bind            || exit 1
            configure_named_conf "$bind_ip" || exit 1
            start_bind_service "$interface"  || exit 1
            ;;

        list-interfaces) list_network_interfaces ;;

        check-static-ip)
            local interface=""
            while [[ $# -gt 0 ]]; do
                case "$1" in --interface) interface="$2"; shift 2 ;; *) msg_error "Opcion desconocida: $1"; exit 1 ;; esac
            done
            [[ -z "$interface" ]] && { msg_error "Se requiere --interface"; exit 1; }
            if check_static_ip "$interface"; then
                msg_success "IP estatica configurada en $interface"
            else
                msg_info "No hay IP estatica en $interface"; exit 1
            fi
            ;;

        set-static-ip)
            local interface="" ip="" dns=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --interface) interface="$2"; shift 2 ;;
                    --ip)        ip="$2";        shift 2 ;;
                    --dns)       dns="$2";       shift 2 ;;
                    *) msg_error "Opcion desconocida: $1"; exit 1 ;;
                esac
            done
            [[ -z "$interface" || -z "$ip" || -z "$dns" ]] && {
                msg_error "Se requieren --interface, --ip y --dns"; exit 1
            }
            validate_ip_cidr_dns "$ip" || { msg_error "IP debe incluir CIDR (ej: 192.168.1.10/24)"; exit 1; }
            configure_static_ip "$interface" "$ip" "$dns" || exit 1
            ;;

        create-zone)
            local domain="" ip="" ttl="" refresh="" retry="" expire="" negative=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --domain)   domain="$2";   shift 2 ;;
                    --ip)       ip="$2";       shift 2 ;;
                    --ttl)      ttl="$2";      shift 2 ;;
                    --refresh)  refresh="$2";  shift 2 ;;
                    --retry)    retry="$2";    shift 2 ;;
                    --expire)   expire="$2";   shift 2 ;;
                    --negative) negative="$2"; shift 2 ;;
                    *) msg_error "Opcion desconocida: $1"; exit 1 ;;
                esac
            done
            [[ -z "$domain" || -z "$ip" ]] && { msg_error "Se requieren --domain y --ip"; exit 1; }
            create_zone "$domain" "$ip" "$ttl" "$refresh" "$retry" "$expire" "$negative" || exit 1
            ;;

        create-reverse-zone)
            local ip="" domain="" ttl="" refresh="" retry="" expire="" negative=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --ip)       ip="$2";       shift 2 ;;
                    --domain)   domain="$2";   shift 2 ;;
                    --ttl)      ttl="$2";      shift 2 ;;
                    --refresh)  refresh="$2";  shift 2 ;;
                    --retry)    retry="$2";    shift 2 ;;
                    --expire)   expire="$2";   shift 2 ;;
                    --negative) negative="$2"; shift 2 ;;
                    *) msg_error "Opcion desconocida: $1"; exit 1 ;;
                esac
            done
            [[ -z "$ip" || -z "$domain" ]] && { msg_error "Se requieren --ip y --domain"; exit 1; }
            create_reverse_zone "$ip" "$domain" "$ttl" "$refresh" "$retry" "$expire" "$negative" || exit 1
            ;;

        list-zones)  list_zones ;;

        show-zone)
            local domain=""
            while [[ $# -gt 0 ]]; do
                case "$1" in --domain) domain="$2"; shift 2 ;; *) msg_error "Opcion desconocida: $1"; exit 1 ;; esac
            done
            [[ -z "$domain" ]] && { msg_error "Se requiere --domain"; exit 1; }
            show_zone "$domain" || exit 1
            ;;

        delete-zone)
            local domain=""
            while [[ $# -gt 0 ]]; do
                case "$1" in --domain) domain="$2"; shift 2 ;; *) msg_error "Opcion desconocida: $1"; exit 1 ;; esac
            done
            [[ -z "$domain" ]] && { msg_error "Se requiere --domain"; exit 1; }
            delete_zone "$domain" || exit 1
            ;;

        add-record)
            local domain="" hostname="" type="" value=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --domain)   domain="$2";   shift 2 ;;
                    --hostname) hostname="$2"; shift 2 ;;
                    --type)     type="$2";     shift 2 ;;
                    --value)    value="$2";    shift 2 ;;
                    *) msg_error "Opcion desconocida: $1"; exit 1 ;;
                esac
            done
            [[ -z "$domain" || -z "$hostname" || -z "$type" || -z "$value" ]] && {
                msg_error "Se requieren --domain, --hostname, --type y --value"; exit 1
            }
            add_record "$domain" "$hostname" "$type" "$value" || exit 1
            ;;

        logs)
            local lines="50"
            while [[ $# -gt 0 ]]; do
                case "$1" in --lines) lines="$2"; shift 2 ;; *) msg_error "Opcion desconocida: $1"; exit 1 ;; esac
            done
            show_logs "$lines"
            ;;

        logs-follow)  show_logs_follow ;;
        logs-errors)  show_logs_errors ;;
        validate)     validate_bind_config || exit 1 ;;

        test)
            local domain=""
            while [[ $# -gt 0 ]]; do
                case "$1" in --domain) domain="$2"; shift 2 ;; *) msg_error "Opcion desconocida: $1"; exit 1 ;; esac
            done
            [[ -z "$domain" ]] && { msg_error "Se requiere --domain"; exit 1; }
            test_resolution "$domain"     || exit 1
            test_www_resolution "$domain" || exit 1
            ;;

        test-reverse)
            local ip=""
            while [[ $# -gt 0 ]]; do
                case "$1" in --ip) ip="$2"; shift 2 ;; *) msg_error "Opcion desconocida: $1"; exit 1 ;; esac
            done
            [[ -z "$ip" ]] && { msg_error "Se requiere --ip"; exit 1; }
            test_reverse_resolution "$ip" || exit 1
            ;;

        status) check_bind_status ;;

        *) msg_error "Comando desconocido: $command"; show_help; exit 1 ;;
    esac
}

main "$@"