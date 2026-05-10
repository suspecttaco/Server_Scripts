#!/bin/bash
# Configura Postfix (SMTP)

set -e

CERT_DIR=/etc/mail_config/certs

echo "postfix: configurando main.cf"

cat > /etc/postfix/main.cf << EOF2
# identidad
myhostname = ${MAIL_HOSTNAME}
mydomain = ${MAIL_DOMAIN}
myorigin = \$mydomain

# red
inet_interfaces = all
inet_protocols = ipv4
mydestination = \$myhostname, localhost.\$mydomain, localhost

# dominios virtuales
virtual_mailbox_domains = \$mydomain
virtual_mailbox_base = /var/mail
virtual_mailbox_maps = hash:/etc/postfix/vmailbox
virtual_minimum_uid = 100
virtual_uid_maps = static:1000
virtual_gid_maps = static:1000

# TLS entrante
smtpd_tls_cert_file = ${CERT_DIR}/mail.crt
smtpd_tls_key_file = ${CERT_DIR}/mail.key
smtpd_tls_security_level = may
smtpd_tls_loglevel = 1

# TLS saliente
smtp_tls_security_level = may
smtp_tls_loglevel = 1

# autenticacion SASL via Dovecot
smtpd_sasl_auth_enable = yes
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_security_options = noanonymous

# restricciones
smtpd_relay_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination

smtpd_recipient_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination

# milter DKIM
milter_default_action = accept
milter_protocol = 6
smtpd_milters =
non_smtpd_milters =

mynetworks = 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 10.0.0.0/8
compatibility_level = 3.6
maillog_file = /var/log/maillog
EOF2

echo "postfix: creando tabla de buzones virtuales"

mkdir -p /etc/postfix

cat > /etc/postfix/vmailbox << EOF2
${MAIL_USER1}@${MAIL_DOMAIN}    ${MAIL_USER1}/Maildir/
${MAIL_USER2}@${MAIL_DOMAIN}    ${MAIL_USER2}/Maildir/
EOF2

postmap /etc/postfix/vmailbox

echo "postfix: configurando master.cf"

cat > /etc/postfix/master.cf << 'EOF2'
smtp      inet  n       -       n       -       -       smtpd
submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
pickup    unix  n       -       n       60      1       pickup
cleanup   unix  n       -       n       -       0       cleanup
qmgr      unix  n       -       n       300     1       qmgr
tlsmgr    unix  -       -       n       1000?   1       tlsmgr
rewrite   unix  -       -       n       -       -       trivial-rewrite
bounce    unix  -       -       n       -       0       bounce
defer     unix  -       -       n       -       0       bounce
trace     unix  -       -       n       -       0       bounce
verify    unix  -       -       n       -       1       verify
flush     unix  n       -       n       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
proxywrite unix -       -       n       -       1       proxymap
smtp      unix  -       -       n       -       -       smtp
relay     unix  -       -       n       -       -       smtp
showq     unix  n       -       n       -       -       showq
error     unix  -       -       n       -       -       error
retry     unix  -       -       n       -       -       error
discard   unix  -       -       n       -       -       discard
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       n       -       -       lmtp
anvil     unix  -       -       n       -       1       anvil
scache    unix  -       -       n       -       1       scache
EOF2

echo "postfix: listo"

# agregar postlog si no existe (requerido en Postfix moderno)
if ! grep -q "^postlog" /etc/postfix/master.cf; then
    echo "postlog  unix-dgram n  -       n       -       1       postlogd" >> /etc/postfix/master.cf
fi