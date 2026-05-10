#!/bin/bash
# Configura fail2ban

set -e

F2B_DIR=/etc/fail2ban

echo "fail2ban: configurando jail.local"

cat > "$F2B_DIR/jail.local" << 'JAILCONF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = polling
action   = %(action_)s

[dovecot]
enabled  = true
port     = imap,imaps,submission
filter   = dovecot
logpath  = /var/log/dovecot-info.log
maxretry = 5
backend  = polling
JAILCONF

echo "fail2ban: configurando filtro dovecot"

mkdir -p "$F2B_DIR/filter.d"

cat > "$F2B_DIR/filter.d/dovecot.conf" << 'FILTERCONF'
[Definition]
failregex = auth\(.*,<HOST>,sasl:.*\).*Password mismatch
            imap-login:.*Login aborted.*rip=<HOST>
ignoreregex =
FILTERCONF

if ! command -v iptables > /dev/null 2>&1; then
    cat > "$F2B_DIR/action.d/log-only.conf" << 'ACTIONCONF'
[Definition]
actionban  = echo "fail2ban: bloqueando <ip>" >> /var/log/fail2ban-blocks.log
actionunban = echo "fail2ban: desbloqueando <ip>" >> /var/log/fail2ban-blocks.log
ACTIONCONF
    sed -i 's/action   = %(action_)s/action   = log-only/' "$F2B_DIR/jail.local"
fi

mkdir -p /var/run/fail2ban

echo "fail2ban: listo"
touch /var/log/dovecot-info.log