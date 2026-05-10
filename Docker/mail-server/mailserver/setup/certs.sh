#!/bin/bash
# Genera certificados autofirmados si no existen

CERT_DIR=/etc/mail_config/certs
KEY=$CERT_DIR/mail.key
CERT=$CERT_DIR/mail.crt

if [ -f "$KEY" ] && [ -f "$CERT" ]; then
    echo "certs: ya existen, se omite generacion"
    exit 0
fi

mkdir -p "$CERT_DIR"

openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "$KEY" \
    -out "$CERT" \
    -subj "/C=MX/ST=Sinaloa/L=Local/O=${MAIL_DOMAIN}/CN=${MAIL_HOSTNAME}"

chmod 600 "$KEY"
chmod 644 "$CERT"

echo "certs: generados en $CERT_DIR"