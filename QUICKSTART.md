# Quickstart (exam day)

This is the **copy-paste-from-top-to-bottom** version. You don't need to understand what the commands do. If anything fails, the "If it breaks" section at the bottom has the fix.

## Assumptions (check these first)

You have a **Rocky Linux 10** VM where:

1. You can log in as a non-root user (e.g. `h3`) with sudo rights.
2. Podman is installed (`podman --version` should work).
3. You have network access to the Windows DC on port 389.

## 1. Install (copy the whole block, paste in one go)

```bash
cd ~
sudo dnf install -y git
git clone https://github.com/Salicath/vsftpd-ldap-ad.git ftp-ldap
cd ~/ftp-ldap
chmod +x install.sh test.sh cleanup.sh
./install.sh
```

Wait ~1-2 minutes for the first build. When you see:

```
================================================
  SUCCESS — the ftp-ldap service is running.
================================================
```

...you're in.

**If your network is NOT the h3.local lab** (e.g. on exam day): edit `ftp-ldap.container` before running `./install.sh`, and change the `Environment=` lines at the top of the `[Container]` section:

```bash
nano ~/ftp-ldap/ftp-ldap.container
```

The two values that usually need changing are:

```
Environment=AD_HOST=<your DC IP>
Environment=PASV_ADDRESS=<this host's IP>
```

Save, then run `./install.sh`. (Or if the service is already running and you just want to change config, edit `~/.config/containers/systemd/ftp-ldap.container` and run `systemctl --user daemon-reload && systemctl --user restart ftp-ldap.service`.)

## 2. Test it

```bash
cd ~/ftp-ldap
./test.sh
```

Expected: four green `[PASS]` lines and `All tests passed. Ready for exam demo.`

## 3. Demo for the examiner

### Show a group member logging in

```bash
curl --user 'test1:Kode1234!' ftp://192.168.1.13/
```

(Replace `192.168.1.13` with whatever `PASV_ADDRESS` you set.)

Should list the directory.

### Upload a file

```bash
echo "hello from exam day" > /tmp/hi.txt
curl --user 'test1:Kode1234!' -T /tmp/hi.txt ftp://192.168.1.13/
curl --user 'test1:Kode1234!' ftp://192.168.1.13/   # should now show hi.txt
```

### Show the group filter in action

On the Windows DC, open **Active Directory Users and Computers**, find `test1`, and **remove them from the `FTP-Brugere` group**. Then immediately:

```bash
curl --user 'test1:Kode1234!' ftp://192.168.1.13/
# -> curl: (67) Access denied: 530
```

No delay, no cache, no container restart. Re-add to the group and run the curl again — it works instantly. This is the "money shot" for the exam.

### Show the filesystem lockdown

```bash
ls -la ~/data/ftp/
```

Expected: `ls: cannot open directory '/home/h3/data/ftp/': Permission denied`

**This is correct.** Explanation for the examiner: *"Even though I have shell access to this host, I can't read the FTP data directly. The bind mount is owned by the container's subuid with mode 700, so I'd need to either use the FTP protocol (which goes through AD auth) or use sudo. Local shell bypass of the AD access control is blocked."*

## 4. Optional: turn on TLS/FTPS

Most examiners will ask about encryption. Your answer is the two-layer story: **IPsec at the network layer** (between Site A and Site B, already covers cross-site traffic) **plus FTPS at the transport layer** (covers same-LAN and local admin access). To turn FTPS on, change the `FTPS_ENABLE` line in `ftp-ldap.container`:

```bash
sed -i 's/Environment=FTPS_ENABLE=NO/Environment=FTPS_ENABLE=YES/' \
    ~/.config/containers/systemd/ftp-ldap.container
systemctl --user daemon-reload
systemctl --user restart ftp-ldap.service
sleep 3
curl -kv --ssl-reqd --user 'test1:Kode1234!' ftp://192.168.1.13/ 2>&1 | head -30
```

You should see `234 AUTH SSL successful`, a TLS 1.3 handshake, and `230 User test1 logged in`. The `-k` flag tells curl to accept the self-signed cert. In production, you'd mount a certificate issued by Active Directory Certificate Services instead.

To turn it back off, swap `YES` for `NO` and restart.

## 5. Start over completely from scratch

```bash
cd ~/ftp-ldap
./cleanup.sh
# type 'yes' when prompted
./install.sh
./test.sh
```

## If it breaks

| Symptom | What it means / how to fix |
|---|---|
| `error getting current working directory` | You ran cleanup from inside `~/ftp-ldap` and your shell is in a deleted dir. Type `cd ~` and try again. |
| `Permission denied` on `ls ~/data/ftp` | **Not a bug.** That's the filesystem lockdown doing its job. Explain it to the examiner. |
| `curl: (7) Failed to connect` right after `install.sh` | The container is still starting. Wait 5 seconds and try again. |
| `curl: (67) Access denied: 530` for a user you expect to work | That user isn't in the configured AD group. Add them (or check the group DN in `ftp-ldap.container`). |
| `Failed to start ftp-ldap.service` | Read the journal: `journalctl --user -u ftp-ldap.service --no-pager -n 50` |
| `./install.sh: Permission denied` | You forgot `chmod +x install.sh test.sh cleanup.sh` — run that again. |
| `podman not found` | `sudo dnf install -y podman` then rerun `install.sh`. |

## Where to edit configuration

**Everything** — AD connection, bind credentials, group DN, PASV address, FTPS toggle — lives in **one file**: `ftp-ldap.container`. There are two copies of it:

- `~/ftp-ldap/ftp-ldap.container` — the source in the cloned repo
- `~/.config/containers/systemd/ftp-ldap.container` — the installed copy systemd reads

`./install.sh` copies from the first to the second. If you edit the installed copy directly, `systemctl --user daemon-reload && systemctl --user restart ftp-ldap.service` picks up the change without a rebuild.

## One-sentence summary for the examiner

> This is a rootless Podman ProFTPD container on Rocky Linux 10. Authentication goes through ProFTPD's `mod_ldap` directly against Active Directory — there's no PAM involved. The group filter is embedded in the LDAP search itself as a `memberOf` clause, so non-members are rejected at the directory level with no cache, enforced on every login. FTPS is available as an opt-in one-env-var flip with an auto-generated self-signed cert for the lab; in production I'd mount a certificate issued by AD Certificate Services. The bind-mounted data directory is mode 700 owned by the container's subuid, so local shell users without sudo can't bypass the network-level access control. All deployment and configuration lives in one systemd Quadlet file (`ftp-ldap.container`) plus one Containerfile — two files describe the entire system.
