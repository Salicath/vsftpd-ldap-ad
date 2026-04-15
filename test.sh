#!/bin/bash
# test.sh — smoke tests for the ftp-ldap container.
# Usage: ./test.sh              (uses ~/ftp.env's PASV_ADDRESS)
#        ./test.sh 192.168.1.13 (override host)
set -u

GREEN=$'\e[0;32m'; RED=$'\e[0;31m'; YELLOW=$'\e[1;33m'; NC=$'\e[0m'
pass() { echo "  ${GREEN}[PASS]${NC} $*"; }
fail() { echo "  ${RED}[FAIL]${NC} $*"; FAILED=1; }
warn() { echo "  ${YELLOW}[WARN]${NC} $*"; }

FAILED=0

# Resolve host: argument, then ftp.env, then default
if [ $# -ge 1 ]; then
    HOST="$1"
elif [ -f "$HOME/ftp.env" ] && grep -q '^PASV_ADDRESS=' "$HOME/ftp.env"; then
    HOST="$(grep '^PASV_ADDRESS=' "$HOME/ftp.env" | cut -d= -f2)"
else
    HOST="192.168.1.13"
fi

# AD host for error hints (separate from FTP host)
AD_HOST="$(grep '^AD_HOST=' "$HOME/ftp.env" 2>/dev/null | cut -d= -f2 || echo '<unset>')"

USER="test1"
PASS_CRED="Kode1234!"

echo
echo "ftp-ldap smoke tests — host=$HOST user=$USER"
echo "==============================================="
echo

# ---- 1. server is listening and speaks ProFTPD (retry up to 15 seconds) -----
echo "1. Server banner on port 21..."
BANNER=""
for i in $(seq 1 15); do
    BANNER=$(python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(2)
try:
    s.connect(('$HOST', 21))
    print(s.recv(200).decode('utf-8', 'replace').strip())
except Exception as e:
    print('ERROR:', e, file=sys.stderr)
    sys.exit(1)
" 2>&1) && break
    sleep 1
done

if [[ "$BANNER" == *ProFTPD* ]]; then
    pass "Banner: $BANNER"
else
    fail "No banner after 15s retry: $BANNER"
    fail "  Likely the container isn't running. Try:"
    fail "    systemctl --user status ftp-ldap.service"
    fail "    journalctl --user -u ftp-ldap.service --no-pager -n 30"
    exit 1
fi
echo

# ---- 2. positive login -------------------------------------------------------
echo "2. Can $USER log in (is a member of the AD group)..."
if curl -sS --max-time 10 --user "$USER:$PASS_CRED" "ftp://$HOST/" > /dev/null 2>&1; then
    pass "$USER authenticated and got a directory listing."
else
    fail "$USER login rejected. Possible causes:"
    fail "  - $USER is NOT in the configured AD group (check in AD Users and Computers)"
    fail "  - AD bind credentials in ~/ftp.env are wrong"
    fail "  - container can't reach the DC at $AD_HOST on port 389"
fi
echo

# ---- 3. upload --------------------------------------------------------------
echo "3. File upload works and lands on the host..."
STAMP="$(date -u +%Y%m%d-%H%M%S)"
TEST_FILE="/tmp/ftp-test-$STAMP.txt"
echo "test upload at $STAMP" > "$TEST_FILE"
if curl -sS --max-time 10 --user "$USER:$PASS_CRED" -T "$TEST_FILE" "ftp://$HOST/" 2>&1 | grep -q '^curl:'; then
    fail "Upload failed."
else
    pass "Upload completed."
fi
rm -f "$TEST_FILE"
echo

# ---- 4. filesystem lockdown --------------------------------------------------
echo "4. Local host users can't read the data directory..."
if ls -la "$HOME/data/ftp/" >/dev/null 2>&1; then
    fail "Local user CAN read $HOME/data/ftp — lockdown is OFF."
    fail "  Expected: 'Permission denied' (entrypoint.sh should chmod 700)."
else
    pass "$HOME/data/ftp is locked (Permission denied for local user). Good."
fi
echo

# ---- summary ----------------------------------------------------------------
echo "==============================================="
if [ "$FAILED" -eq 0 ]; then
    echo "${GREEN}All tests passed. Ready for exam demo.${NC}"
    exit 0
else
    echo "${RED}One or more tests failed. See above.${NC}"
    echo "Diagnostic: journalctl --user -u ftp-ldap.service --no-pager -n 50"
    exit 1
fi
