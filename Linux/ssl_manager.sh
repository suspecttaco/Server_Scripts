#!/bin/bash
# =============================================================================
# ssl_manager.sh — Gestor SSL/TLS para servicios Linux
#
# Uso: sudo bash ssl_manager.sh
#
# Servicios soportados:
#   HTTP : Apache (httpd), Nginx, Tomcat
#   FTP  : vsftpd (FTPS explícito con AUTH TLS)
#
# Puede ejecutarse:
#   a) De forma standalone para servicios ya instalados
#   b) Invocado desde ws_manager.sh o ftp_manager.sh vía hook post-instalación
#
# Requiere: lib/ui.sh, lib/utils.sh, ws_lib/ws_utils.sh, ssl_lib/ssl.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Verificar root
# -----------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Este script debe ejecutarse como root o con sudo"
    exit 1
fi

# -----------------------------------------------------------------------------
# Cargar librerías
# -----------------------------------------------------------------------------
source "${SCRIPT_DIR}/lib/ui.sh"    || { echo "ERROR: lib/ui.sh no cargó";    exit 1; }
source "${SCRIPT_DIR}/lib/utils.sh" 2>/dev/null || true   # opcional, funciones de check_*

# ws_lib necesario para constantes HTTP (webroot, usuarios, etc.)
source "${SCRIPT_DIR}/ws_lib/ws_utils.sh"     || { msg_error "ws_utils.sh no cargó";     exit 1; }
source "${SCRIPT_DIR}/ws_lib/ws_validators.sh" 2>/dev/null || true

# ftp_lib necesario para VSFTPD_CONF y helpers FTP
source "${SCRIPT_DIR}/ftp_lib/ftp.sh" 2>/dev/null || {
    # Si ftp_lib no está disponible, definir el mínimo necesario
    VSFTPD_CONF="${VSFTPD_CONF:-/etc/vsftpd/vsftpd.conf}"
    msg_alert "ftp_lib no disponible — funcionalidad FTPS limitada"
}

# Cargar SSL (entry point que carga todos los módulos ssl_lib/)
source "${SCRIPT_DIR}/ssl_lib/ssl.sh" || { msg_error "ssl_lib/ssl.sh no cargó"; exit 1; }

# -----------------------------------------------------------------------------
# Menú: Configurar SSL en un servicio específico
# -----------------------------------------------------------------------------
_ssl_menu_configurar() {
    while true; do
        clear
        draw_header "Configurar SSL/TLS — Seleccionar Servicio"
        echo ""

        # Mostrar estado actual de cada servicio
        local servicios=("httpd:Apache (httpd):HTTP" "nginx:Nginx:HTTP" "tomcat:Tomcat:HTTP" "vsftpd:vsftpd:FTP")
        local i=1
        local entrada
        for entrada in "${servicios[@]}"; do
            local svc="${entrada%%:*}"
            local nombre="${entrada#*:}"; nombre="${nombre%:*}"
            local tipo="${entrada##*:}"
            local estado_ssl=""
            local instalado=""

            if rpm -q "$svc" &>/dev/null; then
                instalado="${GREEN}instalado${NC}"
                if ssl_esta_activo "$svc" 2>/dev/null; then
                    estado_ssl="${GREEN}[SSL activo]${NC}"
                else
                    estado_ssl="${YELLOW}[sin SSL]${NC}"
                fi
            else
                instalado="${GRAY}no instalado${NC}"
                estado_ssl="${GRAY}[N/A]${NC}"
            fi

            printf "  ${BLUE}%s)${NC} %-22s %-8s " "$i" "${nombre}" "$tipo"
            echo -e "${instalado}  ${estado_ssl}"
            (( i++ ))
        done

        echo ""
        echo -e "  ${BLUE}0)${NC} Volver"
        echo ""
        msg_input "Opción: "; read -r op

        case "$op" in
            1) ssl_configurar_apache  ;;
            2) ssl_configurar_nginx   ;;
            3) ssl_configurar_tomcat  ;;
            4) ssl_configurar_vsftpd  ;;
            0) return 0 ;;
            *) msg_alert "Opción inválida"; sleep 1 ;;
        esac

        echo ""
        read -rp "  Presiona Enter para continuar..."
    done
}

# -----------------------------------------------------------------------------
# Menú: Ver certificados instalados
# -----------------------------------------------------------------------------
_ssl_menu_certificados() {
    while true; do
        clear
        draw_header "Certificados SSL/TLS Instalados"
        echo ""

        local dirs=(
            "${SSL_DIR_APACHE}:Apache (httpd)"
            "${SSL_DIR_NGINX}:Nginx"
            "${SSL_DIR_TOMCAT}:Tomcat"
            "${SSL_DIR_VSFTPD}:vsftpd (FTPS)"
        )

        local entrada
        for entrada in "${dirs[@]}"; do
            local dir="${entrada%%:*}"
            local nombre="${entrada##*:}"
            ssl_mostrar_certificado "$dir" "$nombre" 2>/dev/null || true
        done

        echo ""
        echo -e "  ${BLUE}0)${NC} Volver"
        echo ""
        msg_input "Opción: "; read -r op
        [[ "$op" == "0" ]] && return 0
    done
}

