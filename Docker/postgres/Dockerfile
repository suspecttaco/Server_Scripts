# =============================================================================
# postgres/Dockerfile
# Imagen base oficial, sin modificaciones.
# Todo lo necesario se maneja via docker-compose.yml y variables de entorno.
# =============================================================================

FROM postgres:16-alpine

LABEL maintainer="infra"
LABEL description="PostgreSQL contenedor de produccion para infra_red"

# Script SQL de inicializacion: se ejecuta automaticamente la primera vez
# que el volumen esta vacio
COPY init/01_schema.sql /docker-entrypoint-initdb.d/01_schema.sql

# Script de backup: se copia a /usr/local/bin para que no lo pise el volumen
# El volumen /backup solo se usa como destino de los archivos .sql generados
COPY init/backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

EXPOSE 5432

CMD ["postgres"]