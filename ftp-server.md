# FTP-server med Podman
## Quadlet og Active Directory

## Forudsætninger

- Rocky Linux 10
- Bruger: `h3`
- VPN-tunnel mellem Site A og Site B (FTP-serveren skal kunne nå Domain Controller)
- Active Directory Domain Controller tilgængelig på `10.1.80.11`
- AD-sikkerhedsgruppe `FTP-Brugere` oprettet i Active Directory
- Denne server er placeret på **Site B** (datacenter-siden bag ASA2) på `10.2.80.11`

## 1. Installér Podman og forbered bruger

```bash
sudo dnf install -y podman nano
sudo loginctl enable-linger h3
```

Aktivér Podman socket:

```bash
systemctl --user enable --now podman.socket
```

## 2. Tillad port 21 for rootless Podman

Port 21 er under 1024 og kræver en sysctl-ændring for at rootless Podman må binde til den:

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=21
echo "net.ipv4.ip_unprivileged_port_start=21" | sudo tee /etc/sysctl.d/99-ftp.conf
```

Ændringen er persistent efter reboot via `sysctl.d`-filen.

## 3. Opret datamappe

```bash
mkdir -p /home/h3/data/ftp
mkdir -p /home/h3/.config/containers/systemd
```

## 4. Quadlet-fil

Filen placeres i `/home/h3/.config/containers/systemd/ftp-ldap.container`

```ini
[Unit]
Description=ftp-ldap (ProFTPD with AD group filter via mod_ldap)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Container]
ContainerName=ftp-ldap
Image=ghcr.io/salicath/ftp-ldap:latest
Pull=newer

PublishPort=21:21
PublishPort=50000-50100:50000-50100

Volume=/home/h3/data/ftp:/srv/ftp:Z

# ---- Active Directory ----
Environment=AD_HOST=<DC_IP>
Environment=AD_BASE_DN=DC=<DOMÆNE>,DC=local
Environment=AD_BIND_DN=CN=<SERVICE_ACCOUNT>,OU=<OU_PATH>,DC=<DOMÆNE>,DC=local
Environment=AD_BIND_PW=Kode1234!
Environment=AD_GROUP_DN=CN=FTP-Brugere,OU=<GROUPS_OU>,DC=<DOMÆNE>,DC=local

# ---- Passive FTP ----
Environment=PASV_ADDRESS=<FTP_IP>
Environment=PASV_MIN_PORT=50000
Environment=PASV_MAX_PORT=50100

# ---- FTPS (sæt YES for at aktivere TLS) ----
Environment=FTPS_ENABLE=NO

SecurityLabelDisable=true

HealthCmd=bash -c '</dev/tcp/localhost/21'
HealthInterval=30s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=10s

