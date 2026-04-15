#!/bin/bash
# install.sh — idiot-safe installer for the ftp-ldap container.
# Run this from inside the cloned repo directory. No arguments.
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}!!${NC} $*"; }
die()  { echo -e "${RED}XX${NC} $*" >&2; exit 1; }

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

# --- 7. verify ----------------------------------------------------------------
sleep 3
if systemctl --user is-active --quiet vsftpd.service; then
    echo
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}  SUCCESS — the FTP service is running.${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo
    echo "Test it with:"
    echo "    $REPO_DIR/test.sh"
    echo
    echo "Or manually:"
    echo "    curl --user 'test1:Kode1234!' ftp://192.168.1.13/"
    echo
else
    echo
    warn "Service failed to start. Last 30 log lines:"
    journalctl --user -u vsftpd.service --no-pager -n 30 || true
    die "Investigate the log above and rerun this script."
fi
