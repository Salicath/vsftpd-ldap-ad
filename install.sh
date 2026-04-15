#!/bin/bash
# install.sh — idiot-safe installer for the ftp-ldap container.
# Run this from inside the cloned repo directory. No arguments.
set -euo pipefail

GREEN=$'\e[0;32m'; YELLOW=$'\e[1;33m'; RED=$'\e[0;31m'; NC=$'\e[0m'
step() { echo "${GREEN}==>${NC} $*"; }
warn() { echo "${YELLOW}!!${NC} $*"; }
die()  { echo "${RED}XX${NC} $*" >&2; exit 1; }

# --- preconditions -----------------------------------------------------------
[ "$EUID" -eq 0 ] && die "Run as a normal user, not root. Rootless podman only."
command -v podman    >/dev/null || die "podman not found. Install it: sudo dnf install -y podman"
command -v systemctl >/dev/null || die "systemctl not found. Is this systemd?"

# must be run from inside the cloned repo
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"
[ -f Containerfile ] && [ -f vsftpd.container ] || \
    die "Run this from inside the cloned ftp-ldap repo directory."

# --- 1. unprivileged port 21 --------------------------------------------------
CURRENT_PORT_START=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)
if [ "$CURRENT_PORT_START" -gt 21 ]; then
    step "Lowering unprivileged port floor to 21 (needs sudo, one time)..."
    sudo sysctl -w net.ipv4.ip_unprivileged_port_start=21
    echo "net.ipv4.ip_unprivileged_port_start=21" | \
        sudo tee /etc/sysctl.d/99-ftp.conf > /dev/null
else
    step "Port 21 already unprivileged. Good."
fi

# --- 2. build the container image --------------------------------------------
step "Building container image (first build downloads ~30 MB of packages)..."
podman build -t localhost/vsftpd-ldap .

# --- 3. config file -----------------------------------------------------------
if [ ! -f "$HOME/ftp.env" ]; then
    step "Creating $HOME/ftp.env from template..."
    cp ftp.env.example "$HOME/ftp.env"
    chmod 600 "$HOME/ftp.env"
    warn "Defaults assume the h3.local lab. If your DC/host IPs differ,"
    warn "edit $HOME/ftp.env now and rerun this script."
else
    step "$HOME/ftp.env already exists — leaving it alone."
fi

# --- 4. data directory --------------------------------------------------------
step "Ensuring data directory $HOME/data/ftp exists..."
mkdir -p "$HOME/data/ftp"

# --- 5. Quadlet unit ----------------------------------------------------------
step "Installing Quadlet unit to $HOME/.config/containers/systemd/ ..."
mkdir -p "$HOME/.config/containers/systemd"
cp vsftpd.container "$HOME/.config/containers/systemd/"

# --- 6. start the service -----------------------------------------------------
step "Starting vsftpd.service (systemd user unit)..."
systemctl --user daemon-reload
systemctl --user restart vsftpd.service

# make it survive logout
loginctl enable-linger "$USER" 2>/dev/null || true

# --- 7. verify (wait for service active AND port 21 accepting) ---------------
step "Waiting for service to start and port 21 to accept connections..."
PASV_ADDR="$(grep '^PASV_ADDRESS=' "$HOME/ftp.env" | cut -d= -f2 | tr -d '"' 2>/dev/null || echo 192.168.1.13)"

LISTENING=0
for i in $(seq 1 20); do
    if systemctl --user is-active --quiet vsftpd.service; then
        if python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(2)
try:
    s.connect(('$PASV_ADDR', 21))
    b = s.recv(200).decode('utf-8', 'replace')
    sys.exit(0 if 'ProFTPD' in b or 'vsFTP' in b else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
            LISTENING=1
            break
        fi
    fi
    sleep 1
done

if [ "$LISTENING" -eq 1 ]; then
    echo
    echo "${GREEN}================================================${NC}"
    echo "${GREEN}  SUCCESS — the FTP service is running.${NC}"
    echo "${GREEN}================================================${NC}"
    echo
    echo "Test it with:"
    echo "    $REPO_DIR/test.sh"
    echo
    echo "Or manually:"
    echo "    curl --user 'test1:Kode1234!' ftp://$PASV_ADDR/"
    echo
else
    echo
    warn "Service did not respond on port 21 after 20 seconds."
    warn "Last 30 log lines:"
    journalctl --user -u vsftpd.service --no-pager -n 30 || true
    die "Investigate the log above and rerun this script."
fi
