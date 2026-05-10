#!/bin/bash
# Prepara directorios para Dovecot
# El config ya viene en la imagen via Dockerfile

set -e

echo "dovecot: preparando directorios"

mkdir -p /var/spool/postfix/private
mkdir -p /var/run/dovecot

echo "dovecot: listo"