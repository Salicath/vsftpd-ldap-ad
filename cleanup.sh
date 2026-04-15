#!/bin/bash
# cleanup.sh — idiot-safe teardown. Removes the service, image, config,
# and data dir so you can reinstall from scratch. Interactive confirmation.
set -u

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# Escape any dangling cwd before we start deleting things
cd "$HOME" || cd /

cat <<EOF
${YELLOW}This will REMOVE:${NC}
  - systemd user unit vsftpd.service (stop + unit file)
  - container image  localhost/vsftpd-ldap
  - running container vsftpd-ldap (if any)
  - config file      ~/ftp.env
  - data directory   ~/data/ftp (and all files inside)
  - old cruft:       ~/ldap.conf

It will NOT touch:
  - the cloned repo at ~/ftp-ldap (delete manually if you want)
  - AD or anything on the Windows DC
  - the sysctl unprivileged-port setting (it's harmless to leave)
EOF
echo
read -r -p "Type 'yes' to proceed: " answer
[ "$answer" = "yes" ] || { echo "Aborted."; exit 0; }

echo -e "${GREEN}==>${NC} Stopping service..."
systemctl --user stop vsftpd.service ftp.service 2>/dev/null || true
systemctl --user disable vsftpd.service ftp.service 2>/dev/null || true

echo -e "${GREEN}==>${NC} Removing Quadlet units..."
rm -f "$HOME/.config/containers/systemd/vsftpd.container"
rm -f "$HOME/.config/containers/systemd/ftp.container"
rm -f "$HOME/.config/containers/systemd/proftpd.container"
systemctl --user daemon-reload

echo -e "${GREEN}==>${NC} Removing containers..."
podman ps -a --format '{{.Names}}' 2>/dev/null | \
    grep -iE '^(ftp|vsftpd|proftpd)' | xargs -r podman rm -f 2>/dev/null || true

echo -e "${GREEN}==>${NC} Removing images..."
podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | \
    grep -iE '(vsftpd|proftpd|ftp-ldap)' | xargs -r podman rmi -f 2>/dev/null || true

echo -e "${GREEN}==>${NC} Removing config + data..."
rm -f "$HOME/ftp.env" "$HOME/ldap.conf"

# The data dir is mode 700 owned by the container's ftpuser subuid,
# so plain rm -rf fails with Permission denied. Use podman unshare
# to enter the user namespace where that subuid is root.
if [ -d "$HOME/data/ftp" ]; then
    podman unshare rm -rf "$HOME/data/ftp" 2>/dev/null || \
        sudo rm -rf "$HOME/data/ftp"
fi
rmdir "$HOME/data" 2>/dev/null || true

echo
echo -e "${GREEN}Clean.${NC} To reinstall:"
echo "    cd ~/ftp-ldap && ./install.sh"
