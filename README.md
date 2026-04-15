# vsftpd-ldap-ad

**Rootless Podman vsftpd with real Active Directory group-membership access control.**

A minimal `debian:trixie-slim` container that runs [vsftpd](https://security.appspot.com/vsftpd.html) authenticating against a Windows Active Directory, and **restricts login to members of a single AD group**. Designed to run rootless under Podman as a systemd Quadlet on modern Linux hosts.

~40 MB image. ~60 lines of config across 5 files. No custom PAM logic, no AD schema changes, no POSIX attributes required on your users.

---

## Why this exists

If you've tried to get Dockerized vsftpd + LDAP working with a "members of group X only" restriction, you've probably hit one of these walls:

| Project | Problem |
|---|---|
| [`docker.io/undying/vsftpd`](https://hub.docker.com/r/undying/vsftpd) | Uses legacy `libpam-ldap`, whose PAM account stack has `[success=1 default=ignore]` for `pam_ldap.so`. Group denials are silently dropped. **No `LDAP_FILTER`, `pam_filter`, or `pam_groupdn` variant fixes this.** |
| [`joharper54SEG/Docker-vsftp-ldap`](https://github.com/joharper54SEG/Docker-vsftp-ldap) | Purpose-built for this but is based on Ubuntu 18.04 (EOL), vendors an ancient `confd` binary, and requires AD users to have POSIX attributes (`uidNumber`, `loginShell`, etc.) populated. |
| `fauria/vsftpd` | Dead since 2017. No LDAP support. |
| `delfer/alpine-ftp-server`, `atmoz/sftp` | Local users only, no directory integration. |

The widely-assumed "just set a `memberOf` filter" doesn't work on vsftpd because vsftpd's PAM service doesn't enforce group checks — PAM does, and PAM's legacy LDAP module is abandonware.

**This project solves the problem at a different layer: the `nss-pam-ldapd` daemon.** By putting the group filter in `nslcd`'s `filter passwd` directive, non-members become invisible to the entire PAM stack. When vsftpd asks PAM "does user X exist?", the answer is simply "no" for anyone outside the group. No legacy library bugs, no `default=ignore` footguns, no workarounds in vsftpd itself.

---

## Features

- ✅ **AD / LDAP authentication** via `nss-pam-ldapd` (the modern `libpam-ldapd`, not legacy `libpam-ldap`)
- ✅ **True group-based access control** — non-members receive `530 Login incorrect`, enforced by the LDAP directory itself
- ✅ **Instant enforcement** — removing a user from the group in AD rejects their next login with no cache delay
- ✅ **Rootless Podman** — runs under a normal user, managed by `systemd --user` via a Quadlet
- ✅ **No AD schema changes** — works with out-of-the-box Active Directory; no need to populate POSIX attributes on users
- ✅ **Defense in depth** — bind-mount data directory is auto-locked to `chmod 700` owned by the container's subuid at startup, so local host users can't bypass the network-level ACL by reading files directly
- ✅ **Passive FTP mode** — configurable PASV port range and advertised address (for NAT)
- ✅ **Nested group support** — documented one-line change for AD `LDAP_MATCHING_RULE_IN_CHAIN` if your FTP group is a group of groups
- ✅ **Small and inspectable** — 5 config files, a 20-line entrypoint, a 20-line Containerfile

---

## Quick start

### Prerequisites

- Linux host with `podman` ≥ 4.4 and `systemd --user` (tested on Rocky Linux 10, should work on Fedora, Ubuntu 22.04+, Debian 12+)
- Network reachability from the host to your AD/LDAP server on port 389
- A read-only bind account in AD (a normal user account is enough)
- An AD security group whose members you want to allow
- Rootless binding to port 21 enabled on the host (see below)

### One-time host setup

```bash
# Allow rootless containers to bind to port 21
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=21
echo "net.ipv4.ip_unprivileged_port_start=21" | sudo tee /etc/sysctl.d/99-ftp.conf
```

### Install

```bash
git clone https://github.com/Salicath/vsftpd-ldap-ad.git
cd vsftpd-ldap-ad
podman build -t localhost/vsftpd-ldap .

# Configure
cp ftp.env.example ~/ftp.env
chmod 600 ~/ftp.env
$EDITOR ~/ftp.env        # set AD_HOST, DNs, PASV_ADDRESS — see below

# Data directory (bind-mounted into the container)
mkdir -p ~/data/ftp

# Install and start the Quadlet
mkdir -p ~/.config/containers/systemd
cp vsftpd.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start vsftpd.service

# Make it survive logout
loginctl enable-linger $USER
```

Verify:
```bash
systemctl --user status vsftpd.service
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

### For nested AD groups

Active Directory `memberOf` does not traverse nested groups by default. If your FTP group contains other groups (rather than users directly), edit `nslcd.conf.tmpl` and swap:

```
filter passwd (&(objectClass=user)(memberOf=${AD_GROUP_DN}))
```

for:

```
filter passwd (&(objectClass=user)(memberOf:1.2.840.113556.1.4.1941:=${AD_GROUP_DN}))
```

That OID is `LDAP_MATCHING_RULE_IN_CHAIN` — it instructs the DC to walk the group hierarchy transitively. Rebuild the image after changing the template.

---

## How it works

### The architecture

```
    FTP client
        │
        │  control channel: port 21
        ▼
┌─────────────────┐
│     pasta       │   (rootless podman's network backend, forwards host:21 → container:21)
└────────┬────────┘
         │
┌────────▼────────────────────────────────────────────┐
│ Container (debian:trixie-slim, ~40 MB)              │
│                                                     │
│   vsftpd ──PAM──▶ pam_ldap.so ──unix socket──▶ nslcd│
│     │                                          │   │
│     │                                          ▼   │
│     │                                    ┌──────────┤
│     │                                    │  LDAP    │
│     │                                    │  query   │
│     │                                    │  with    │
│     │                                    │  filter  │
│     └── bind mount /home/vsftpd           │  passwd  │
│         (host: ~/data/ftp, mode 700,      │  ...     │
│         owned by container's ftpuser)     └──┬───────┤
└───────────────────────────────────────────────│──────┘
                                                │
                                                ▼
                                       Active Directory (LDAP)
```

### The access-control flow

1. Client connects to vsftpd on port 21.
2. Client sends `USER <name>` and `PASS <password>`.
3. vsftpd calls PAM with service name `vsftpd`. Our `pam.d/vsftpd` is three lines, all `required`:
   ```
   auth     required pam_ldap.so
   account  required pam_ldap.so
   session  required pam_permit.so
   ```
4. `pam_ldap.so` (from `libpam-ldapd`) forwards the auth and account checks to `nslcd` via a Unix socket.
5. `nslcd` applies the filter from `nslcd.conf`:
   ```
   filter passwd (&(objectClass=user)(memberOf=CN=FTP-Users,...))
   ```
6. If the user is not in the group, `nslcd` returns nothing → PAM returns `PAM_USER_UNKNOWN` → vsftpd sends `530 Login incorrect`.
7. If the user is in the group, PAM auth succeeds. vsftpd's `guest_enable=YES` then remaps the session to a local `ftpuser` account (uid 1000) and chroots into `/home/vsftpd`, which is bind-mounted to the host's `~/data/ftp`.

### Why `primaryGroupID` for uidNumber

`nslcd` needs to return *some* numeric uid to satisfy NSS lookups. AD users don't have a `uidNumber` attribute by default (that requires the deprecated "Identity Management for UNIX" role). We could use the `objectSid → uidNumber` mapping trick, but that needs the domain SID as a runtime variable.

Instead, we use `map passwd uidNumber primaryGroupID`. Every domain user has `primaryGroupID=513`, which is always numeric and always present. It doesn't matter that every user reports the same uid — vsftpd throws the value away in step 7 above when it remaps to `ftpuser`.

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

No container restart needed. Re-adding her to the group restores access on the next login. `nslcd` has no meaningful positive cache for this query, so enforcement is effectively instant.

### Local filesystem bypass is blocked

```bash
ls -la ~/data/ftp/
# ls: cannot open directory '/home/you/data/ftp/': Permission denied
```

The bind mount is owned by the container's `ftpuser` subuid with mode `700`. Only the container (through its user namespace) can read the data. A local shell user without sudo cannot bypass the AD group filter by reading files directly. The trust boundary is "anyone with sudo on the host can read everything" — which is true of every system and cannot be engineered away.

---

## Security considerations

**Plain FTP is unencrypted.** This project authenticates users against AD but transmits credentials and data in the clear. Only use it on trusted networks, behind a VPN, or in combination with network-level access controls. TLS/FTPS support is on the roadmap.

**Trust boundary:** the host's root user (or anyone with sudo) can always read the data directory by entering the container's user namespace. This is inherent to rootless containers and not a bug.

**The bind account:** use a dedicated read-only LDAP user. A normal domain user account with no admin rights is sufficient. Do not use a Domain Admin.

**Password in `~/ftp.env`:** the environment file contains the bind DN password in plaintext. `chmod 600 ~/ftp.env` is mandatory; consider using `systemd-creds` or a secrets backend for production deployments.

**No rate limiting:** vsftpd has `max_login_fails` but brute-force protection should still be layered on top (fail2ban, firewall rate limits, or a reverse proxy).

---

## Troubleshooting

Most problems show up in the systemd user journal:

```bash
journalctl --user -u vsftpd.service --no-pager -n 80
```

| Symptom | Likely cause |
|---|---|
| `nslcd: bind failed` | `AD_BIND_DN` or `AD_BIND_PW` is wrong. Verify from the host with `ldapsearch -x -H ldap://$AD_HOST -D "$AD_BIND_DN" -w "$AD_BIND_PW" -b "$AD_BASE_DN" -s base`. |
| `Main process exited, code=exited, status=139` | vsftpd segfault — almost always a specific distro's vsftpd build. This image uses Debian Trixie's vsftpd 3.0.5 to avoid a known crash in Bookworm's 3.0.3. |
| `curl: (67) 530` for a group member | The `AD_GROUP_DN` in `ftp.env` does not exactly match the group's `distinguishedName` in AD. Copy it from AD Users & Computers → the group → Attribute Editor → `distinguishedName`. |
| `curl` hangs forever on `LIST` after login | PASV data channel is broken. `PASV_ADDRESS` must be the IP the client uses to reach the host, and the PASV port range (50000-50100) must be open on any firewall between client and host. |
| `[500 OOPS: vsftpd: refusing to run with writable root inside chroot()`] | `allow_writeable_chroot=YES` is already set in this image's `vsftpd.conf.tmpl`, so you shouldn't hit this. If you do, the bind mount's mode is probably broken — the entrypoint auto-chowns it to `700` + `ftpuser` on startup. |

---

## Requirements

- **Host**: any modern Linux with `podman` ≥ 4.4, systemd user sessions, and the `user_allow_other` FUSE option (default on most distros)
- **AD / LDAP**: Active Directory (any reasonably modern version), or an LDAP directory with `memberOf` overlay. OpenLDAP with `memberOf` overlay enabled also works.
- **Network**: port 389 (LDAP) to the directory, port 21 and the configured PASV range (default 50000-50100) between clients and the host

---

## Roadmap

This project is intentionally minimal. The following are deliberate non-goals of the v1 — but candidates for future work if there's demand:

- [ ] **FTPS** (explicit TLS on the FTP protocol) — prevents credential sniffing. Straightforward: `ssl_enable=YES` + cert mount. Needs a cert-generation helper or a sidecar.
- [ ] **SFTP transport** — a sibling Containerfile using `openssh-server` + `pam_ldapd` would give you the same group filter with SSH-based transport. More production-friendly than FTP.
- [ ] **Multiple groups** — allow login if user is in any of a list of groups
- [ ] **Per-group virtual roots** — different chroot per AD group
- [ ] **LDAPS** for the bind itself (currently plain LDAP on port 389)
- [ ] **Prometheus metrics** exporter sidecar

Contributions welcome.

---

## Alternatives

If this project doesn't fit, here are the other options worth considering:

- **[ProFTPD](http://www.proftpd.org/)** with `mod_ldap` — ProFTPD has native `LDAPGroups` + `<Limit LOGIN><AllowGroup>` directives, so group filtering is a one-line config. Image: [`instantlinux/proftpd`](https://github.com/instantlinux/docker-tools/tree/main/images/proftpd). Cleanest alternative if you don't specifically need vsftpd.
- **[Pure-FTPd](https://www.pureftpd.org/)** with `LDAPFilter` — supports `(memberOf=...)` filters directly in its LDAP config. Image: [`stilliard/pure-ftpd`](https://github.com/stilliard/docker-pure-ftpd).
- **SSH/SFTP with SSSD on the host** — not in a container, but Red Hat's officially supported path for AD-authenticated file transfer on Linux. Heavier and requires joining the domain.

---

## Credits & prior art

- [`nss-pam-ldapd`](https://arthurdejong.org/nss-pam-ldapd/) by Arthur de Jong — the upstream project that makes this possible
- [vsftpd](https://security.appspot.com/vsftpd.html) by Chris Evans
- Jonathon Harper's [blog post and original repo](https://blog.jonathonharper.com/2019/10/25/ftp-docker-container-with-active-directory-authentication/) from 2019 were the first to document the nslcd approach for AD, and inspired this modern rewrite
- The Debian maintainers of `libpam-ldapd` for keeping a sane, working PAM-LDAP path alive while the rest of the ecosystem moved on

---

## License

MIT. See `LICENSE` (TODO — add before publishing).
