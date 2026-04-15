#!/bin/bash
# cleanup.sh — idiot-safe teardown. Removes the service, image, and
# data dir so you can reinstall from scratch. Interactive confirmation.
set -u

GREEN=$'\e[0;32m'; YELLOW=$'\e[1;33m'; RED=$'\e[0;31m'; NC=$'\e[0m'

# Escape any dangling cwd before we start deleting things
cd "$HOME" || cd /

cat <<EOF
${YELLOW}This will REMOVE:${NC}
  - systemd user unit ftp-ldap.service (stop + unit file)
  - container image  localhost/ftp-ldap
  - running container ftp-ldap (if any)
  - data directory   ~/data/ftp (and all files inside)
  - old cruft:       ~/ftp.env, ~/ldap.conf, old vsftpd.container

It will NOT touch:
  - the cloned repo at ~/ftp-ldap (delete manually if you want)
  - AD or anything on the Windows DC
  - the sysctl unprivileged-port setting (harmless to leave)
EOF
echo
read -r -p "Type 'yes' to proceed: " answer
[ "$answer" = "yes" ] || { echo "Aborted."; exit 0; }

echo "${GREEN}==>${NC} Stopping services..."
systemctl --user stop ftp-ldap.service vsftpd.service ftp.service 2>/dev/null || true
systemctl --user disable ftp-ldap.service vsftpd.service ftp.service 2>/dev/null || true

echo "${GREEN}==>${NC} Removing Quadlet units..."
rm -f "$HOME/.config/containers/systemd/ftp-ldap.container"
rm -f "$HOME/.config/containers/systemd/vsftpd.container"
rm -f "$HOME/.config/containers/systemd/ftp.container"
rm -f "$HOME/.config/containers/systemd/proftpd.container"
systemctl --user daemon-reload

echo "${GREEN}==>${NC} Removing containers..."
podman ps -a --format '{{.Names}}' 2>/dev/null | \
    grep -iE '^(ftp|vsftpd|proftpd)' | xargs -r podman rm -f 2>/dev/null || true

echo "${GREEN}==>${NC} Removing images..."
podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | \
    grep -iE '(vsftpd|proftpd|ftp-ldap)' | xargs -r podman rmi -f 2>/dev/null || true

echo "${GREEN}==>${NC} Removing stale files from earlier setups..."
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
echo "${GREEN}Clean.${NC} To reinstall:"
echo "    cd ~/ftp-ldap && ./install.sh"
