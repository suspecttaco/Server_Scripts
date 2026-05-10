#!/bin/bash
# Ejecuta los scripts de configuracion en orden al primer arranque

set -e

echo "entrypoint: iniciando configuracion"

/setup/certs.sh
/setup/rsyslog.sh
/setup/postfix.sh
/setup/dovecot.sh
/setup/dkim.sh
/setup/spamassassin.sh
/setup/fail2ban.sh
/setup/accounts.sh
/setup/backup.sh

echo "entrypoint: configuracion completada"
touch /tmp/setup_done