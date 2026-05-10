#!/bin/bash
# Configura OpenDKIM y genera claves si no existen

set -e

KEY_DIR=/etc/mail_config/dkim
SELECTOR=mail

echo "dkim: verificando claves"

if [ ! -f "$KEY_DIR/${SELECTOR}.private" ]; then
    mkdir -p "$KEY_DIR"
    opendkim-genkey \
        -b 2048 \
        -d "$MAIL_DOMAIN" \
        -D "$KEY_DIR" \
        -s "$SELECTOR" \
        -v
    chmod 600 "$KEY_DIR/${SELECTOR}.private"
    echo "dkim: claves generadas en $KEY_DIR"
else
    echo "dkim: claves ya existen, se omite generacion"
fi

echo "dkim: configurando opendkim.conf"

cat > /etc/opendkim.conf << EOF
# modo
Mode                sv
Syslog              yes
SyslogSuccess       yes
LogWhy              yes

# red
Socket              inet:8891@localhost
PidFile             /var/run/opendkim/opendkim.pid
UMask               002

# identidad
Domain              ${MAIL_DOMAIN}
Selector            ${SELECTOR}
KeyFile             ${KEY_DIR}/${SELECTOR}.private

# tablas
InternalHosts       /etc/opendkim/InternalHosts
SigningTable        refile:/etc/opendkim/SigningTable
KeyTable            /etc/opendkim/KeyTable

Canonicalization    relaxed/simple
EOF

echo "dkim: configurando tablas"

mkdir -p /etc/opendkim

cat > /etc/opendkim/SigningTable << EOF
*@${MAIL_DOMAIN} ${SELECTOR}._domainkey.${MAIL_DOMAIN}
EOF

cat > /etc/opendkim/KeyTable << EOF
${SELECTOR}._domainkey.${MAIL_DOMAIN} ${MAIL_DOMAIN}:${SELECTOR}:${KEY_DIR}/${SELECTOR}.private
EOF

cat > /etc/opendkim/InternalHosts << EOF
127.0.0.1
localhost
172.16.0.0/12
192.168.0.0/16
10.0.0.0/8
EOF

mkdir -p /var/run/opendkim
chown opendkim:opendkim /var/run/opendkim 2>/dev/null || true

echo "dkim: registro DNS TXT requerido:"
echo "------"
cat "$KEY_DIR/${SELECTOR}.txt" 2>/dev/null || echo "archivo .txt no encontrado, revisar $KEY_DIR"
echo "------"
echo "dkim: listo"