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

nslcd

echo "nslcd started; launching vsftpd"
exec vsftpd /etc/vsftpd.conf
