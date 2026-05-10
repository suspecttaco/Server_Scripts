#!/bin/bash
# Restaura un respaldo de buzones
# Uso: restore.sh [archivo.tar.gz]
# Sin argumento usa el respaldo mas reciente

BACKUP_DIR=/backups
MAIL_DIR=/var/mail

if [ -n "$1" ]; then
    BACKUP_FILE="$1"
else
    BACKUP_FILE=$(ls -1t "$BACKUP_DIR"/mailbackup_*.tar.gz 2>/dev/null | head -n 1)
fi

if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
    echo "restore: ERROR - no se encontro archivo de respaldo"
    echo "uso: $0 [ruta/archivo.tar.gz]"
    exit 1
fi

echo "restore: usando respaldo $BACKUP_FILE"
echo "restore: restaurando en $MAIL_DIR"

tar -xzf "$BACKUP_FILE" -C "$MAIL_DIR"

if [ $? -eq 0 ]; then
    echo "restore: completado"
else
    echo "restore: ERROR durante la restauracion"
    exit 1
fi