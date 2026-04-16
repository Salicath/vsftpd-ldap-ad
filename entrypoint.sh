#!/bin/bash
set -euo pipefail

req() { [ -n "${!1:-}" ] || { echo "ERROR: env var $1 is required" >&2; exit 1; }; }
req AD_HOST
req AD_BASE_DN
req AD_BIND_DN
req AD_BIND_PW
req AD_GROUP_DN
req PASV_ADDRESS
: "${PASV_MIN_PORT:=50000}"
: "${PASV_MAX_PORT:=50100}"
export PASV_MIN_PORT PASV_MAX_PORT

envsubst '${AD_HOST} ${AD_BASE_DN} ${AD_BIND_DN} ${AD_BIND_PW} ${AD_GROUP_DN} ${PASV_ADDRESS} ${PASV_MIN_PORT} ${PASV_MAX_PORT}' \
    < /etc/proftpd/proftpd.conf.tmpl > /etc/proftpd/proftpd.conf
chown root:root /etc/proftpd/proftpd.conf
chmod 600 /etc/proftpd/proftpd.conf

# Lock the bind-mounted data dir so local host users without sudo
# can't bypass the AD group filter by reading files directly off disk.
chown ftpuser:ftpuser /srv/ftp
chmod 700 /srv/ftp

# Optional FTPS: enable by setting FTPS_ENABLE=YES in ftp-ldap.container.
# Uses a mounted cert at /etc/proftpd/ssl/proftpd.pem if present,
# otherwise auto-generates a self-signed one. Replace with a CA-issued
# cert in production by mounting a real proftpd.pem via the Quadlet.
if [ "${FTPS_ENABLE:-NO}" = "YES" ]; then
    install -d -o root -g root -m 755 /etc/proftpd/ssl
    CERT=/etc/proftpd/ssl/proftpd.pem
    if [ ! -f "$CERT" ]; then
        echo "FTPS: no cert mounted, generating self-signed"
        openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
            -keyout "$CERT" -out "$CERT" \
            -subj "/CN=ftp-ldap" >/dev/null 2>&1
        chmod 600 "$CERT"
    else
        echo "FTPS: using mounted cert at $CERT"
    fi
    cat >> /etc/proftpd/proftpd.conf <<EOF

<IfModule mod_tls.c>
  TLSEngine              on
  TLSRequired            on
  TLSProtocol            TLSv1.2 TLSv1.3
  TLSRSACertificateFile  $CERT
  TLSRSACertificateKeyFile $CERT
  TLSOptions             NoSessionReuseRequired
  TLSVerifyClient        off
</IfModule>
EOF
fi

echo "launching proftpd"
exec proftpd --nodaemon --config /etc/proftpd/proftpd.conf