[Service]
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
```

Erstat placeholders med jeres AD-oplysninger (værdier kommer fra `00-variabler.pdf`):

| Placeholder | Erstat med | Eksempel |
|---|---|---|
| `<DC_IP>` | IP på Domain Controller | `10.1.80.11` |
| `<FTP_IP>` | IP på denne FTP-server (for PASV) | `10.2.80.11` |
| `<DOMÆNE>` | AD-domænenavn (første label) | `h3` |
| `<SERVICE_ACCOUNT>` | AD service-konto (samme som Nextcloud bruger) | `svc-ldap` |
| `<OU_PATH>` | OU-stien til service-kontoen | `Servicekonti` |
| `<GROUPS_OU>` | OU hvor `FTP-Brugere` gruppen ligger | `Sikkerhedsgrupper` |

## Forklaring

| Indstilling | Formål |
|---|---|
| `Image=ghcr.io/salicath/ftp-ldap:latest` | ProFTPD med mod_ldap, pre-built image på GitHub Container Registry |
| `Pull=newer` | Henter automatisk imaget ved første start og opdaterer ved nye versioner |
| `PublishPort=21:21` | Kontrolkanal — standard FTP-port |
| `PublishPort=50000-50100` | Passive mode data-range |
| `Volume=...:/srv/ftp:Z` | FTP data på hosten (låses automatisk til mode 700) |
| `AD_HOST` / `AD_BASE_DN` | Domain Controller IP og LDAP-søgebase |
| `AD_BIND_DN` / `AD_BIND_PW` | Service-konto ProFTPD binder med |
| `AD_GROUP_DN` | Fuld DN på `FTP-Brugere` — selve gruppe-filteret |
| `PASV_ADDRESS` | IP'en klienter bruger til at nå serveren (annonceres i PASV-svar) |
| `FTPS_ENABLE` | `YES` aktiverer TLS med auto-genereret selvsigneret certifikat |

## Credentials

| Hvad | Bruger | Password |
|---|---|---|
| LDAP bind-konto | `<SERVICE_ACCOUNT>` | `Kode1234!` |
| FTP login | AD-brugernavn (skal være medlem af `FTP-Brugere`) | AD-brugerens password |

## 5. Start FTP-serveren

```bash
systemctl --user daemon-reload
systemctl --user start ftp-ldap.service
```

Verificer:

```bash
systemctl --user status ftp-ldap.service
podman ps
```

Forventet: `Active: active (running)` og en container ved navn `ftp-ldap` i `podman ps`.

## 6. Åbn firewall

```bash
sudo firewall-cmd --add-service=ftp --permanent
sudo firewall-cmd --add-port=50000-50100/tcp --permanent
sudo firewall-cmd --reload
```

Hvis `firewall-cmd` ikke findes, kører `firewalld` ikke — spring dette trin over.

## Vigtige detaljer

- **Gruppe-filteret håndhæves i selve LDAP-søgningen** via `LDAPUsers` med en `(memberOf=...)` clause inde i imaget. Brugere der ikke er medlemmer matcher ikke søgningen, og ProFTPD svarer `530 Login incorrect`. Ingen cache.
- **`Pull=newer`** betyder at Podman henter imaget fra `ghcr.io` første gang servicen starter, og senere opdaterer automatisk hvis vi pusher en ny version.
- **`chmod 700` på `/srv/ftp`** sættes automatisk hver container-start. Lokale shell-brugere på Rocky-værten uden sudo får `Permission denied` på `/home/h3/data/ftp` — de kan ikke omgå AD-gruppefilteret ved at læse filerne direkte.
- **Filnavnet `ftp-ldap.container` bestemmer systemd-unit'en**: `ftp-ldap.service`.
- **`sudo loginctl enable-linger h3` er påkrævet** — uden det stoppes containeren når `h3` logger ud.
- **Efter ændringer i Quadlet-filen**: kør `systemctl --user daemon-reload && systemctl --user restart ftp-ldap.service`.

## 7. Verificering

### 7.1 Test forbindelse

```bash
python3 -c "import socket; s=socket.socket(); s.settimeout(3); \
    s.connect(('10.2.80.11',21)); print(s.recv(200).decode())"
```

Forventet: `220 ProFTPD Server (ftp-ldap) [10.2.80.11]`

### 7.2 Test login som gruppe-medlem

```bash
curl --user 'test1:Kode1234!' ftp://10.2.80.11/
```

Forventet: en mappeliste (kan være tom ved første login). Erstat `test1` med en rigtig bruger der er medlem af `FTP-Brugere`.

### 7.3 Test upload

```bash
echo "test" > /tmp/testfil.txt
curl --user 'test1:Kode1234!' -T /tmp/testfil.txt ftp://10.2.80.11/
curl --user 'test1:Kode1234!' ftp://10.2.80.11/
```

Den anden `curl` skal vise `testfil.txt` i listen.

### 7.4 Test adgangsbegrænsning (det vigtigste)

På Windows DC'en: åbn **Active Directory Users and Computers**, find brugeren, højreklik → **Properties** → fanen **Member Of** → marker `FTP-Brugere` → **Remove** → **OK**.

Kør derefter den samme `curl` igen:

```bash
curl --user 'test1:Kode1234!' ftp://10.2.80.11/
```

Forventet: `curl: (67) Access denied: 530`. Ingen ventetid, ingen genstart af service. Tilføj brugeren til gruppen igen og kør `curl` — det virker med det samme.

### 7.5 Test lokal filsystem-spærring

```bash
ls -la /home/h3/data/ftp/
```

Forventet: `ls: cannot open directory '/home/h3/data/ftp/': Permission denied`. Dette er korrekt — mappen er låst til mode 700 ejet af containerens subuid.

## 8. Valgfrit: aktivér FTPS (TLS)

Ændr en enkelt linje i den installerede Quadlet-fil:

```bash
sed -i 's/Environment=FTPS_ENABLE=NO/Environment=FTPS_ENABLE=YES/' \
    /home/h3/.config/containers/systemd/ftp-ldap.container

