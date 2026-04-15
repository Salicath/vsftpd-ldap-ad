# FTP-server med Podman Quadlet og Active Directory

## Forudsætninger

- Rocky Linux 10
- Bruger: `h3`
- VPN-tunnel mellem Site A og Site B (FTP-serveren skal kunne nå Domain Controller)
- Active Directory Domain Controller tilgængelig på `10.1.80.11`
- AD-sikkerhedsgruppe `FTP-Brugere` oprettet i Active Directory
- Denne server er placeret på **Site B** (datacenter-siden bag ASA2) på `10.2.80.11`

## Rolle i infrastrukturen

- Medarbejdere i AD-gruppen `FTP-Brugere` kan uploade filer via FTP til datacenteret
- FTP-serveren autentificerer mod Active Directory via LDAP — samme service-konto som Nextcloud bruger
- **Kun brugere i `FTP-Brugere` gruppen kan logge ind** — alle andre afvises med `530 Login incorrect`
- Adgangskontrollen håndhæves i LDAP-søgningen selv (`memberOf=...` filter) uden cache — fjerner man en bruger fra gruppen i AD slår det igennem på næste loginforsøg
- FTP-uploads er tilgængelige i Nextcloud via External Storage (se `nextcloud.pdf`)
- WordPress-containeren kan også tilgå uploadede filer som read-only volume

## Arkitektur

FTP-serveren er en **custom Podman-container bygget fra debian:trixie-slim**. Den kører ProFTPD med `mod_ldap` og `mod_tls`. I modsætning til en færdig upstream image (som den oprindelige `undying/vsftpd` vi forsøgte først, hvor gruppe-filteret aldrig reelt håndhævede adgangskontrollen) er denne container skræddersyet så gruppe-medlemskab valideres direkte i LDAP-søgningen.

Projektet består af fire filer:

| Fil | Formål | Ændres? |
|---|---|---|
| `Containerfile` | Bygger image'et (installerer ProFTPD + mod_ldap + mod_tls) | Nej |
| `proftpd.conf.tmpl` | ProFTPD config-skabelon med `${VAR}` placeholders | Nej |
| `entrypoint.sh` | Renderer config, låser data-mappe, exec'er proftpd | Nej |
| `ftp-ldap.container` | Systemd Quadlet unit — **her ligger hele runtime-konfigurationen** | **Ja — redigér ved lab-ændringer** |

De tre første filer taster du én gang og glemmer. Den fjerde indeholder AD-host, service-konto, gruppe-DN og passive-adresse som `Environment=` linjer og er den eneste du skal røre ved når netværket eller AD-strukturen ændrer sig.

## 1. Tillad port 21 for rootless Podman

