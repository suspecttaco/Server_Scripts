#!/bin/bash
# =============================================================================
# entrypoint.sh — Configura usuario FTP y arranca vsftpd
# Autenticacion via /etc/shadow usando password-auth de PAM
# (mismo metodo que ftp_install.sh del proyecto)
# =============================================================================

: "${FTP_USER:?Variable FTP_USER no definida}"
: "${FTP_PASS:?Variable FTP_PASS no definida}"
: "${PASV_ADDRESS:?Variable PASV_ADDRESS no definida}"
: "${PASV_MIN_PORT:?Variable PASV_MIN_PORT no definida}"
: "${PASV_MAX_PORT:?Variable PASV_MAX_PORT no definida}"

# -----------------------------------------------------------------------------
# Crear usuario del sistema para FTP
# -M: no crear home (ya existe el volumen)
# -d: directorio home apunta al volumen compartido
# -s: sin shell interactiva
# -----------------------------------------------------------------------------
if ! id "${FTP_USER}" &>/dev/null; then
    useradd -M -d /var/ftp/uploads -s /sbin/nologin "${FTP_USER}"
    echo "[ftp] Usuario '${FTP_USER}' creado"
fi

# Establecer contrasena via openssl para garantizar compatibilidad con shadow
echo "${FTP_USER}:${FTP_PASS}" | chpasswd
echo "[ftp] Contrasena configurada para '${FTP_USER}'"

# Permisos sobre el directorio
chown -R "${FTP_USER}:${FTP_USER}" /var/ftp/uploads
chmod 755 /var/ftp/uploads
echo "[ftp] Permisos configurados en /var/ftp/uploads"

# -----------------------------------------------------------------------------
# PAM: autenticacion via /etc/shadow (igual que ftp_install.sh)
# -----------------------------------------------------------------------------
cat > /etc/pam.d/vsftpd << 'PAMEOF'
#%PAM-1.0
auth     include  password-auth
account  include  password-auth
PAMEOF
echo "[ftp] PAM configurado via password-auth"

# -----------------------------------------------------------------------------
# Inyectar PASV_ADDRESS y puertos en vsftpd.conf
# -----------------------------------------------------------------------------
sed -i "s|^pasv_address=.*|pasv_address=${PASV_ADDRESS}|" /etc/vsftpd/vsftpd.conf
grep -q "^pasv_address=" /etc/vsftpd/vsftpd.conf || \
    echo "pasv_address=${PASV_ADDRESS}" >> /etc/vsftpd/vsftpd.conf

sed -i "s|^pasv_min_port=.*|pasv_min_port=${PASV_MIN_PORT}|" /etc/vsftpd/vsftpd.conf
sed -i "s|^pasv_max_port=.*|pasv_max_port=${PASV_MAX_PORT}|" /etc/vsftpd/vsftpd.conf

echo "[ftp] Configuracion PASV: ${PASV_ADDRESS}:${PASV_MIN_PORT}-${PASV_MAX_PORT}"

# -----------------------------------------------------------------------------
# Arrancar vsftpd en primer plano
# -----------------------------------------------------------------------------
echo "[ftp] Iniciando vsftpd..."
exec vsftpd /etc/vsftpd/vsftpd.conf