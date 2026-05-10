#!/bin/bash
# Prepara directorios para Dovecot
# El config viene en la imagen via Dockerfile

set -e

echo "dovecot: preparando directorios"

mkdir -p /var/spool/postfix/private
mkdir -p /var/run/dovecot
touch /var/log/dovecot.log
touch /var/log/dovecot-info.log

echo "dovecot: listo"