Port 21 er under 1024 og kræver en sysctl-ændring for at rootless Podman må binde til den:

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=21
echo "net.ipv4.ip_unprivileged_port_start=21" | sudo tee /etc/sysctl.d/99-ftp.conf
```

Ændringen er persistent efter reboot via `sysctl.d`-filen.

## 2. Opret mapper

```bash
mkdir -p /home/h3/data/ftp
mkdir -p /home/h3/.config/containers/systemd
mkdir -p /home/h3/ftp-ldap
cd /home/h3/ftp-ldap
```

## 3. Projekt-filer

Alle fire filer placeres i `/home/h3/ftp-ldap/`. Den sidste (Quadlet'en) flyttes senere til `systemd`-mappen i trin 5.

### 3.1 Containerfile

```dockerfile
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        proftpd-basic \
        proftpd-mod-ldap \
        proftpd-mod-crypto \
        gettext-base \
        ca-certificates \
        openssl && \
    rm -rf /var/lib/apt/lists/* && \
    userdel proftpd 2>/dev/null || true && \
    useradd --uid 1000 --home-dir /srv/ftp --no-create-home \
        --shell /usr/sbin/nologin ftpuser && \
    install -d -o ftpuser -g ftpuser -m 755 /srv/ftp && \
    install -d -o root -g root -m 755 /var/run/proftpd && \
    install -d /etc/ldap && \
    printf 'REFERRALS off\n' >> /etc/ldap/ldap.conf

COPY proftpd.conf.tmpl  /etc/proftpd/proftpd.conf.tmpl
COPY entrypoint.sh      /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 21 50000-50100

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### 3.2 proftpd.conf.tmpl

```
Include /etc/proftpd/modules.conf
LoadModule            mod_ldap.c
LoadModule            mod_tls.c

ServerName            "ftp-ldap"
ServerType            standalone
DefaultServer         on
Port                  21
Umask                 022
MaxInstances          10

User                  ftpuser
Group                 ftpuser

DefaultRoot           /srv/ftp

AllowOverwrite        on
AllowStoreRestart     on
RequireValidShell     off

PassivePorts          ${PASV_MIN_PORT} ${PASV_MAX_PORT}
MasqueradeAddress     ${PASV_ADDRESS}

SystemLog             none
TransferLog           none

<IfModule mod_ldap.c>
  LDAPServer          ldap://${AD_HOST}/??sub
  LDAPBindDN          "${AD_BIND_DN}" "${AD_BIND_PW}"
  LDAPAuthBinds       on
  LDAPSearchScope     subtree

  LDAPUsers           "${AD_BASE_DN}" "(&(objectClass=user)(sAMAccountName=%u)(memberOf=${AD_GROUP_DN}))" "(&(objectClass=user)(uidNumber=%v))"

  LDAPAttr            uid sAMAccountName
  LDAPAttr            gidNumber primaryGroupID

  LDAPDefaultUID      1000
  LDAPDefaultGID      1000
  LDAPForceDefaultUID on
  LDAPForceDefaultGID on

  LDAPGenerateHomedir on
  LDAPGenerateHomedirPrefix /srv/ftp
  LDAPGenerateHomedirPrefixNoUsername on
</IfModule>

AuthOrder             mod_ldap.c
```

### 3.3 entrypoint.sh

```bash
#!/bin/bash
set -euo pipefail

req() { [ -n "${!1:-}" ] || { echo "ERROR: env var $1 is required" >&2; exit 1; }; }
req AD_HOST
req AD_BASE_DN
req AD_BIND_DN
req AD_BIND_PW
req AD_GROUP_DN
req PASV_ADDRESS
: "${PASV_MIN_PORT:=50000}"
: "${PASV_MAX_PORT:=50100}"
export PASV_MIN_PORT PASV_MAX_PORT

envsubst '${AD_HOST} ${AD_BASE_DN} ${AD_BIND_DN} ${AD_BIND_PW} ${AD_GROUP_DN} ${PASV_ADDRESS} ${PASV_MIN_PORT} ${PASV_MAX_PORT}' \
    < /etc/proftpd/proftpd.conf.tmpl > /etc/proftpd/proftpd.conf
chown root:root /etc/proftpd/proftpd.conf
chmod 600 /etc/proftpd/proftpd.conf

# Lås data-mappe: ejes af containerens ftpuser (uid 1000) med mode 700,
# så lokale shell-brugere på Rocky-værten uden sudo ikke kan omgå
# AD-gruppefilteret ved at læse filerne direkte.
chown ftpuser:ftpuser /srv/ftp
chmod 700 /srv/ftp

# Valgfrit: FTPS (TLS). Aktiveres ved at sætte FTPS_ENABLE=YES i Quadlet'en.
if [ "${FTPS_ENABLE:-NO}" = "YES" ]; then
    install -d -o root -g root -m 755 /etc/proftpd/ssl
    CERT=/etc/proftpd/ssl/proftpd.pem
    if [ ! -f "$CERT" ]; then
        openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
            -keyout "$CERT" -out "$CERT" \
            -subj "/CN=ftp-ldap" >/dev/null 2>&1
        chmod 600 "$CERT"
    fi
    cat >> /etc/proftpd/proftpd.conf <<EOF

<IfModule mod_tls.c>
  TLSEngine              on
  TLSRequired            on
  TLSProtocol            TLSv1.2 TLSv1.3
  TLSRSACertificateFile  $CERT
  TLSRSACertificateKeyFile $CERT
  TLSOptions             NoSessionReuseRequired
  TLSVerifyClient        off
</IfModule>
EOF
fi

exec proftpd --nodaemon --config /etc/proftpd/proftpd.conf
```

Gør scriptet eksekverbart efter du har gemt det:

```bash
chmod +x /home/h3/ftp-ldap/entrypoint.sh
```

### 3.4 ftp-ldap.container

Dette er den eneste fil du skal redigere når lab-oplysningerne ændrer sig. Erstat alle `<PLACEHOLDER>` med jeres AD-oplysninger (se tabellen nedenfor).

```ini
[Unit]
Description=ftp-ldap (ProFTPD with AD group filter via mod_ldap)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Container]
ContainerName=ftp-ldap
Image=localhost/ftp-ldap:latest

PublishPort=21:21
PublishPort=50000-50100:50000-50100

Volume=%h/data/ftp:/srv/ftp:Z

# ---- Active Directory ----
Environment=AD_HOST=10.1.80.11
Environment=AD_BASE_DN=DC=<DOMÆNE>,DC=local
Environment=AD_BIND_DN=CN=<SERVICE_ACCOUNT>,OU=<OU_PATH>,DC=<DOMÆNE>,DC=local
Environment=AD_BIND_PW=Kode1234!
Environment=AD_GROUP_DN=CN=FTP-Brugere,OU=<GROUPS_OU>,DC=<DOMÆNE>,DC=local

# ---- Passive FTP ----
Environment=PASV_ADDRESS=10.2.80.11
Environment=PASV_MIN_PORT=50000
Environment=PASV_MAX_PORT=50100

# ---- FTPS (sæt YES for at aktivere TLS) ----
Environment=FTPS_ENABLE=NO

SecurityLabelDisable=true

[Service]
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
```

Erstat placeholders med jeres AD-oplysninger (værdier kommer fra `00-variabler.pdf`):

| Placeholder | Erstat med | Eksempel |
|---|---|---|
| `<SERVICE_ACCOUNT>` | AD service-konto (samme som Nextcloud bruger) | `svc-ldap` |
| `<OU_PATH>` | OU-stien til service-kontoen | `Servicekonti` |
| `<GROUPS_OU>` | OU hvor `FTP-Brugere` gruppen ligger | `Sikkerhedsgrupper` |
| `<DOMÆNE>` | AD-domænenavn (første label) | `h3` |

Fastholdt-IPs (`10.1.80.11` for DC, `10.2.80.11` for denne server) kommer fra `ip-skema.pdf` og ændres kun hvis lab-netværket omlægges.

## 4. Byg container image

Fra `/home/h3/ftp-ldap`:

```bash
cd /home/h3/ftp-ldap
podman build -t localhost/ftp-ldap .
```

Første build tager 1-2 minutter (henter ca. 30 MB Debian-pakker og ProFTPD).

## Forklaring

Hvad hver `Environment=` linje i Quadlet'en gør:

| Indstilling | Formål |
|---|---|
| `AD_HOST` | IP eller hostname på Domain Controller'en |
| `AD_BASE_DN` | LDAP-søgebase (hele domænet) |
| `AD_BIND_DN` | DN på service-kontoen som ProFTPD binder med |
| `AD_BIND_PW` | Password til service-kontoen |
| `AD_GROUP_DN` | Fuld DN på `FTP-Brugere` gruppen — selve gruppe-filteret |
| `PASV_ADDRESS` | IP'en klienter bruger til at nå serveren (annonceres i PASV-svar) |
| `PASV_MIN/MAX_PORT` | Passive mode port-range |
| `FTPS_ENABLE` | `YES` tilføjer TLS-blokken til ProFTPD-config og genererer et selvsigneret certifikat |

## Vigtige detaljer

- **Gruppe-filteret håndhæves i selve LDAP-søgningen** via `LDAPUsers` med en `(memberOf=...)` clause. Brugere der ikke er medlemmer matcher ikke søgningen, og ProFTPD svarer `530 Login incorrect`. Der er ingen cache.
- **`LDAPForceDefaultUID/GID on`** betyder at alle AD-brugere i containeren optræder som lokal `ftpuser` (uid 1000). Du behøver derfor ikke POSIX-attributter (`uidNumber`, `homeDirectory` osv.) på jeres AD-brugere.
- **`LDAPAttr uid sAMAccountName`** fortæller mod_ldap at AD-brugernavne ligger i `sAMAccountName`, ikke det POSIX-`uid` attribut mod_ldap normalt forventer. Uden dette fejler søgningen med "no such user found" selv om filteret matcher.
- **`REFERRALS off`** skrives til `/etc/ldap/ldap.conf` inde i container-imaget. Uden det kommer LDAP-søgninger mod AD til at jagte referrals til `CN=Configuration`, `DomainDnsZones` osv. og timeout'e. Kendt mod_ldap-problem.
- **`chmod 700` på `/srv/ftp`** sættes automatisk af `entrypoint.sh` ved hver container-start. Lokale shell-brugere på Rocky-værten uden sudo får `Permission denied` på `~/data/ftp`, så de kan ikke omgå AD-gruppefilteret ved at læse filerne direkte.
- **Filnavnet `ftp-ldap.container` bestemmer systemd-unit'en**: `ftp-ldap.service`.
- **`sudo loginctl enable-linger h3` er påkrævet** — uden det stoppes containeren når `h3` logger ud.
- **Hvorfor ikke `undying/vsftpd`?** Vi startede med den upstream image fordi det så simplest ud, men `LDAP_FILTER` og `pam_filter` håndhæver ikke gruppe-medlemskab med den gamle `libpam-ldap` library den bruger — alle AD-brugere kan logge ind uanset gruppe. ProFTPD's `mod_ldap` rammer problemet i selve LDAP-søgningen og virker korrekt.

## Adgangsstyring

| Afdeling | FTP-adgang | Begrundelse |
|---|---|---|
| IT | Ja | Systemadministration og vedligeholdelse |
| Marketing | Ja | Upload af website-indhold til WordPress |
| Administration | Nej | Intet behov for datacenter-filadgang |
| Salg | Nej | Intet behov for datacenter-filadgang |
| Udvikling | Nej | Intet behov for datacenter-filadgang |
| Produktion | Nej | Intet behov for datacenter-filadgang |

Adgang styres centralt via AD-gruppen `FTP-Brugere`. Tilføj eller fjern brugere i AD — ændringen slår igennem med det samme i både FTP og Nextcloud.

## Credentials

| Hvad | Bruger | Password |
|---|---|---|
| LDAP bind-konto | `<SERVICE_ACCOUNT>` | `Kode1234!` |
| FTP login | AD-brugernavn (skal være medlem af `FTP-Brugere`) | AD-brugerens password |

## 5. Installér Quadlet og start FTP-serveren

```bash
cp /home/h3/ftp-ldap/ftp-ldap.container \
   /home/h3/.config/containers/systemd/

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

## 7. Test

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

Forventet: `ls: cannot open directory '/home/h3/data/ftp/': Permission denied`. **Dette er korrekt** — mappen er ejet af containerens subuid i mode 700, så lokale brugere på Rocky-værten uden sudo ikke kan omgå AD-gruppefilteret ved at læse filerne direkte.

## 8. Valgfrit: aktivér FTPS (TLS)

For at kryptere FTP-trafik, ændr en enkelt linje i den installerede Quadlet-fil:

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

Forventet: `234 AUTH SSL successful`, TLS 1.3 handshake, og `230 User test1 logged in`. Containeren genererer automatisk et selvsigneret certifikat første gang FTPS aktiveres. I produktion bør man i stedet mounte et certifikat udstedt af **Active Directory Certificate Services** så domain-joined klienter stoler på det uden advarsler.

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
| `Failed to start ftp-ldap.service` | Syntax-fejl i Quadlet'en eller proftpd.conf | Læs journal-loggen — fejlen står i de sidste 10 linjer |
| `curl: (7) Failed to connect to 10.2.80.11 port 21` | Containeren startede ikke eller port 21 er blokeret | `systemctl --user status ftp-ldap.service` + tjek firewall |
| `curl: (67) Access denied: 530` for gyldig bruger | Brugeren er ikke i `FTP-Brugere` gruppen | Tilføj brugeren til gruppen i AD Users and Computers |
| LDAP-søgning timer out | `REFERRALS off` står ikke i `/etc/ldap/ldap.conf` i containeren | Byg imaget igen (Containerfile skriver den linje) |
| `mod_ldap.c not loaded` i log | `proftpd-mod-ldap` ikke installeret eller `LoadModule` mangler | Tjek at Containerfile installerer pakken, og at `proftpd.conf.tmpl` har `LoadModule mod_ldap.c` |
| `response reading failed (errno 115)` ved FTPS | `mod_tls` ikke indlæst | Tjek at `proftpd-mod-crypto` er installeret og `LoadModule mod_tls.c` er med |
| `ls: cannot open directory '/home/h3/data/ftp/'` | **Ikke en fejl** — filsystem-spærringen virker som den skal | (intet at gøre) |
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

Hvis denne kommando returnerer en `dn:` linje, skal brugeren også kunne logge ind via FTP. Hvis den ikke returnerer noget, er brugeren ikke i gruppen — eller filteret matcher ikke AD-strukturen.

## Opsummering

| Komponent | Detalje |
|---|---|
| OS | Rocky Linux 10 |
| Container runtime | Podman (rootless) |
| Base image | debian:trixie-slim |
| FTP daemon | ProFTPD 1.3.8 |
| LDAP modul | proftpd-mod-ldap 2.9 |
| TLS modul (valgfrit) | proftpd-mod-crypto |
| Sysctl | `net.ipv4.ip_unprivileged_port_start=21` (påkrævet for rootless) |
| Autentificering | Active Directory via LDAP (`mod_ldap`) |
| Adgangskontrol | `memberOf` filter i selve LDAP-søgningen — ingen cache |
| Service-konto | Samme bind-konto som Nextcloud bruger |
| Image tag | `localhost/ftp-ldap:latest` |
| Container navn | `ftp-ldap` |
| FTP data (host) | `/home/h3/data/ftp` (mode 700, ejet af containerens subuid) |
| FTP data (container) | `/srv/ftp` |
| Porte | 21 (kontrol) + 50000-50100 (passive) |
| Quadlet unit | `ftp-ldap.container` → `ftp-ldap.service` |
| Runtime config | `Environment=` linjer i Quadlet'en — **ingen separat env-fil** |
| Valgfri TLS | `FTPS_ENABLE=YES` → automatisk selvsigneret certifikat |
| WordPress-integration | FTP-uploads som read-only volume |
| Nextcloud-integration | FTP-uploads via External Storage (FTP backend) |
| Alle credentials | Service-konto password: `Kode1234!` |
| Placering | Site B — datacenter (bag ASA2) |
