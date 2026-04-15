# ftp-ldap

**Rootless Podman FTP container with real Active Directory group-membership access control and optional FTPS.**

> **In a hurry? See [QUICKSTART.md](QUICKSTART.md)** — copy-paste install, test, and demo in under 5 minutes. No Linux expertise required.

A minimal `debian:trixie-slim` container running [ProFTPD](http://www.proftpd.org/) with `mod_ldap`, authenticating against a Windows Active Directory and **restricting login to members of a single AD group**. Designed to run rootless under Podman as a systemd Quadlet on modern Linux hosts.

> **About the GitHub repo name:** this project is hosted at `github.com/Salicath/vsftpd-ldap-ad` for historical reasons — it started life as a vsftpd build. The working implementation is now ProFTPD; all current files, paths, and service names use `ftp-ldap`. See "History" at the bottom if you're curious.

~60 MB image. ~80 lines of config across 5 files. No POSIX attributes required on your AD users. Group filter is enforced inside the directory, not in PAM or NSS.

---

## Why this exists

If you've tried to get Dockerised FTP + LDAP working with a "members of group X only" restriction against Active Directory, you've probably hit one of these walls:

| Project | Problem |
|---|---|
| [`docker.io/undying/vsftpd`](https://hub.docker.com/r/undying/vsftpd) | Uses legacy `libpam-ldap`, whose PAM account stack has `[success=1 default=ignore]` for `pam_ldap.so`. Group denials are silently dropped. No combination of `LDAP_FILTER`, `pam_filter` or `pam_groupdn` fixes this. |
| [`joharper54SEG/Docker-vsftp-ldap`](https://github.com/joharper54SEG/Docker-vsftp-ldap) | Ubuntu 18.04 (EOL), vendors an ancient `confd` binary, and requires AD users to have POSIX attributes populated. |
| A custom vsftpd + `libpam-ldapd` + nslcd build | Works for auth on paper, but **vsftpd segfaults on post-session cleanup** in modern kernels (reproducible in both Debian bookworm's 3.0.3 and trixie's 3.0.5). This repo's git history contains the full diagnostic journey. |

**ProFTPD's `mod_ldap` solves the problem cleanly**: AD group membership is checked as part of the user-search filter directly against the directory. Non-members simply don't match, so there's no "login denied" code path in the FTP server itself — the search returns nothing, and ProFTPD reports "user not found." No nslcd tricks, no broken PAM modules, no segfaults.

---

## Features

- ✅ **Active Directory authentication** via ProFTPD `mod_ldap` (no nslcd, no PAM surgery)
- ✅ **True group-based access control** — non-members receive `530 Login incorrect`, enforced at the LDAP search level
- ✅ **Instant enforcement** — removing a user from the group in AD rejects their next login with no cache
- ✅ **No AD schema changes** — works with stock AD; no POSIX attributes (`uidNumber`, `loginShell`, `homeDirectory`) required on users
- ✅ **Optional FTPS (TLS 1.2+)** — one env var flip; auto-generates a self-signed cert for dev/lab, or mount a CA-issued cert (e.g. from Active Directory Certificate Services)
- ✅ **Rootless Podman** — runs under a normal user, managed by `systemd --user` via a Quadlet
- ✅ **Defence in depth** — bind-mounted data dir is auto-locked to `chmod 700` owned by the container's subuid, so local host users without sudo can't bypass the network-level ACL
- ✅ **Passive FTP mode** — configurable PASV port range and advertised address (for NAT)
- ✅ **Nested group support** — documented one-line change for AD `LDAP_MATCHING_RULE_IN_CHAIN` if the FTP group contains subgroups

---

## Quick start

### Prerequisites

- Linux host with `podman` ≥ 4.4 and `systemd --user` (tested on Rocky Linux 10; also works on Fedora, Debian 12+, Ubuntu 22.04+)
- Network reachability from the host to your AD/LDAP server on port 389
- A read-only bind account in AD (a normal, unprivileged domain user is enough)
- An AD security group whose members you want to allow
- Rootless binding to port 21 enabled on the host (see below)

### One-time host setup

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=21
echo "net.ipv4.ip_unprivileged_port_start=21" | sudo tee /etc/sysctl.d/99-ftp.conf
```

### Install

```bash
git clone https://github.com/Salicath/vsftpd-ldap-ad.git ftp-ldap
cd ftp-ldap
podman build -t localhost/ftp-ldap .

# Configure
cp ftp.env.example ~/ftp.env
chmod 600 ~/ftp.env
$EDITOR ~/ftp.env        # set AD_HOST, DNs, PASV_ADDRESS — see below

# Data directory (bind-mounted into the container)
mkdir -p ~/data/ftp

# Install and start the Quadlet
mkdir -p ~/.config/containers/systemd
cp ftp-ldap.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start ftp-ldap.service

# Make it survive logout
loginctl enable-linger $USER
```

Verify:
```bash
systemctl --user status ftp-ldap.service --no-pager
```

---

## Configuration

All runtime configuration lives in `~/ftp.env`. Nothing goes in the Quadlet unit or the image.

| Variable | Example | Description |
|---|---|---|
| `AD_HOST` | `192.168.1.21` | LDAP host or IP of your AD domain controller |
| `AD_BASE_DN` | `DC=example,DC=local` | Search base for user lookups |
| `AD_BIND_DN` | `CN=svc-ldap,OU=Service,DC=example,DC=local` | DN of the account used to bind to AD (read-only is enough) |
| `AD_BIND_PW` | `secret` | Bind account password |
| `AD_GROUP_DN` | `CN=FTP-Users,OU=Groups,DC=example,DC=local` | **Exact DN** of the AD group whose members may log in. Copy from AD Users & Computers → Attribute Editor → `distinguishedName`. |
| `PASV_ADDRESS` | `192.168.1.13` | The IP that FTP clients use to reach this host. Must be routable from clients — not a container-internal address. |
| `PASV_MIN_PORT` | `50000` | Lower bound of passive-mode port range |
| `PASV_MAX_PORT` | `50100` | Upper bound of passive-mode port range |
| `FTPS_ENABLE` | `NO` / `YES` | Enable TLS on the control and data channels (explicit FTPS). See below. |

### Enabling FTPS (TLS)

Set `FTPS_ENABLE=YES` in `~/ftp.env` and restart the service. The entrypoint will:

1. Check for a mounted cert at `/etc/proftpd/ssl/proftpd.pem` (see Quadlet comment for the volume mount line).
2. If no cert is mounted, auto-generate a self-signed one at container startup. Fine for labs, dev, or any environment where the TLS config itself needs to be demonstrable but the cert's trust anchor isn't critical.
3. Append a TLS block to `/etc/proftpd/proftpd.conf` — forces TLS on both control and data channels (`TLSRequired on`), TLS 1.2 / 1.3 only.

After enabling, clients must use **explicit FTPS** (the `AUTH TLS` command on the control channel). Examples:

```bash
curl -k --ssl-reqd --user 'alice:password' ftp://ftp.example.local/   # -k accepts self-signed
lftp -u alice,password -e 'set ftp:ssl-force yes; ls; bye' ftp.example.local
```

In FileZilla: **Protocol: FTP → Encryption: Require explicit FTP over TLS**.

**To use a CA-issued cert instead of the auto-generated one** (recommended for production):

1. Put your cert+key concatenated in one PEM file at `~/certs/proftpd.pem` on the host
2. `chmod 600 ~/certs/proftpd.pem`
3. Uncomment the `Volume=...proftpd.pem...` line in `~/.config/containers/systemd/ftp-ldap.container`
4. `systemctl --user daemon-reload && systemctl --user restart ftp-ldap.service`

Internal enterprise deployments typically issue this cert from **Active Directory Certificate Services** (free, included with Windows Server), so domain-joined clients automatically trust it with no cert warnings.

### For nested AD groups

Active Directory `memberOf` does not traverse nested groups by default. If your FTP group contains other groups (rather than users directly), edit `proftpd.conf.tmpl` and swap:

```
LDAPUsers "${AD_BASE_DN}" "(&(objectClass=user)(sAMAccountName=%u)(memberOf=${AD_GROUP_DN}))" ...
```

for:

```
LDAPUsers "${AD_BASE_DN}" "(&(objectClass=user)(sAMAccountName=%u)(memberOf:1.2.840.113556.1.4.1941:=${AD_GROUP_DN}))" ...
```

That OID is `LDAP_MATCHING_RULE_IN_CHAIN` — it instructs the DC to walk the group hierarchy transitively. Rebuild the image after changing the template.

---

## How it works

### The access-control flow

1. Client connects to ProFTPD on port 21.
2. Client sends `USER <name>` / `PASS <password>`.
3. `mod_ldap` (configured with `LDAPAuthBinds on`) binds to AD as the read-only service account and runs a subtree search with the filter:
   ```
   (&(objectClass=user)(sAMAccountName=<name>)(memberOf=CN=FTP-Users,...))
   ```
4. **If the user isn't in the group, the filter doesn't match, the search returns nothing, and ProFTPD sends `530 Login incorrect`.**
5. If the filter does match, ProFTPD takes the returned DN, unbinds, and re-binds as that DN with the user-supplied password. Successful bind = authenticated.
6. `LDAPForceDefaultUID/GID on` maps every authenticated AD user to local `ftpuser` (uid 1000). The session chroots into `/srv/ftp`, which is bind-mounted to `~/data/ftp` on the host.

The access decision happens in the LDAP search — there's no group-membership logic in the FTP server or PAM itself. This is what makes the approach clean.

### Why `LDAPAttr uid sAMAccountName` / `gidNumber primaryGroupID`

`mod_ldap` parses returned LDAP entries looking for POSIX attributes (`uid`, `gidNumber`, `homeDirectory`, `loginShell`) to build a Unix user record. AD users don't have these — they have `sAMAccountName`, `primaryGroupID`, `unixHomeDirectory` (sometimes), etc. Without the attribute mappings, the search matches but the result is dropped as "unparseable" with the misleading error "no such user found."

- `LDAPAttr uid sAMAccountName` — use sAMAccountName where mod_ldap expects `uid`
- `LDAPAttr gidNumber primaryGroupID` — every domain user has `primaryGroupID=513`, which gives mod_ldap a number to read (and which `LDAPForceDefaultGID` then overwrites)

### Why `REFERRALS off` in `/etc/ldap/ldap.conf`

AD subtree searches against the domain root DN return **referral entries** alongside real results, pointing at `CN=Configuration`, `DomainDnsZones.h3.local`, `ForestDnsZones.h3.local`, etc. OpenLDAP's client library (used by mod_ldap) chases these by default. From inside a container those hostnames aren't resolvable, each referral waits for a DNS timeout, and the whole search hangs. Disabling referral chasing at the OpenLDAP client level via `/etc/ldap/ldap.conf REFERRALS off` fixes this for any app that uses libldap in the container. This is a known issue — see [proftpd/mod_ldap#4](https://github.com/proftpd/mod_ldap/issues/4).

### Defence in depth

| Layer | What it protects | How |
|---|---|---|
| Network | Cross-site traffic | IPsec tunnel at L3 (outside this container's scope) |
| Transport | Same-LAN traffic, admin access | FTPS via `mod_tls` (`FTPS_ENABLE=YES`) |
| Application | Who can log in at all | AD group filter via `mod_ldap` |
| Filesystem | Local shell bypass of the FTP service | Bind mount at mode 700 owned by container subuid — local users without sudo get Permission denied on the data directory |

---

## Testing

### Positive — a group member logs in

```bash
curl --user 'alice:password' ftp://ftp.example.local/
```

Expected: directory listing.

### Upload

```bash
echo hello > /tmp/hello.txt
curl --user 'alice:password' -T /tmp/hello.txt ftp://ftp.example.local/
```

Expected: `226 Transfer complete`. The file appears in `~/data/ftp/` on the host, owned by the container's subuid (not your login user).

### Negative — a non-member is rejected

Remove `alice` from the FTP group in AD, then immediately:

```bash
curl --user 'alice:password' ftp://ftp.example.local/
# curl: (67) Access denied: 530
```

No container restart needed. Re-adding her to the group restores access on the next login. There is no positive cache for this lookup; enforcement is effectively instant.

### Filesystem bypass is blocked

```bash
ls -la ~/data/ftp/
# ls: cannot open directory '/home/you/data/ftp/': Permission denied
```

The bind mount is owned by the container's `ftpuser` subuid with mode `700`. Only the container (via its user namespace) can read the data.

---

## Security considerations

**TLS is opt-in via `FTPS_ENABLE=YES`.** When disabled, the FTP protocol transmits credentials and data in the clear — only acceptable on trusted networks (isolated VLAN, IPsec/VPN tunnel between sites, etc.). When enabled, use a CA-issued cert for any production scenario; the auto-generated self-signed cert is for lab/dev use.

**Trust boundary:** the host's root user (or anyone with sudo) can always read the data directory by entering the container's user namespace. This is inherent to rootless containers and not a bug — don't give sudo to people who shouldn't read FTP data.

**The bind account:** use a dedicated read-only LDAP user. A normal, unprivileged domain user is sufficient. Do not use a Domain Admin.

**Password in `~/ftp.env`:** the environment file contains the bind DN password in plaintext. `chmod 600 ~/ftp.env` is mandatory; consider using `systemd-creds` or a secrets backend for production deployments.

**No rate limiting:** ProFTPD has `MaxLoginAttempts`, but brute-force protection should still be layered on top (fail2ban, firewall rate limits, or a reverse proxy).

---

## Troubleshooting

Most problems show up in the systemd user journal:

```bash
journalctl --user -u ftp-ldap.service --no-pager -n 80
```

| Symptom | Likely cause |
|---|---|
| `fatal: unknown configuration directive '...'` | Template rendered but ProFTPD doesn't recognise that directive in this version. Check the directive name against the version's mod_ldap/mod_tls docs. |
| `curl: (67) Access denied: 530` for a group member | The `AD_GROUP_DN` in `ftp.env` does not exactly match the group's `distinguishedName` in AD. Copy from AD Users & Computers → the group → Attribute Editor → `distinguishedName`. |
| `no such user found` in the ProFTPD LDAP log | mod_ldap couldn't parse the returned LDAP entry as a user record. Usually a missing `LDAPAttr` mapping (uid or gidNumber). |
| LDAP search times out | Referral chasing is enabled. `/etc/ldap/ldap.conf` should contain `REFERRALS off` (the Containerfile adds this). |
| `AuthOrder: warning: module 'mod_ldap.c' not loaded` | `proftpd-mod-ldap` isn't installed, or mod_ldap isn't explicitly loaded. The Containerfile installs it and the template has `LoadModule mod_ldap.c`. |
| `response reading failed (errno 115)` on FTPS | `mod_tls` isn't loaded. Install `proftpd-mod-crypto` and ensure `LoadModule mod_tls.c` is in the config. |
| `curl` hangs forever on `LIST` after login | PASV data channel broken. `PASV_ADDRESS` must be the IP the client uses to reach this host, and the PASV port range (default 50000-50100) must be open on any firewall between client and host. |

---

## Requirements

- **Host**: any modern Linux with `podman` ≥ 4.4, systemd user sessions
- **AD / LDAP**: Active Directory (any reasonably modern version), or an LDAP directory with `memberOf` overlay
- **Network**: port 389 (LDAP) to the directory, port 21 and the configured PASV range between clients and the host

---

## Roadmap

- [x] **AD group filtering** — shipped
- [x] **FTPS (explicit TLS)** — shipped, enable with `FTPS_ENABLE=YES`
- [x] **Defense in depth filesystem** — shipped, entrypoint auto-locks bind mount
- [ ] **SFTP transport** — a sibling Containerfile using `openssh-server` with LDAP auth; more production-friendly than FTP/FTPS for many use cases
- [ ] **Multiple groups** — allow login if user is a member of any of a list of groups
- [ ] **Per-group virtual roots** — different chroot per AD group
- [ ] **LDAPS** for the bind itself (currently plain LDAP on port 389)
- [ ] **Mount integration with Active Directory Certificate Services** — documented workflow for issuing a cert to the FTP host from the internal CA

---

## History

This project went through two architectures before landing on the current one:

1. **vsftpd + libpam-ldapd + nslcd** — an elegant-looking solution that used the `filter passwd (&(objectClass=user)(memberOf=...))` nslcd trick to make non-members invisible at the NSS layer. Works on paper, but vsftpd itself crashed on every session teardown in our specific environment (Debian's 3.0.3 and 3.0.5, same code offset, reproducible on every session). Root cause never fully pinned down; likely an interaction between vsftpd's privilege-separation model, `libpam-ldapd`'s session handling, and modern glibc/kernel behaviour.
2. **ProFTPD + `mod_ldap`** (current main) — replaces the entire stack. `mod_ldap` does AD group filtering natively via the user-search filter; no nslcd, no PAM tricks. Works cleanly and doesn't crash.

The full diagnostic journey (including every dead-end config we tried) is in the git log on main. If you're integrating vsftpd with LDAP elsewhere and want the nslcd technique as a reference, `git log --oneline | head -50` will walk you back through it.

---

## Alternatives

If this project doesn't fit, here are the other options worth considering:

- **[Pure-FTPd](https://www.pureftpd.org/)** with `LDAPFilter` — supports `(memberOf=...)` filters directly in its LDAP config. Image: [`stilliard/pure-ftpd`](https://github.com/stilliard/docker-pure-ftpd).
- **SSH/SFTP with SSSD on the host** — not in a container, but Red Hat's officially supported path for AD-authenticated file transfer on Linux. Heavier and requires joining the domain.

---

## Credits & prior art

- [ProFTPD](http://www.proftpd.org/) and the [mod_ldap docs](http://www.proftpd.org/docs/contrib/mod_ldap.html)
- [warlord0blog: ProFTPD and LDAP / Active Directory](https://warlord0blog.wordpress.com/2018/05/10/proftpd-and-ldap-active-directory/) — working AD config reference
- [proftpd/mod_ldap#4](https://github.com/proftpd/mod_ldap/issues/4) — known AD referral issue
- Jonathon Harper's [2019 blog post](https://blog.jonathonharper.com/2019/10/25/ftp-docker-container-with-active-directory-authentication/) — original inspiration for the vsftpd attempt and a good reference for the nslcd-based approach

---

## License

MIT. See `LICENSE` (TODO — add before publishing).
