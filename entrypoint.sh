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

envsubst '${AD_HOST} ${AD_BASE_DN} ${AD_BIND_DN} ${AD_BIND_PW} ${AD_GROUP_DN}' \
    < /etc/nslcd.conf.tmpl > /etc/nslcd.conf
chown root:root /etc/nslcd.conf
chmod 600 /etc/nslcd.conf

envsubst '${PASV_ADDRESS} ${PASV_MIN_PORT} ${PASV_MAX_PORT}' \
    < /etc/vsftpd.conf.tmpl > /etc/vsftpd.conf

install -d -o nslcd -g nslcd -m 755 /var/run/nslcd
install -d -o root  -g root  -m 755 /var/run/vsftpd/empty

# Lock the bind-mounted data dir so local host users without sudo can't
# bypass the AD group filter by reading files directly off disk.
chown ftpuser:ftpuser /home/vsftpd
chmod 700 /home/vsftpd

# Optional FTPS: enabled by setting FTPS_ENABLE=YES in ftp.env.
# Uses a mounted cert at /etc/vsftpd/vsftpd.pem if present, otherwise
# auto-generates a self-signed one (valid for the lab / dev; replace
# with a CA-issued cert in production by mounting a real vsftpd.pem).
if [ "${FTPS_ENABLE:-NO}" = "YES" ]; then
    install -d -o root -g root -m 755 /etc/vsftpd
    CERT=/etc/vsftpd/vsftpd.pem
    if [ ! -f "$CERT" ]; then
        echo "FTPS: no cert mounted, generating self-signed"
        openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
            -keyout "$CERT" -out "$CERT" \
            -subj "/CN=vsftpd-ldap-ad" >/dev/null 2>&1
        chmod 600 "$CERT"
    else
        echo "FTPS: using mounted cert at $CERT"
    fi
    cat >> /etc/vsftpd.conf <<EOF

ssl_enable=YES
rsa_cert_file=$CERT
rsa_private_key_file=$CERT
allow_anon_ssl=NO
force_local_data_ssl=YES
force_local_logins_ssl=YES
ssl_tlsv1_2=YES
ssl_tlsv1=NO
ssl_sslv2=NO
ssl_sslv3=NO
require_ssl_reuse=NO
ssl_ciphers=HIGH:!aNULL:!MD5
EOF
fi

nslcd

echo "nslcd started; launching vsftpd"
exec vsftpd /etc/vsftpd.conf