# -----------------------------------------------------------------------------
# Menú: Desactivar SSL en un servicio
# -----------------------------------------------------------------------------
_ssl_menu_desactivar() {
    clear
    draw_header "Desactivar SSL/TLS — Seleccionar Servicio"
    echo ""
    echo -e "  ${RED}ADVERTENCIA:${NC} Esta operación elimina la configuración SSL del servicio."
    echo -e "  Los certificados se conservan en ${SSL_BASE_DIR}."
    echo ""
    echo -e "  ${BLUE}1)${NC} Apache (httpd)"
    echo -e "  ${BLUE}2)${NC} Nginx"
    echo -e "  ${BLUE}3)${NC} Tomcat"
    echo -e "  ${BLUE}4)${NC} vsftpd (FTPS)"
    echo -e "  ${BLUE}0)${NC} Volver"
    echo ""
    msg_input "Opción: "; read -r op

    case "$op" in
        1)
            msg_input "¿Confirmar desactivar SSL en Apache? [S/N]: "; read -r c
            [[ "${c^^}" =~ ^(S|SI|Y|YES)$ ]] && ssl_desactivar_apache
            ;;
        2)
            msg_input "¿Confirmar desactivar SSL en Nginx? [S/N]: "; read -r c
            [[ "${c^^}" =~ ^(S|SI|Y|YES)$ ]] && ssl_desactivar_nginx
            ;;
        3)
            msg_input "¿Confirmar desactivar SSL en Tomcat? [S/N]: "; read -r c
            [[ "${c^^}" =~ ^(S|SI|Y|YES)$ ]] && ssl_desactivar_tomcat
            ;;
        4)
            msg_input "¿Confirmar desactivar FTPS en vsftpd? [S/N]: "; read -r c
            [[ "${c^^}" =~ ^(S|SI|Y|YES)$ ]] && ssl_desactivar_vsftpd
            ;;
        0) return 0 ;;
        *) msg_alert "Opción inválida" ;;
    esac

    echo ""
    read -rp "  Presiona Enter para continuar..."
}

# -----------------------------------------------------------------------------
# Menú principal
# -----------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        draw_header "Gestor SSL/TLS — Linux"
        echo ""

        # Panel de estado rápido
        msg_info "Estado SSL actual:"
        echo ""
        local servicios_http=("httpd:Apache" "nginx:Nginx" "tomcat:Tomcat" "vsftpd:vsftpd FTP")
        local entrada
        for entrada in "${servicios_http[@]}"; do
            local svc="${entrada%%:*}"
            local nombre="${entrada##*:}"
            local status_str

            if ! rpm -q "$svc" &>/dev/null; then
                status_str="${GRAY}no instalado${NC}"
            elif ssl_esta_activo "$svc" 2>/dev/null; then
                status_str="${GREEN}SSL activo${NC}"
            else
                status_str="${YELLOW}sin SSL${NC}"
            fi

            printf "    %-20s " "$nombre"
            echo -e "$status_str"
        done

        echo ""
        separator
        echo -e "  ${BLUE}1)${NC} Configurar SSL/TLS en un servicio"
        echo -e "  ${BLUE}2)${NC} Ver certificados instalados"
        echo -e "  ${BLUE}3)${NC} Auditoría SSL completa (todos los servicios)"
        echo -e "  ${BLUE}4)${NC} Auditoría SSL por servicio"
        echo -e "  ${BLUE}5)${NC} Desactivar SSL en un servicio"
        echo -e "  ${BLUE}0)${NC} Salir"
        separator
        echo ""
        msg_input "Opción: "; read -r op

        case "$op" in
            1) _ssl_menu_configurar ;;
            2) _ssl_menu_certificados ;;
            3)
                ssl_audit_completo
                ;;
            4)
                clear
                draw_header "Auditoría SSL — Seleccionar Servicio"
                echo ""
                echo -e "  ${BLUE}1)${NC} Apache (httpd)"
                echo -e "  ${BLUE}2)${NC} Nginx"
                echo -e "  ${BLUE}3)${NC} Tomcat"
                echo -e "  ${BLUE}4)${NC} vsftpd (FTPS)"
                echo ""
                msg_input "Opción: "; read -r svc_op
                case "$svc_op" in
                    1) ssl_audit_servicio "apache"  ;;
                    2) ssl_audit_servicio "nginx"   ;;
                    3) ssl_audit_servicio "tomcat"  ;;
                    4) ssl_audit_servicio "vsftpd"  ;;
                    *) msg_alert "Opción inválida" ;;
                esac
                read -rp "  Presiona Enter para continuar..."
                ;;
            5) _ssl_menu_desactivar ;;
            0)
                echo ""
                msg_info "Saliendo del Gestor SSL..."
                echo ""
                exit 0
                ;;
            *) msg_alert "Opción inválida"; sleep 1 ;;
        esac
    done
}

main_menu