# ftp-ldap (ProFTPD + AD group filter) — exam-day runbook

Rootless Podman **ProFTPD** container on Rocky Linux 10. Authenticates users against Windows Active Directory via `mod_ldap` and allows login **only** to members of `CN=FTP-Brugere,OU=Sikkerhedsgrupper,DC=h3,DC=local`. Optional FTPS (TLS 1.2+) via a one-env-var flip. Runs as a systemd user unit via a Podman Quadlet.

**Status:** Tested end-to-end on 2026-04-15. Positive login, upload, negative (non-member) rejection, FTPS with TLS 1.3, filesystem lockdown — all verified. The project originally used `vsftpd`; it was migrated to ProFTPD after `vsftpd` hit a reproducible post-session segfault in this exact environment. See "History" at the bottom.

## Environment (h3.local lab)

| | Test | Prod |
|---|---|---|
| DC (LDAP) | 192.168.1.21 | 10.1.80.11 (Site A) |
| FTP host  | 192.168.1.13 | 10.2.80.11 (Site B) |

- Domain: `h3.local`, base DN `DC=h3,DC=local`
- Bind: `CN=svc-ldap,OU=Servicekonti,DC=h3,DC=local`
- Group: `CN=FTP-Brugere,OU=Sikkerhedsgrupper,DC=h3,DC=local`
- Rocky host user: `h3` (lab password `Kode1234!`)
- Data dir (bind mount): `/home/h3/data/ftp`
- Encryption layers: IPsec tunnel between Site A and Site B (at network level) + optional FTPS (at transport level)

## Install (Rocky 10, rootless)

```bash
# 1. Allow rootless bind to port 21
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=21
echo "net.ipv4.ip_unprivileged_port_start=21" | sudo tee /etc/sysctl.d/99-ftp.conf

# 2. Clone and build
sudo dnf install -y git
git clone https://github.com/Salicath/vsftpd-ldap-ad.git ftp-ldap
cd ftp-ldap
podman build -t localhost/vsftpd-ldap .

# 3. Configure (edit IPs if not 192.168.1.{13,21})
cp ftp.env.example ~/ftp.env
chmod 600 ~/ftp.env

# 4. Data dir + Quadlet
mkdir -p ~/data/ftp ~/.config/containers/systemd
cp vsftpd.container ~/.config/containers/systemd/

# 5. Start and make it survive logout
systemctl --user daemon-reload
systemctl --user start vsftpd.service
loginctl enable-linger $USER

# 6. Verify it came up
systemctl --user status vsftpd.service --no-pager
```

## Test (for the exam demo)

```bash
sudo dnf install -y curl

# POSITIVE — test1 is a member of FTP-Brugere
curl --user 'test1:Kode1234!' ftp://192.168.1.13/
# expected: directory listing

# UPLOAD
echo "hello" > /tmp/hello.txt
curl --user 'test1:Kode1234!' -T /tmp/hello.txt ftp://192.168.1.13/
ls -la ~/data/ftp/                        # file appears on the host
                                          # Note: 'Permission denied' if listed
                                          # as h3 — that's the defence in depth
                                          # (chmod 700 on the bind mount owner)

# NEGATIVE — remove test1 from FTP-Brugere in AD, then:
curl --user 'test1:Kode1234!' ftp://192.168.1.13/
# expected: curl: (67) Access denied: 530
# Enforcement is instant — no cache, no container restart required.

# (re-add test1 to the group in AD, login works again)
```

### Optional: enable FTPS (TLS)

```bash
# flip FTPS on
sed -i 's/FTPS_ENABLE=NO/FTPS_ENABLE=YES/' ~/ftp.env
systemctl --user restart vsftpd.service
sleep 3

# test with curl — -k accepts self-signed, --ssl-reqd forces AUTH TLS
curl -kv --ssl-reqd --user 'test1:Kode1234!' ftp://192.168.1.13/ 2>&1 | head -30
# expected: TLS 1.3 handshake, cert CN=ftp-ldap, 230 User test1 logged in
```

## How it works (exam talking points)

### Group filter (one-paragraph pitch)

> ProFTPD's `mod_ldap` is configured with `LDAPAuthBinds on`, which means it binds to AD as a read-only service account and does a subtree search for the user with the filter `(&(objectClass=user)(sAMAccountName=%u)(memberOf=CN=FTP-Brugere,...))`. Users who aren't in the group don't match the filter, so mod_ldap reports them as "user not found" and the login is rejected with 530. Once a user is found, ProFTPD unbinds and re-binds as the discovered user's DN with the supplied password to verify credentials. The access-control decision happens inside the directory itself — there is no group-check logic in the FTP server or PAM, just one LDAP search with a `memberOf` clause. Removing a user from the group in AD takes effect on their next login attempt, with no cache.

### Encryption (defence in depth)

| Layer | Scope | How |
|---|---|---|
| **Network (L3)** | Site A ↔ Site B cross-site traffic | IPsec tunnel — encrypts all packets between sites, regardless of application protocol |
| **Transport (L6)** | Same-site LAN traffic, admin access, non-VPN clients | FTPS via ProFTPD's `mod_tls` — TLS 1.2+ on both control and data channels (`TLSRequired on`) |

