# ftp-ldap

Rootless Podman FTP container with Active Directory group-membership access control.

Built for an exam project — Rocky Linux 10, rootless Podman, systemd Quadlet, pre-built image hosted on GitHub Container Registry.

## For students / groupmembers

**Follow [`ftp-server.md`](ftp-server.md)** (Danish). You'll paste one Quadlet file, edit a handful of `Environment=` lines, and start the service. The image is pulled automatically from `ghcr.io/salicath/ftp-ldap:latest` — no `podman build`, no install scripts.

## For the maintainer

The image is rebuilt and pushed to GHCR automatically by `.github/workflows/build.yml` on every push to `main` that touches `Containerfile`, `entrypoint.sh`, or `proftpd.conf.tmpl`. Students get updates by restarting the service (`Pull=newer` in the Quadlet).

Files:

| File | Audience | Purpose |
|---|---|---|
| `ftp-ldap.container` | student | The only file a beginner edits |
| `ftp-server.md` | student | Danish step-by-step walkthrough |
| `Containerfile` | maintainer | Defines the image (ProFTPD + mod_ldap + mod_tls on `debian:trixie-slim`) |
| `proftpd.conf.tmpl` | maintainer | ProFTPD config template, rendered by `entrypoint.sh` with `Environment=` values |
| `entrypoint.sh` | maintainer | Renders config, locks data dir, enables optional FTPS, execs proftpd |
| `.github/workflows/build.yml` | maintainer | Builds and pushes the image to GHCR |
| `docs-style.css` | maintainer | CSS for rendering `ftp-server.md` to PDF |

To rebuild the image manually (for local testing before pushing):

```bash
podman build -t localhost/ftp-ldap .
# then in the Quadlet temporarily: Image=localhost/ftp-ldap:latest
```
