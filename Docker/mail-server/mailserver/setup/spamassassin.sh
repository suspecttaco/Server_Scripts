#!/bin/bash
# Configura SpamAssassin como filtro de spam via procmail

set -e

echo "spamassassin: configurando local.cf"

cat > /etc/mail/spamassassin/local.cf << 'SA'
required_score 5.0
report_safe 0
rewrite_header Subject [SPAM]
add_header all Status _YESNO_, score=_SCORE_ required=_REQD_
SA

echo "spamassassin: configurando procmailrc global"

cat > /etc/procmailrc << 'PM'
DROPPRIVS=YES
:0fw
| /usr/bin/spamc
:0e
{
    EXITCODE=$?
}
PM

echo "spamassassin: actualizando reglas"
sa-update --nogpg 2>/dev/null || true

mkdir -p /var/run/spamd
chown spamd:spamd /var/run/spamd 2>/dev/null || true

echo "spamassassin: listo"