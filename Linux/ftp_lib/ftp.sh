#!/bin/bash
# =============================================================================
# ftp_lib/ftp.sh — Entry point. Variables globales y carga de modulos.
# Uso: source ftp_lib/ftp.sh  |  Requiere: source lib/ui.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Variables globales
# -----------------------------------------------------------------------------
FTP_ROOT="${FTP_ROOT:-/srv/ftp}"
FTP_GENERAL="${FTP_GENERAL:-$FTP_ROOT/general}"
FTP_USER_PREFIX="${FTP_USER_PREFIX:-ftp_}"   # prefijo para directorios de usuario
FTP_BANNER="${FTP_BANNER:-Servidor FTP}"
FTP_SSH_GROUP="${FTP_SSH_GROUP:-ftp_users}"  # grupo para bloqueo SSH

VSFTPD_CONF="${VSFTPD_CONF:-/etc/vsftpd/vsftpd.conf}"
VSFTPD_DIR="/etc/vsftpd"
VSFTPD_GROUPS_FILE="${VSFTPD_DIR}/groups"
VSFTPD_USERS_META="${VSFTPD_DIR}/virtual_users_meta"  # usuario_ftp:grupo
PAM_FILE="/etc/pam.d/vsftpd"

FTP_GROUPS=()

# -----------------------------------------------------------------------------
# Cargar modulos
# -----------------------------------------------------------------------------
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$_LIB_DIR/ftp_groups.sh"
source "$_LIB_DIR/ftp_install.sh"
source "$_LIB_DIR/ftp_users.sh"
source "$_LIB_DIR/ftp_dirs.sh"
source "$_LIB_DIR/ftp_service.sh"
source "$_LIB_DIR/ftp_config.sh"

_cargar_grupos