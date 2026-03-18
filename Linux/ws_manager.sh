#!/bin/bash
# =============================================================================
# ws_manager.sh — Gestor de servicios web (Apache, Nginx, Tomcat)
#
# Uso: ./ws_manager.sh [OPCIONES]
#
# Opciones:
#   -d, --debug     Activa set -x para trazar la ejecución
#   -h, --help      Muestra esta ayuda
#   -v, --verify    Verifica dependencias y sale
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Parseo de argumentos
# -----------------------------------------------------------------------------

DEBUG=false

_usage() {
    echo ""
    echo "  Uso: $0 [OPCIONES]"
    echo ""
    echo "  Opciones:"
    echo "    -d, --debug     Activa trazado de ejecución (set -x)"
    echo "    -v, --verify    Verifica dependencias y sale"
    echo "    -h, --help      Muestra esta ayuda"
    echo ""
}

for arg in "$@"; do
    case "$arg" in
        -d|--debug)   DEBUG=true ;;
        -h|--help)    _usage; exit 0 ;;
        -v|--verify)  VERIFY_ONLY=true ;;
        *)
            echo "Opcion desconocida: $arg"
            _usage
            exit 1
            ;;
    esac
done

[[ "$DEBUG" == true ]] && set -x

# -----------------------------------------------------------------------------
# Carga de librerías
# -----------------------------------------------------------------------------

source "${SCRIPT_DIR}/lib/ui.sh"
source "${SCRIPT_DIR}/lib/net.sh"

[[ -f "${SCRIPT_DIR}/lib/utils.sh" ]] && source "${SCRIPT_DIR}/lib/utils.sh"

source "${SCRIPT_DIR}/ws_lib/ws_utils.sh"
source "${SCRIPT_DIR}/ws_lib/ws_validators.sh"
source "${SCRIPT_DIR}/ws_lib/ws_status.sh"
source "${SCRIPT_DIR}/ws_lib/ws_install.sh"
source "${SCRIPT_DIR}/ws_lib/ws_config.sh"
source "${SCRIPT_DIR}/ws_lib/ws_versions.sh"
source "${SCRIPT_DIR}/ws_lib/ws_monitor.sh"

# ws_ftp_source carga bajo demanda desde http_menu_instalar
# pero si existe lo precargamos para validar su sintaxis al inicio
[[ -f "${SCRIPT_DIR}/ws_lib/ws_ftp_source.sh" ]] && \
    source "${SCRIPT_DIR}/ws_lib/ws_ftp_source.sh" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Solo verificar dependencias si se pidió
# -----------------------------------------------------------------------------

if [[ "${VERIFY_ONLY:-false}" == true ]]; then
    draw_header "Verificacion de dependencias"
    echo ""
    http_verificar_dependencias
    exit $?
fi

# -----------------------------------------------------------------------------
# Verificaciones previas al inicio
# -----------------------------------------------------------------------------

if ! http_verificar_dependencias &>/dev/null; then
    draw_header "Advertencia de dependencias"
    echo ""
    http_verificar_dependencias
    echo ""
    msg_alert "Algunas herramientas criticas no estan disponibles"
    msg_info "El script puede no funcionar correctamente"
    echo ""
    input_read "Continuar de todas formas? [s/n]" _resp
    http_validar_confirmacion "$_resp" || exit 0
fi

# -----------------------------------------------------------------------------
# Función de invocación al gestor SSL
# -----------------------------------------------------------------------------

_ws_ssl_invoke() {
    local ssl_mgr="${SCRIPT_DIR}/ssl_manager.sh"

    if [[ ! -f "$ssl_mgr" ]]; then
        msg_error "ssl_manager.sh no encontrado en: ${ssl_mgr}"
        msg_info  "Copie ssl_manager.sh en el mismo directorio que ws_manager.sh"
        echo ""
        read -rp "  Presiona Enter para continuar..."
        return 1
    fi

    bash "$ssl_mgr"
}

# -----------------------------------------------------------------------------
# Menú principal
# -----------------------------------------------------------------------------

main_menu() {
    while true; do
        clear
        draw_header "Gestor de Servicios Web — Fedora Server"
        echo ""
        echo -e "  ${BLUE}1)${NC} Verificar estado de servicios"
        echo -e "  ${BLUE}2)${NC} Instalar servicio HTTP"
        echo -e "  ${BLUE}3)${NC} Configurar / Seguridad"
        echo -e "  ${BLUE}4)${NC} Monitoreo"
        echo -e "  ${BLUE}5)${NC} Verificar dependencias del sistema"
        echo -e "  ${BLUE}6)${NC} SSL/TLS — Gestionar certificados y HTTPS"
        echo -e "  ${BLUE}7)${NC} Salir"
        echo ""
        [[ "$DEBUG" == true ]] && echo -e "  ${YELLOW}[DEBUG ACTIVO]${NC}"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) http_menu_verificar ;;
            2) http_menu_instalar ;;
            3) http_menu_configurar ;;
            4) http_menu_monitoreo ;;
            5)
                draw_header "Verificacion de dependencias"
                echo ""
                http_verificar_dependencias
                echo ""
                msg_pause
                ;;
            6) _ws_ssl_invoke ;;
            7)
                echo ""
                msg_info "Hasta luego."
                echo ""
                exit 0
                ;;
            *)
                msg_error "Opcion invalida. Seleccione entre 1 y 7"
                sleep 2
                ;;
        esac
    done
}

main_menu