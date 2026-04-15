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
[ -f Containerfile ] && [ -f ftp-ldap.container ] || \
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
podman build -t localhost/ftp-ldap .

# --- 3. install the Quadlet unit ---------------------------------------------
QUADLET_DIR="$HOME/.config/containers/systemd"
step "Installing Quadlet unit to $QUADLET_DIR ..."
mkdir -p "$QUADLET_DIR"
cp ftp-ldap.container "$QUADLET_DIR/"

# --- 4. data directory -------------------------------------------------------
step "Ensuring data directory $HOME/data/ftp exists..."
mkdir -p "$HOME/data/ftp"

# --- 5. start the service -----------------------------------------------------
step "Starting ftp-ldap.service (systemd user unit)..."
systemctl --user daemon-reload
systemctl --user restart ftp-ldap.service

# make it survive logout
loginctl enable-linger "$USER" 2>/dev/null || true

# --- 6. verify (wait for service active AND port 21 accepting) ---------------
step "Waiting for service to start and port 21 to accept connections..."
PASV_ADDR="$(grep -E '^Environment=PASV_ADDRESS=' ftp-ldap.container | cut -d= -f3)"
PASV_ADDR="${PASV_ADDR:-192.168.1.13}"

LISTENING=0
for i in $(seq 1 20); do
    if systemctl --user is-active --quiet ftp-ldap.service; then
        if python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(2)
try:
    s.connect(('$PASV_ADDR', 21))
    b = s.recv(200).decode('utf-8', 'replace')
    sys.exit(0 if 'ProFTPD' in b else 1)
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
    echo "${GREEN}  SUCCESS — the ftp-ldap service is running.${NC}"
    echo "${GREEN}================================================${NC}"
    echo
    echo "Test it with:"
    echo "    $REPO_DIR/test.sh"
    echo
    echo "Or manually:"
    echo "    curl --user 'test1:Kode1234!' ftp://$PASV_ADDR/"
    echo
    echo "To change the AD / network configuration, edit the"
    echo "Environment= lines in ftp-ldap.container and rerun this script."
    echo
else
    echo
    warn "Service did not respond on port 21 after 20 seconds."
    warn "Last 30 log lines:"
    journalctl --user -u ftp-ldap.service --no-pager -n 30 || true
    die "Investigate the log above and rerun this script."
fi
