#!/bin/bash
# =============================================================================
# ftp_manager.sh — Instalacion y configuracion de servidor FTP (vsftpd)
# Uso: sudo bash ftp_manager.sh
# Requiere: lib/ui.sh, lib/net.sh, lib/iface.sh, lib/ftp.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/ui.sh"       || { echo "ERROR: No se pudo cargar lib/ui.sh"; exit 1; }
source "$SCRIPT_DIR/lib/net.sh"      || { msg_error "No se pudo cargar lib/net.sh"; exit 1; }
source "$SCRIPT_DIR/ftp_lib/ftp.sh"  || { msg_error "No se pudo cargar ftp_lib/ftp.sh"; exit 1; }

# -----------------------------------------------------------------------------
# Verificar privilegios
# -----------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    msg_error "Este script debe ejecutarse como root o con sudo"
    exit 1
fi

# -----------------------------------------------------------------------------
# Función de invocación al gestor FTPS
# -----------------------------------------------------------------------------

_ftp_ftps_invoke() {
    local ssl_lib="${SCRIPT_DIR}/ssl_lib/ssl.sh"

    if [[ ! -f "$ssl_lib" ]]; then
        msg_error "ssl_lib/ssl.sh no encontrado en: ${ssl_lib}"
        msg_info  "Copie ssl_lib/ en el mismo directorio que ftp_manager.sh"
        echo ""
        read -rp "  Presiona Enter para continuar..."
        return 1
    fi

    # Cargar dependencias que ssl_lib necesita y que ftp_manager puede no tener
    if ! declare -f http_get_webroot &>/dev/null; then
        source "${SCRIPT_DIR}/ws_lib/ws_utils.sh" 2>/dev/null || true
    fi

    source "$ssl_lib" || {
        msg_error "No se pudo cargar ssl_lib"
        read -rp "  Presiona Enter para continuar..."
        return 1
    }

    while true; do
        clear
        draw_header "Gestion FTPS — vsftpd"
        echo ""

        # Panel de estado rápido
        if grep -q "^ssl_enable=YES" "${VSFTPD_CONF:-/etc/vsftpd/vsftpd.conf}" 2>/dev/null; then
            echo -e "  Estado FTPS: ${GREEN}activo${NC}"
        else
            echo -e "  Estado FTPS: ${YELLOW}inactivo${NC}"
        fi
        echo ""

        echo -e "  ${BLUE}1)${NC} Configurar FTPS (certificado + SSL en vsftpd)"
        echo -e "  ${BLUE}2)${NC} Ver certificado FTPS instalado"
        echo -e "  ${BLUE}3)${NC} Auditoria FTPS"
        echo -e "  ${BLUE}4)${NC} Desactivar FTPS"
        echo -e "  ${BLUE}0)${NC} Volver"
        echo ""
        msg_input "Opcion: "; read -r ftps_op

        case "$ftps_op" in
            1) ssl_configurar_vsftpd ;;
            2) ssl_mostrar_certificado "$SSL_DIR_VSFTPD" "vsftpd (FTPS)" ;;
            3)
                _sreset 2>/dev/null || true
                _ssl_audit_vsftpd
                _ssl_audit_resumen "vsftpd"
                ;;
            4)
                msg_input "¿Confirmar desactivar FTPS? [S/N]: "; read -r c
                [[ "${c^^}" =~ ^(S|SI|Y|YES)$ ]] && ssl_desactivar_vsftpd
                ;;
            0) return 0 ;;
            *) msg_alert "Opcion invalida"; sleep 1; continue ;;
        esac

        echo ""
        read -rp "  Presiona Enter para continuar..."
    done
}

# -----------------------------------------------------------------------------
# Menu principal
# -----------------------------------------------------------------------------
main_menu() {
    while true; do
        separator
        msg_info "FTP Manager — vsftpd"
        separator
        echo "  1) Instalar y configurar vsftpd"
        echo "  2) Gestionar usuarios FTP"
        echo "  3) Gestionar grupos y permisos"
        echo "  4) Gestion del servicio"
        echo "  5) Gestion de configuracion"
        echo "  6) SSL/TLS (FTPS) — Gestionar certificados FTPS"
        echo "  7) Desinstalar vsftpd"
        echo "  0) Salir"
        separator
        msg_input "Opcion: "
        read -r opcion

        case "$opcion" in
            1) instalar_vsftpd ;;
            2) menu_usuarios ;;
            3) menu_grupos ;;
            4) menu_servicio ;;
            5) menu_configuracion ;;
            6) _ftp_ftps_invoke ;;
            7) desinstalar_vsftpd ;;
            0) msg_info "Saliendo..."; exit 0 ;;
            *) msg_alert "Opcion invalida" ;;
        esac
    done
}

menu_grupos() {
    while true; do
        separator
        msg_info "Gestion de Grupos y Permisos"
        separator
        echo "  1) Listar grupos y permisos"
        echo "  2) Crear grupo"
        echo "  3) Eliminar grupo"
        echo "  4) Ver / reparar permisos de directorios"
        echo "  5) Reparar grupos primarios de usuarios"
        echo "  0) Volver"
        separator
        msg_input "Opcion: "
        read -r opcion

        case "$opcion" in
            1) listar_grupos_ftp ;;
            2) crear_grupo_ftp ;;
            3) eliminar_grupo_ftp ;;
            4) gestionar_permisos_directorios ;;
            5) reparar_grupos_usuarios ;;
            0) return ;;
            *) msg_alert "Opcion invalida" ;;
        esac
    done
}

menu_servicio() {
    while true; do
        separator
        msg_info "Gestion del Servicio vsftpd"
        separator
        echo "  1) Ver estado detallado"
        echo "  2) Iniciar servicio"
        echo "  3) Detener servicio"
        echo "  4) Reiniciar servicio"
        echo "  5) Habilitar / deshabilitar arranque automatico"
        echo "  0) Volver"
        separator
        msg_input "Opcion: "
        read -r opcion

        case "$opcion" in
            1) mostrar_estado ;;
            2) iniciar_servicio ;;
            3) detener_servicio ;;
            4) reiniciar_servicio ;;
            5) toggle_arranque_automatico ;;
            0) return ;;
            *) msg_alert "Opcion invalida" ;;
        esac
    done
}

menu_configuracion() {
    while true; do
        separator
        msg_info "Gestion de Configuracion"
        separator
        echo "  1) Ver configuracion activa"
        echo "  2) Editar parametros del servidor"
        echo "  3) Gestionar firewall (puertos FTP)"
        echo "  0) Volver"
        separator
        msg_input "Opcion: "
        read -r opcion

        case "$opcion" in
            1) ver_configuracion ;;
            2) editar_configuracion ;;
            3) gestionar_firewall ;;
            0) return ;;
            *) msg_alert "Opcion invalida" ;;
        esac
    done
}

menu_usuarios() {
    while true; do
        separator
        msg_info "Gestion de Usuarios FTP"
        separator
        echo "  1) Crear usuarios en lote"
        echo "  2) Actualizar usuario (nombre / contrasena / grupo)"
        echo "  3) Eliminar usuario"
        echo "  4) Listar usuarios FTP"
        echo "  0) Volver"
        separator
        msg_input "Opcion: "
        read -r opcion

        case "$opcion" in
            1) crear_usuarios_lote ;;
            2) actualizar_usuario_ftp ;;
            3) eliminar_usuario_ftp ;;
            4) listar_usuarios_ftp ;;
            0) return ;;
            *) msg_alert "Opcion invalida" ;;
        esac
    done
}

main_menu