systemctl --user daemon-reload
systemctl --user restart ftp-ldap.service
```

Test med `curl` (flaget `-k` accepterer det selvsignerede certifikat):

```bash
curl -kv --ssl-reqd --user 'test1:Kode1234!' ftp://10.2.80.11/ 2>&1 | head -30
```

Forventet: `234 AUTH SSL successful`, TLS 1.3 handshake, og `230 User test1 logged in`.

## 9. WordPress-integration (valgfrit)

For at lade WordPress servere filer uploadet via FTP, tilføj FTP-mappen som read-only volume i `wordpress-app.container`:

```
Volume=/home/h3/data/ftp:/var/www/html/ftp-uploads:ro
```

Genstart WordPress:

```bash
systemctl --user daemon-reload
systemctl --user restart wordpress-pod
```

Filer uploadet via FTP er nu tilgængelige på `http://<WORDPRESS_IP>/ftp-uploads/`. `:ro` sikrer at WordPress kun kan læse — ikke ændre eller slette FTP-filer.

## 10. Fejlfinding

Læs servicens log først:

```bash
journalctl --user -u ftp-ldap.service --no-pager -n 50
```

| Problem | Årsag | Løsning |
|---|---|---|
| `Failed to start ftp-ldap.service` | Syntax-fejl i Quadlet'en | Læs journal-loggen — fejlen står i de sidste 10 linjer |
| `Error: initializing source ...: ...` ved start | Imaget kunne ikke hentes (ingen netværk, eller GHCR er privat) | Test `podman pull ghcr.io/salicath/ftp-ldap:latest` manuelt |
| `curl: (7) Failed to connect to 10.2.80.11 port 21` | Containeren startede ikke eller port 21 er blokeret | `systemctl --user status ftp-ldap.service` + tjek firewall |
| `curl: (67) Access denied: 530` for gyldig bruger | Brugeren er ikke i `FTP-Brugere` gruppen | Tilføj brugeren til gruppen i AD Users and Computers |
| `ls: cannot open directory '/home/h3/data/ftp/'` | Ikke en fejl — filsystem-spærringen virker som den skal | (intet at gøre) |
| VPN nede — kan ikke nå DC'en | IPSec-tunnelen er gået ned | Tjek `show crypto ipsec sa` på ASA1/ASA2 |

Test LDAP-filteret direkte mod DC'en fra Rocky-værten (uden containeren):

```bash
sudo dnf install -y openldap-clients

ldapsearch -x -H ldap://10.1.80.11 \
  -D "CN=<SERVICE_ACCOUNT>,OU=<OU_PATH>,DC=<DOMÆNE>,DC=local" -w 'Kode1234!' \
  -b "DC=<DOMÆNE>,DC=local" \
  "(&(objectClass=user)(sAMAccountName=test1)(memberOf=CN=FTP-Brugere,OU=<GROUPS_OU>,DC=<DOMÆNE>,DC=local))" \
  dn 2>&1 | grep '^dn:'
```

Hvis denne kommando returnerer en `dn:` linje, skal brugeren også kunne logge ind via FTP. Hvis den ikke returnerer noget, er brugeren ikke i gruppen.

## Opdatering af imaget

Imaget bygges automatisk på GitHub hver gang Containerfile'en eller entrypoint'en ændres. For at hente den nyeste version på Rocky-værten:

```bash
systemctl --user restart ftp-ldap.service
```

`Pull=newer` i Quadlet'en henter automatisk det nye image hvis det findes.

## Opsummering

| Komponent | Detalje |
|---|---|
| OS | Rocky Linux 10 |
| Container runtime | Podman (rootless) |
| Image | `ghcr.io/salicath/ftp-ldap:latest` (pre-built, auto-updates) |
| FTP daemon | ProFTPD med mod_ldap og mod_tls |
| Sysctl | `net.ipv4.ip_unprivileged_port_start=21` (påkrævet for rootless) |
| Autentificering | Active Directory via LDAP (`mod_ldap`) |
| Adgangskontrol | `memberOf` filter i selve LDAP-søgningen — ingen cache |
| Service-konto | Samme bind-konto som Nextcloud bruger |
| Quadlet-fil | `/home/h3/.config/containers/systemd/ftp-ldap.container` (den eneste fil man rører) |
| FTP data (host) | `/home/h3/data/ftp` (mode 700, ejet af containerens subuid) |
| FTP data (container) | `/srv/ftp` |
| Porte | 21 (kontrol) + 50000-50100 (passive) |
| Systemd unit | `ftp-ldap.service` |
| Valgfri TLS | `FTPS_ENABLE=YES` → automatisk selvsigneret certifikat |
| WordPress-integration | FTP-uploads som read-only volume |
| Nextcloud-integration | FTP-uploads via External Storage (FTP backend) |
| Alle credentials | Service-konto password: `Kode1234!` |
| Placering | Site B — datacenter (bag ASA2) |
