#!/bin/bash
# Configura el cron job de respaldo de buzones

set -e

BACKUP_SCRIPT=/usr/local/bin/mail_backup.sh

echo "backup: creando script de respaldo"

cat > "$BACKUP_SCRIPT" << 'SCRIPT'
#!/bin/bash
# Respaldo diario de buzones

BACKUP_DIR=/backups
MAIL_DIR=/var/mail
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FILENAME="mailbackup_${TIMESTAMP}.tar.gz"
KEEP=7

mkdir -p "$BACKUP_DIR"

echo "backup: iniciando respaldo $FILENAME"

tar -czf "$BACKUP_DIR/$FILENAME" -C "$MAIL_DIR" . 2>/var/log/backup.log

if [ $? -eq 0 ]; then
    echo "backup: $FILENAME completado"
else
    echo "backup: ERROR al crear $FILENAME"
    exit 1
fi

# eliminar respaldos mas antiguos, conservar los ultimos $KEEP
COUNT=$(ls -1 "$BACKUP_DIR"/mailbackup_*.tar.gz 2>/dev/null | wc -l)
if [ "$COUNT" -gt "$KEEP" ]; then
    ls -1t "$BACKUP_DIR"/mailbackup_*.tar.gz | tail -n +$((KEEP + 1)) | xargs rm -f
    echo "backup: respaldos antiguos eliminados, se conservan $KEEP"
fi
SCRIPT

chmod +x "$BACKUP_SCRIPT"

echo "backup: registrando cron job (cada 24 horas)"

HOUR=${BACKUP_HOUR:-2}
echo "0 $HOUR * * * root $BACKUP_SCRIPT >> /var/log/backup.log 2>&1" > /etc/cron.d/mail_backup
chmod 644 /etc/cron.d/mail_backup

echo "backup: listo (corre diario a las ${HOUR}:00)"