#!/bin/bash
# Crea cuentas de correo en archivo de usuarios de Dovecot

set -e

echo "accounts: verificando variables"

if [ -z "$MAIL_USER1" ] || [ -z "$MAIL_PASS1" ]; then
    echo "accounts: ERROR - MAIL_USER1 o MAIL_PASS1 no definidos"
    exit 1
fi

if [ -z "$MAIL_USER2" ] || [ -z "$MAIL_PASS2" ]; then
    echo "accounts: ERROR - MAIL_USER2 o MAIL_PASS2 no definidos"
    exit 1
fi

# usuario del sistema para entrega virtual
if ! id vmail > /dev/null 2>&1; then
    useradd -u 1000 -d /var/mail -s /sbin/nologin vmail
fi

mkdir -p /var/mail
chown vmail:vmail /var/mail

USERS_FILE=/etc/dovecot/users
> "$USERS_FILE"

create_account() {
    local USER=$1
    local PASS=$2
    local EMAIL="${USER}@${MAIL_DOMAIN}"
    local MAILDIR=/var/mail/${USER}/Maildir

    echo "accounts: creando $EMAIL"

    local HASH
    HASH=$(doveadm pw -s SHA512-CRYPT -p "$PASS")

    # formato: email:hash:uid:gid::home:
    echo "${EMAIL}:${HASH}:1000:1000::/var/mail/${USER}:" >> "$USERS_FILE"

    mkdir -p "${MAILDIR}"/{cur,new,tmp}
    for folder in Drafts Sent Junk Trash; do
        mkdir -p "${MAILDIR}/.${folder}"/{cur,new,tmp}
    done

    chown -R vmail:vmail "/var/mail/${USER}"
    chmod -R 700 "/var/mail/${USER}"

    echo "accounts: $EMAIL listo"
}

create_account "$MAIL_USER1" "$MAIL_PASS1"
create_account "$MAIL_USER2" "$MAIL_PASS2"

chmod 640 "$USERS_FILE"
chown root:dovecot "$USERS_FILE" 2>/dev/null || chmod 640 "$USERS_FILE"

echo "accounts: listo"