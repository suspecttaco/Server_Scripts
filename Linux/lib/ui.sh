#!/bin/bash
# =============================================================================
# lib/ui.sh — Utilidades de interfaz: colores, mensajes, separador
# Uso: source lib/ui.sh
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

separator() {
    echo -e "${CYAN}------------------------------------------------------------${NC}"
}

msg_success() { echo -e "${NC}[ ${GREEN}EXITO ${NC}] $1"; }
msg_error()   { echo -e "${NC}[ ${RED}ERROR ${NC}] $1" >&2; }
msg_info()    { echo -e "${NC}[ ${BLUE}INFO ${NC} ] $1"; }
msg_alert()   { echo -e "${NC}[ ${YELLOW}ALERT ${NC}] $1"; }
msg_process() { echo -e "${NC}[  ${CYAN}---  ${NC}] $1"; }
msg_input()   { echo -ne "${CYAN}->${NC} $1"; }