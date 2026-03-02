#!/bin/bash
# =============================================================================
# ftp_manager.sh — Instalacion y configuracion de servidor FTP (vsftpd)
# Uso: sudo bash ftp_manager.sh
# Requiere: lib/ui.sh, lib/net.sh, lib/iface.sh, lib/ftp.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/ui.sh"   || { echo "ERROR: No se pudo cargar lib/ui.sh"; exit 1; }
source "$SCRIPT_DIR/lib/net.sh"  || { msg_error "No se pudo cargar lib/net.sh"; exit 1; }
source "$SCRIPT_DIR/ftp_lib/ftp.sh"  || { msg_error "No se pudo cargar ftp_lib/ftp.sh"; exit 1; }

# -----------------------------------------------------------------------------
# Verificar privilegios
# -----------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    msg_error "Este script debe ejecutarse como root o con sudo"
    exit 1
fi

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
        echo "  6) Desinstalar vsftpd"
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
            6) desinstalar_vsftpd ;;
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