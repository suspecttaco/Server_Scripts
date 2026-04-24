#!/bin/sh
# =============================================================================
# backup.sh — Backup manual de PostgreSQL
#
# Uso desde el host:
#   docker exec CONTAINER_NAME sh /backup/backup.sh
#
# El archivo .sql se genera dentro del contenedor en /backup/
# y es visible en el host a traves del volumen montado en BACKUP_HOST_PATH
# =============================================================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="/backup/backup_${POSTGRES_DB}_${TIMESTAMP}.sql"

echo "[backup] Iniciando backup de la base de datos: ${POSTGRES_DB}"
echo "[backup] Archivo destino: ${BACKUP_FILE}"

# pg_dump utiliza las variables de entorno POSTGRES_USER y POSTGRES_DB
# que Docker inyecta automaticamente desde el .env
pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" > "${BACKUP_FILE}"

if [ $? -eq 0 ]; then
    echo "[backup] Backup completado exitosamente: ${BACKUP_FILE}"
else
    echo "[backup] ERROR: El backup fallo."
    exit 1
fi