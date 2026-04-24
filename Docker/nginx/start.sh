#!/bin/bash
# =============================================================================
# start.sh — Arranque de php-fpm y Nginx
# Mismo patron que Apache: php-fpm en background, Nginx en primer plano
# =============================================================================

# Arrancar php-fpm en segundo plano
php-fpm --nodaemonize &
PHP_PID=$!
echo "[start] php-fpm iniciado (PID: ${PHP_PID})"

sleep 1

# Nginx en primer plano como PID 1
echo "[start] Iniciando Nginx..."
exec nginx -g "daemon off;"