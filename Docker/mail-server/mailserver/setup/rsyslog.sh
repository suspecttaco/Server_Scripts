#!/bin/bash
# Configura rsyslog para recibir logs de Postfix/Dovecot en Docker

set -e

echo "rsyslog: configurando para entorno Docker"

cat > /etc/rsyslog.d/mail.conf << 'CONF'
# habilitar socket local para que Postfix pueda enviar logs
module(load="imuxsock" SysSock.Use="on")

# deshabilitar imjournal (no hay systemd en Docker)
# ya cargado en rsyslog.conf, se sobreescribe aqui
mail.*     /var/log/maillog
mail.*     /var/log/mail.log
CONF

# deshabilitar imjournal en config principal
sed -i 's/module(load="imjournal"/# module(load="imjournal"/' /etc/rsyslog.conf
sed -i 's/       FileCreateMode="0600"/# FileCreateMode="0600"/' /etc/rsyslog.conf
sed -i 's/       UsePid="system"/# UsePid="system"/' /etc/rsyslog.conf
sed -i 's/       StateFile="imjournal.state")/# StateFile="imjournal.state")/' /etc/rsyslog.conf

# habilitar SysSock en config principal
sed -i 's/SysSock.Use="off"/SysSock.Use="on"/' /etc/rsyslog.conf

echo "rsyslog: listo"