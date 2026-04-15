# vsftpd with AD group filter — exam-day runbook

Rootless Podman vsftpd on Rocky Linux 10. Authenticates users against Windows Active Directory via LDAP and allows login **only** for members of `CN=FTP-Brugere,OU=Sikkerhedsgrupper,DC=h3,DC=local`. Data persists to a host bind mount. Runs as a systemd user unit via a Podman Quadlet.

**Status:** tested end-to-end on 2026-04-15. Positive login, file upload, and negative (non-member) rejection all verified. Group removal in AD is enforced instantly on the next login — no caching, no container restart needed.

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

# NEGATIVE — remove test1 from FTP-Brugere in AD, then:
curl --user 'test1:Kode1234!' ftp://192.168.1.13/
# expected: curl: (67) Access denied: 530

# (re-add test1 to the group in AD, login works again)
```

## How the group filter works (one-paragraph pitch)

> vsftpd's PAM service (`/etc/pam.d/vsftpd`) has `account required pam_ldap.so`. That module (from `libpam-ldapd`) delegates every PAM lookup to the `nslcd` daemon over a Unix socket. `nslcd.conf` contains `filter passwd (&(objectClass=user)(memberOf=CN=FTP-Brugere,...))`, which nslcd applies on every query. Users who are not in the group are simply not returned by nslcd, so PAM reports `PAM_USER_UNKNOWN`, so vsftpd sends `530 Login incorrect`. No group-check logic in PAM itself — the access decision happens inside nslcd at the directory level.

Key tricks:
- **`guest_enable=YES` + `guest_username=ftpuser`** — every authenticated AD user is remapped to a single local user (`ftpuser`, uid 1000). No per-user uid mapping, no AD POSIX attributes needed.
- **`map passwd uidNumber primaryGroupID`** — nslcd needs to return *some* numeric uid to satisfy NSS. `primaryGroupID` is always `513` for domain users; the value is irrelevant because vsftpd throws it away on the remap.
- **Rootless Podman**: port 21 is made unprivileged via sysctl; pasta forwards 21 and 50000-50100 from the host netns to the container.
- **Defense in depth (filesystem)**: `entrypoint.sh` chowns `/home/vsftpd` (the bind mount) to `ftpuser` and chmods it `700` at every container start. Local host users without sudo get `Permission denied` on `~/data/ftp/`, so they can't bypass the AD group filter by reading files directly off disk.
- **Optional FTPS (TLS)**: flip `FTPS_ENABLE=YES` in `~/ftp.env` and restart. The entrypoint auto-generates a self-signed cert if none is mounted, or uses a CA-issued cert from `~/certs/vsftpd.pem` if the volume mount line in the Quadlet is uncommented.

## Encryption story (exam talking points)

Two independent layers, each covering a different threat path:

| Layer | Scope | How |
|---|---|---|
| **Network (L3)** | Cross-site traffic between Site A and Site B | IPsec tunnel — encrypts all packets between the two sites at the IP layer, regardless of application protocol |
| **Transport (L6)** | Same-site LAN traffic, admin access, any traffic not crossing the tunnel | FTPS (`FTPS_ENABLE=YES`) — vsftpd terminates TLS on the control and data channels |

> "Encryption is layered. Cross-site traffic between Site A and Site B goes through an IPsec tunnel, which encrypts at the network layer — FTP payloads are encrypted by the tunnel regardless of application protocol. For traffic that doesn't go through the tunnel (same-LAN clients on Site A, admin access, any future non-VPN clients), the FTP server itself terminates TLS via FTPS with an auto-generated self-signed cert. For production, I would mount a cert issued by Active Directory Certificate Services — the DC at Site A is already capable of being a CA, so domain-joined clients would trust it with zero configuration. No single layer is load-bearing for confidentiality; this is defense in depth."

**Should you enable FTPS for the exam demo?**

- **Yes, flip `FTPS_ENABLE=YES`**, even with the self-signed cert. The cert warning becomes a 10-second talking point ("self-signed for the lab; production would use AD CS"), and you get a full encryption story instead of having to defend plain FTP.
- **If you don't** (e.g., you want to keep the demo simpler), the IPsec-at-the-network-layer answer is still defensible for Site A ↔ Site B traffic. You would be weaker on "what about same-LAN sniffing?" but you can say "Site A's internal LAN is a trusted segment; local-LAN confidentiality is out of scope for this project."
- The one env var toggle means you can literally decide at the last minute and restart the service in ~2 seconds.

After enabling, test with:
```bash
curl -k --ftp-ssl --user 'test1:Kode1234!' ftp://192.168.1.13/
# -k accepts the self-signed cert
```

## File inventory

| File | Purpose |
|---|---|
| `Containerfile` | `debian:12-slim` + `vsftpd` + `libpam-ldapd` (nslcd is a dependency) |
| `entrypoint.sh` | `envsubst`s the two templates, starts `nslcd`, execs `vsftpd` in foreground |
| `nslcd.conf.tmpl` | The one that matters — `filter passwd memberOf=...` + primaryGroupID map |
| `vsftpd.conf.tmpl` | `guest_enable=YES`, passive 50000-50100, `seccomp_sandbox=NO` |
| `pam.vsftpd` | 3 lines, all `required`, no `default=ignore` |
| `vsftpd.container` | Quadlet unit, pulls secrets from `EnvironmentFile=%h/ftp.env` |
| `ftp.env.example` | Copy to `~/ftp.env`, edit if IPs differ |

## Debug checklist

1. **`systemctl --user status vsftpd.service` failed, restarting in a loop** → `journalctl --user -u vsftpd.service --no-pager -n 50` will show the actual error. `nslcd: bind failed` → bad `AD_BIND_DN`/`AD_BIND_PW` in `ftp.env`.
2. **`lftp`/`curl` hangs then says `Delaying before reconnect`** → port 21 not listening, or vsftpd died immediately. `ss -tln | grep :21` + `python3 -c "import socket; s=socket.socket(); s.connect(('192.168.1.13',21)); print(s.recv(200).decode())"` will show the banner or the real error.
3. **Group member is rejected** → the group DN in `ftp.env` must exactly match the AD X500 DN. Copy from AD Users & Computers → user → Attribute Editor → `memberOf` → that entry's `distinguishedName`.
4. **Nested AD groups** → swap the filter in `nslcd.conf.tmpl` for `(memberOf:1.2.840.113556.1.4.1941:=CN=FTP-Brugere,...)` and rebuild.
5. **PASV data connection hangs but control channel works** → `PASV_ADDRESS` in `ftp.env` must be the IP the client uses to reach this host, not a container-internal address.
6. **`vsftpd: segfault` in dmesg after a successful transfer** → cosmetic. Debian's vsftpd 3.0.3 crashes a child worker on session teardown in some kernels. The transfer and file are fine.

## Things NOT to try (already failed during development)

- **`docker.io/undying/vsftpd`** — uses old `libpam-ldap` with `[success=1 default=ignore]` in the PAM account stack. Group filtering is silently bypassed. No amount of `LDAP_FILTER`, `pam_filter`, `pam_groupdn` tweaking fixes it.
- **`joharper54SEG/Docker-vsftp-ldap`** — Ubuntu 18.04 (EOL), vendors an ancient confd binary, *requires* AD users to have POSIX attributes (`uidNumber`, `loginShell`) which h3.local does not populate.
- **`objectSid` mapping for uidNumber** — works, but adds an `AD_DOMAIN_SID` env var that has to be looked up with PowerShell or a binary LDAP decode. `primaryGroupID` is simpler and equally correct here.
- **`vsftpd_log_file=/dev/stdout`** — vsftpd dies with `500 OOPS: failed to open vsftpd log file` on the first connection. Use defaults (no custom log file).

## Fallbacks if the whole approach collapses

1. **`instantlinux/proftpd`** — ProFTPD's `mod_ldap` has native `<Limit LOGIN><AllowGroup>` and `LDAPGroups`. Cleaner config, smaller image.
2. **`stilliard/pure-ftpd`** — `LDAPFilter "(memberOf=...)"` in a mounted `pureftpd-ldap.conf`.
