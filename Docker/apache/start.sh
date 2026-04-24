#!/bin/bash
# =============================================================================
# start.sh — Arranque de php-fpm y Apache
#
# En Fedora, PHP funciona via FastCGI (php-fpm), no como modulo de Apache.
# Este script arranca php-fpm en segundo plano y luego Apache en primer plano
# para que Docker lo gestione como PID 1.
# =============================================================================

# Arrancar php-fpm en segundo plano
php-fpm --nodaemonize &
PHP_PID=$!
echo "[start] php-fpm iniciado (PID: ${PHP_PID})"

# Esperar brevemente a que php-fpm levante su socket
sleep 1

# Arrancar Apache en primer plano (PID 1)
echo "[start] Iniciando Apache..."
exec httpd -D FOREGROUND