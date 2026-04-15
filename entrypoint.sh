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
chown ftpuser:ftpuser /home/vsftpd
chmod 700 /home/vsftpd

echo "launching proftpd"
exec proftpd --nodaemon --config /etc/proftpd/proftpd.conf