> Encryption is layered. Cross-site traffic between Site A and Site B goes through an IPsec tunnel, which encrypts at the network layer — FTP payloads are encrypted by the tunnel regardless of application protocol. For traffic that doesn't go through the tunnel (same-LAN clients, admin access), the FTP server itself terminates TLS via FTPS (ProFTPD's `mod_tls`). The cert is auto-generated self-signed for the lab; in production I would issue one from Active Directory Certificate Services — the DC at Site A can already act as a CA, so domain-joined clients would trust it without any extra configuration. No single layer is load-bearing for confidentiality.

### Design choices worth defending

- **`LDAPAuthBinds on`**: authenticates by binding as the user's DN with their password — doesn't require reading the user's password hash from LDAP (AD doesn't export those over LDAP anyway).
- **`LDAPForceDefaultUID/GID on`**: every authenticated AD user is remapped to local `ftpuser` (uid 1000). This eliminates the need for POSIX attributes (`uidNumber`, `gidNumber`, `loginShell`, `homeDirectory`) on AD users, which AD doesn't populate by default.
- **`LDAPAttr uid sAMAccountName` / `LDAPAttr gidNumber primaryGroupID`**: maps POSIX attributes to the AD attributes that actually exist. Required for `mod_ldap` to parse the search result as a valid user record even when `LDAPForceDefault*` is overriding the values.
- **`REFERRALS off` in `/etc/ldap/ldap.conf`**: disables AD referral chasing at the OpenLDAP client level. Without this, subtree searches against `DC=h3,DC=local` chase referrals to `CN=Configuration`, `DomainDnsZones`, etc. — which hang the search until timeout.
- **Bind-mount at `chmod 700` owned by container subuid**: local host users without sudo get Permission denied on `~/data/ftp/`, closing the "local shell bypass" threat path.
- **Rootless Podman via Quadlet**: port 21 is made unprivileged via sysctl; pasta forwards 21 and the PASV range into the container's network namespace. No root needed; the service runs in the user's own systemd slice.

## File inventory

| File | Purpose |
|---|---|
| `Containerfile` | `debian:trixie-slim` + `proftpd-basic` + `proftpd-mod-ldap` + `proftpd-mod-crypto` (for TLS). Also drops `REFERRALS off` into `/etc/ldap/ldap.conf`. |
| `entrypoint.sh` | `envsubst`s the config template, chowns the bind mount to `ftpuser:ftpuser` (mode 700), generates a self-signed cert if `FTPS_ENABLE=YES`, execs `proftpd --nodaemon` |
| `proftpd.conf.tmpl` | All runtime config: LDAP server + filter + attribute mappings + force-default UID/GID + passive port range |
| `vsftpd.container` | Quadlet unit (historical name — the container actually runs proftpd). Pulls secrets from `EnvironmentFile=%h/ftp.env` |
| `ftp.env.example` | Copy to `~/ftp.env`, edit if IPs differ |

## Debug checklist

1. **`systemctl --user status vsftpd.service` failed** → `journalctl --user -u vsftpd.service --no-pager -n 50` — the proftpd error is usually a syntax problem in the rendered `/etc/proftpd/proftpd.conf`. `podman exec vsftpd-ldap cat /etc/proftpd/proftpd.conf` shows the rendered version.
2. **Client connects but gets "Login incorrect"** → check `podman exec vsftpd-ldap cat /root/proftpd-ldap.log` (if LDAPLog is enabled) for the actual LDAP search operation and result. Temporarily re-add `LDAPLog /root/proftpd-ldap.log` to the config if it's been removed.
3. **Group member is rejected** → the group DN in `ftp.env` must exactly match the AD X500 DN. Copy from AD Users & Computers → the group → Attribute Editor → `distinguishedName`.
4. **Nested AD groups** → swap the filter in `proftpd.conf.tmpl` from `memberOf=` to `memberOf:1.2.840.113556.1.4.1941:=` and rebuild.
5. **PASV data channel hangs but control channel works** → `PASV_ADDRESS` in `ftp.env` must be the IP the client uses to reach this host, not a container-internal address.
6. **FTPS fails with `response reading failed (errno 115)`** → mod_tls isn't loaded. Verify with `podman exec vsftpd-ldap grep -c tls /etc/proftpd/modules.conf` and confirm `proftpd-mod-crypto` is installed.

## History (what NOT to re-explore)

- **Original attempt with `docker.io/undying/vsftpd`** — uses old `libpam-ldap` with a broken `default=ignore` PAM stack. Group filtering is silently ignored regardless of `LDAP_FILTER`, `pam_filter`, `pam_groupdn`. Six config variants tried, all failed.
- **Custom `vsftpd` + `libpam-ldapd` + `nslcd`** — the nslcd `filter passwd memberOf=` trick worked for auth, but **vsftpd itself segfaulted on every session teardown** in this kernel/glibc/rootless-podman environment. Reproducible in both Debian 12's vsftpd 3.0.3 and Debian 13's 3.0.5, same code offset. Tried: `one_process_model=YES` (anonymous-only, rejected), `seccomp_sandbox` toggles, stripping every optional feature (`hide_ids`, `virtual_use_local_privs`, `text_userdb_names`, `check_shell`), `Restart=always` with aggressive intervals. Crash never went away.
- **Pivot to ProFTPD** — clean win. `mod_ldap` does AD group filtering natively via the `LDAPUsers` filter template. No nslcd, no PAM surgery, no segfaults. The vsftpd attempt lives on in branch `vsftpd-legacy` if the code is ever useful as a reference for the nslcd technique.

**Do not spend time re-trying any vsftpd configuration.** The path forward is ProFTPD or (if ProFTPD ever fails) Pure-FTPd.
