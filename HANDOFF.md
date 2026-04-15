# FTP + AD group filter — handoff (2026-04-14)

## Goal
Rootless Podman vsftpd container on Rocky Linux 10, authenticating against Windows Server AD, login restricted to members of `CN=FTP-Brugere,OU=Sikkerhedsgrupper,DC=h3,DC=local`.

## Status
All files written in this directory. **Not yet built or tested on Rocky.** That's the first job tomorrow.

## Why not `undying/vsftpd` anymore
It uses old `libpam-ldap`, whose PAM account stack has `[success=1 default=ignore]` for `pam_ldap.so` — group denials are silently ignored. Every filter/pam_groupdn/pam_filter variant was tried and failed; details in memory, don't re-try them.

## Why this approach works
Custom `debian:12-slim` image with `libpam-ldapd` + `nslcd`. The critical line in `nslcd.conf`:
```
filter passwd (&(objectClass=user)(memberOf=CN=FTP-Brugere,OU=Sikkerhedsgrupper,DC=h3,DC=local))
```
Users outside the group are **invisible** at the NSS layer, so PAM reports `PAM_USER_UNKNOWN` — no group-check logic required, no broken library paths. `objectSid:<base-sid>` mapping derives a stable `uidNumber` without requiring POSIX attributes on AD users.

## Environment
- Rocky Linux 10 host user: `h3`
- DC (test): 192.168.1.21 — DC (prod Site A): 10.1.80.11
- FTP host (test): 192.168.1.13 — FTP host (prod Site B): 10.2.80.11
- Domain: `h3.local`
- Bind: `CN=svc-ldap,OU=Servicekonti,DC=h3,DC=local`
- Group: `CN=FTP-Brugere,OU=Sikkerhedsgrupper,DC=h3,DC=local`
- Test user: `test1` in `OU=IT,OU=Afdelinger,DC=h3,DC=local`
- Lab password throughout: `Kode1234!` (goes into `~/ftp.env`, not this repo)
- Data dir: `/home/h3/data/ftp`
- Port 21 unprivileged: `net.ipv4.ip_unprivileged_port_start=21` already persisted in `/etc/sysctl.d/99-ftp.conf`

## Files in this directory
- `Containerfile` — debian:12-slim + vsftpd + libpam-ldapd (nslcd pulled in as dep)
- `entrypoint.sh` — envsubsts templates, starts nslcd, execs vsftpd
- `nslcd.conf.tmpl` — the key file; `filter passwd memberOf=...` + objectSid→uid mapping
- `vsftpd.conf.tmpl` — guest mode mapping all AD users to local `ftpuser`, pasv 50000-50100
- `pam.vsftpd` — 3 lines, all `required`, no `default=ignore`
- `vsftpd.container` — Quadlet unit, pulls secrets from `EnvironmentFile=%h/ftp.env`
- `ftp.env.example` — template; real one lives at `~/ftp.env` on Rocky (chmod 600)

## Tomorrow's next steps

### 1. On the Windows DC, get the domain SID (needed for nslcd mapping)
```powershell
(Get-ADDomain).DomainSID.Value
```
Expect `S-1-5-21-<a>-<b>-<c>`. Copy it.

### 2. Transfer files to Rocky
From the dev laptop:
```bash
scp -r ~/Downloads/Skoleprojekt/ftp-ldap h3@<rocky-ip>:~/
```

### 3. Build image and install Quadlet on Rocky
```bash
cd ~/ftp-ldap

podman build -t localhost/vsftpd-ldap .

cp ftp.env.example ~/ftp.env
chmod 600 ~/ftp.env
# edit ~/ftp.env: paste real AD_DOMAIN_SID, confirm PASV_ADDRESS is 192.168.1.13 for test

mkdir -p ~/data/ftp

mkdir -p ~/.config/containers/systemd
cp vsftpd.container ~/.config/containers/systemd/

systemctl --user daemon-reload
systemctl --user start vsftpd.service
systemctl --user status vsftpd.service
loginctl enable-linger $USER
```

### 4. Firewalld (Rocky)
```bash
sudo firewall-cmd --add-service=ftp --add-port=50000-50100/tcp --permanent
sudo firewall-cmd --reload
```

### 5. Test
```bash
podman logs -f vsftpd-ldap   # watch this in one terminal

# in another: login as test1 (member → should succeed + allow upload)
lftp -u test1 ftp://192.168.1.13

# login as a user NOT in FTP-Brugere (should fail with 530)
lftp -u <other-user> ftp://192.168.1.13
```

Expected: group member lists and uploads fine; non-member gets `530 Login incorrect`.

## Debug checklist if things break
1. `podman logs` shows `nslcd` won't start → usually bad `AD_DOMAIN_SID` format or bind failure. Verify bind with `ldapsearch` from the host first (the exact working command is in the briefing).
2. Group member can't log in → the group DN in `ftp.env` must match the exact AD X500 DN. Copy from AD Users & Computers → test1 → Attribute Editor → `memberOf` → distinguishedName.
3. Nested AD groups → swap the filter to `(memberOf:1.2.840.113556.1.4.1941:=CN=FTP-Brugere,...)` in `nslcd.conf.tmpl` and rebuild.
4. PASV connection hangs → `PASV_ADDRESS` must be the IP the client uses to reach the host (not the container-internal address). For test it's 192.168.1.13.
5. SELinux denies volume access → `:Z` is on the volume mount AND `SecurityLabelDisable=true` is in the Quadlet (matches your current working config).

## If the whole approach fails
Fallbacks ranked:
1. **`instantlinux/proftpd`** — native `mod_ldap` with `LDAPGroups` + `<Limit LOGIN><AllowGroup>`. Cleanest; use this if vsftpd path dies.
2. **`stilliard/pure-ftpd`** — `LDAPFilter "(memberOf=...)"` in `pureftpd-ldap.conf`. Needs mounted config.

Do not retry: `joharper54SEG/Docker-vsftp-ldap` (Ubuntu 18.04 + needs AD POSIX attrs), `fauria/vsftpd` (dead), SSSD-in-container (rootless pain).
