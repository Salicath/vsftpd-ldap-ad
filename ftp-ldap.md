# ftp-ldap med Podman Quadlet (ProFTPD + Active Directory)

## Forudsætninger

- Rocky Linux 10
- Bruger: `h3`
- Adgang til en Active Directory Domain Controller
- AD-gruppen `FTP-Brugere` som styrer hvem der må logge ind
- Denne server er placeret på **Site B** (datacenter-siden)

## 1. Installér Podman og forbered bruger

```bash
sudo dnf install -y podman nano
sudo loginctl enable-linger h3
```

Aktivér Podman socket:

```bash
systemctl --user enable --now podman.socket
```

## 2. Tillad rootless binding til port 21

FTP skal lytte på port 21, og rootless Podman må normalt ikke
binde til porte under 1024. Sænk grænsen permanent:

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=21
echo "net.ipv4.ip_unprivileged_port_start=21" | \
    sudo tee /etc/sysctl.d/99-ftp.conf
```

## 3. Opret mapper

```bash
mkdir -p /home/h3/data/ftp
mkdir -p /home/h3/.config/containers/systemd
mkdir -p /home/h3/ftp-ldap
cd /home/h3/ftp-ldap
```

## 4. Projekt-filer

Alle fire filer nedenfor placeres i `/home/h3/ftp-ldap/`. Selve
Quadlet-unit'en i trin 4.4 placeres senere (i trin 6) i
`/home/h3/.config/containers/systemd/`.

### 4.1 Containerfile

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

### 4.2 proftpd.conf.tmpl

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

### 4.3 entrypoint.sh

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

chown ftpuser:ftpuser /srv/ftp
chmod 700 /srv/ftp

if [ "${FTPS_ENABLE:-NO}" = "YES" ]; then
    install -d -o root -g root -m 755 /etc/proftpd/ssl
    CERT=/etc/proftpd/ssl/proftpd.pem
    if [ ! -f "$CERT" ]; then
        echo "FTPS: no cert mounted, generating self-signed"
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

echo "launching proftpd"
exec proftpd --nodaemon --config /etc/proftpd/proftpd.conf
```

Gør scriptet executable efter du har gemt det:

```bash
chmod +x /home/h3/ftp-ldap/entrypoint.sh
```

### 4.4 ftp-ldap.container

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
Environment=AD_HOST=<DC_IP>
Environment=AD_BASE_DN=DC=<DOMAIN>,DC=<TLD>
Environment=AD_BIND_DN=CN=<SERVICE_ACCOUNT>,OU=<OU_PATH>,DC=<DOMAIN>,DC=<TLD>
Environment=AD_BIND_PW=<SERVICE_ACCOUNT_PASSWORD>
Environment=AD_GROUP_DN=CN=<GROUP_NAME>,OU=<OU_PATH>,DC=<DOMAIN>,DC=<TLD>

# ---- Passive FTP ----
Environment=PASV_ADDRESS=<FTP_SERVER_IP>
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

Erstat alle `<PLACEHOLDER>` med rigtige værdier inden du går videre.
Se **Vigtige detaljer** nedenfor for et komplet eksempel.

## 5. Vigtige detaljer

- **Hele konfigurationen ligger i `ftp-ldap.container`**. Ingen
  separat `.env`-fil. Hvis du vil ændre DC-IP, AD-struktur,
  passive-port-område eller FTPS-tilstand, rediger
  `Environment=` linjerne og kør `systemctl --user daemon-reload`
  + `systemctl --user restart ftp-ldap.service`.
- **`DefaultRoot /srv/ftp`** tvinger alle AD-brugere til at
  chroote ind i den mappe, uanset hvad AD siger deres
  hjemmemappe er.
- **`LDAPForceDefaultUID/GID on`** betyder at alle AD-brugere
  i containeren optræder som lokal `ftpuser` (uid 1000). Du
  behøver derfor ikke at udfylde POSIX-attributter på dine
  AD-brugere.
- **Gruppe-filter håndhæves i LDAP-søgningen selv** via
  `(memberOf=${AD_GROUP_DN})`. Brugere der ikke er medlemmer
  matcher slet ikke søgningen, og ProFTPD svarer `530 Login
  incorrect`. Der er ingen cache — fjerner du en bruger fra
  gruppen i AD, er deres næste loginforsøg afvist.
- **`chmod 700` på `/srv/ftp`** sættes automatisk af
  entrypoint.sh, så lokale shell-brugere på Rocky-værten
  uden sudo ikke kan læse FTP-data direkte.
- **`REFERRALS off`** i `/etc/ldap/ldap.conf` (sættes i
  Containerfile) er nødvendig — uden det hænger LDAP-søgninger
  mod AD i referrals til CN=Configuration, DomainDnsZones osv.
- **Filnavnet på `.container`-filen bestemmer systemd-unit'ens
  navn**: `ftp-ldap.container` → `ftp-ldap.service`.
- **`sudo loginctl enable-linger h3` er påkrævet** — uden det
  stoppes alle bruger-containere når du logger ud.

## 6. Credentials

| Hvad | Bruger | Password |
|---|---|---|
| AD bind (service-konto) | svc-ldap | Kode1234! |
| AD test-bruger (medlem af FTP-Brugere) | test1 | Kode1234! |
| Rocky Linux | h3 | Kode1234! |

Alle AD-brugere der er medlemmer af `FTP-Brugere` kan logge ind
med deres AD-password. Alle bliver mappet til lokal `ftpuser`
inden i containeren.

## 7. Eksempel på udfyldt ftp-ldap.container

Her er hvordan Environment-linjerne ser ud for h3.local laboratoriet:

```
Environment=AD_HOST=192.168.1.21
Environment=AD_BASE_DN=DC=h3,DC=local
Environment=AD_BIND_DN=CN=svc-ldap,OU=Servicekonti,DC=h3,DC=local
Environment=AD_BIND_PW=Kode1234!
Environment=AD_GROUP_DN=CN=FTP-Brugere,OU=Sikkerhedsgrupper,DC=h3,DC=local
Environment=PASV_ADDRESS=192.168.1.13
Environment=PASV_MIN_PORT=50000
Environment=PASV_MAX_PORT=50100
Environment=FTPS_ENABLE=NO
```

Til eksamen skal du typisk kun ændre to linjer:

- **`AD_HOST`** — IP-adressen på Domain Controlleren
- **`PASV_ADDRESS`** — IP-adressen på denne Rocky-host

De øvrige linjer afhænger af AD-strukturen, ikke netværks-topologien.

## 8. Byg container image

Fra `/home/h3/ftp-ldap`:

```bash
cd /home/h3/ftp-ldap
podman build -t localhost/ftp-ldap .
```

Første build tager 1-2 minutter (henter ca. 30 MB Debian-pakker).

## 9. Installér Quadlet og start service

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

Forventet: `Active: active (running)` og en container ved navn
`ftp-ldap` i `podman ps`.

## 10. Åbn firewall (hvis firewalld kører)

```bash
sudo firewall-cmd --add-service=ftp --permanent
sudo firewall-cmd --add-port=50000-50100/tcp --permanent
sudo firewall-cmd --reload
```

Hvis `firewall-cmd` ikke findes, kører firewalld ikke — spring
dette trin over.

## 11. Test at det virker

### 11.1 Positiv login (medlem af FTP-Brugere)

```bash
curl --user 'test1:Kode1234!' ftp://<FTP_SERVER_IP>/
```

Forventet: en mappeliste (kan være tom ved første login).

### 11.2 Upload

```bash
echo "hello exam" > /tmp/hi.txt
curl --user 'test1:Kode1234!' -T /tmp/hi.txt ftp://<FTP_SERVER_IP>/
curl --user 'test1:Kode1234!' ftp://<FTP_SERVER_IP>/
```

Den anden `curl` skal vise `hi.txt` i listen.

### 11.3 Negativ test — gruppe-filter

På Windows DC'en: åbn **Active Directory Users and
Computers**, find `test1`, højreklik → **Properties** →
fanen **Member Of** → marker `FTP-Brugere` → **Remove** → **OK**.

Kør derefter den samme `curl` igen:

```bash
curl --user 'test1:Kode1234!' ftp://<FTP_SERVER_IP>/
```

Forventet: `curl: (67) Access denied: 530`. Ingen ventetid,
ingen genstart af service. Tilføj `test1` til gruppen igen
og kør `curl` — det virker med det samme.

### 11.4 Lokal filsystem-spærring

```bash
ls -la /home/h3/data/ftp/
```

Forventet: `ls: cannot open directory '/home/h3/data/ftp/':
Permission denied`. **Dette er korrekt** — mappen er ejet af
containerens subuid i mode 700, så lokale shell-brugere på
Rocky-værten uden sudo kan ikke omgå AD-gruppefilteret ved
at læse filerne direkte.

## 12. Valgfrit: aktivér FTPS (TLS)

Ændr en enkelt linje i den installerede Quadlet-fil:

```bash
sed -i 's/Environment=FTPS_ENABLE=NO/Environment=FTPS_ENABLE=YES/' \
    /home/h3/.config/containers/systemd/ftp-ldap.container

systemctl --user daemon-reload
systemctl --user restart ftp-ldap.service
```

Test med curl (det `-k` flag accepterer det selvsignerede
certifikat):

```bash
curl -kv --ssl-reqd --user 'test1:Kode1234!' \
    ftp://<FTP_SERVER_IP>/ 2>&1 | head -30
```

Forventet: `234 AUTH SSL successful`, TLS 1.3 handshake,
og `230 User test1 logged in`. Containeren genererer
automatisk et selvsigneret certifikat første gang FTPS
aktiveres — til produktion bør man i stedet mounte et
certifikat udstedt af **Active Directory Certificate
Services**, så domain-joined klienter stoler på det uden
advarsler.

## 13. Verificering via kommandolinje

### 13.1 Se at containeren kører og accepterer forbindelser

```bash
systemctl --user status ftp-ldap.service
```

```bash
python3 -c "import socket; s=socket.socket(); s.settimeout(3); \
    s.connect(('<FTP_SERVER_IP>',21)); print(s.recv(200).decode())"
```

Forventet banner: `220 ProFTPD Server (ftp-ldap) [<FTP_SERVER_IP>]`

### 13.2 Test LDAP-filteret direkte mod DC'en

Fra Rocky-værten (udenfor containeren) — installer først
openldap-clients:

```bash
sudo dnf install -y openldap-clients
```

```bash
ldapsearch -x -H ldap://<DC_IP> \
  -D "CN=svc-ldap,OU=<OU_PATH>,DC=<DOMAIN>,DC=<TLD>" -w 'Kode1234!' \
  -b "DC=<DOMAIN>,DC=<TLD>" \
  "(&(objectClass=user)(sAMAccountName=test1)(memberOf=CN=FTP-Brugere,OU=<OU_PATH>,DC=<DOMAIN>,DC=<TLD>))" \
  dn 2>&1 | grep '^dn:'
```

Forventet:
`dn: CN=test1,OU=<OU_PATH>,DC=<DOMAIN>,DC=<TLD>`

Hvis denne søgning returnerer en `dn:` linje skal `test1` også
kunne logge ind via FTP. Hvis den ikke returnerer noget, er
brugeren ikke i gruppen (eller filteret er forkert).

### 13.3 Se service-loggen

```bash
journalctl --user -u ftp-ldap.service --no-pager -n 50
```

Leder du efter specifikke mod_ldap-beskeder:

```bash
journalctl --user -u ftp-ldap.service --no-pager | grep -i ldap
```

## 14. Fejlfinding

| Symptom | Årsag / løsning |
|---|---|
| `curl: (7) Failed to connect to <IP> port 21` lige efter start | Containeren starter stadig. Vent 3-5 sekunder og prøv igen. |
| `curl: (67) Access denied: 530` for en bruger der burde kunne logge ind | Brugeren er ikke i `FTP-Brugere` i AD. Tjek i AD Users and Computers. |
| `Failed to start ftp-ldap.service` | `journalctl --user -u ftp-ldap.service -n 50` — fejlen står i sidste 10 linjer. Typisk en slåfejl i en Environment-linje i Quadlet'en. |
| `ls: cannot open directory '/home/h3/data/ftp/': Permission denied` | **Ikke en fejl.** Filsystem-spærringen virker som den skal. |
| LDAP-søgning timer out | `REFERRALS off` er ikke skrevet til `/etc/ldap/ldap.conf` i containeren. Byg imaget igen. |
| `unknown configuration directive` ved start | Stavfejl i `proftpd.conf.tmpl` eller en direktiv der ikke findes i denne ProFTPD-version. |

## 15. Opsummering

| Komponent | Detalje |
|---|---|
| OS | Rocky Linux 10 |
| Container runtime | Podman (rootless) |
| Arkitektur | En enkelt container med ProFTPD + mod_ldap + mod_tls |
| Base image | debian:trixie-slim |
| FTP daemon | ProFTPD 1.3.8 |
| Autentificering | LDAP mod Active Directory via mod_ldap |
| Adgangskontrol | `memberOf` filter i LDAP-søgningen |
| Image tag | localhost/ftp-ldap:latest |
| Container navn | ftp-ldap |
| Data mappe (host) | /home/h3/data/ftp (mode 700, containerens subuid) |
| Data mappe (container) | /srv/ftp |
| Lytter på | port 21 + 50000-50100 (passive) |
| Quadlet fil | /home/h3/.config/containers/systemd/ftp-ldap.container |
| Systemd unit | ftp-ldap.service (user scope) |
| Konfiguration | Environment= linjer i ftp-ldap.container |
| Valgfri TLS | FTPS_ENABLE=YES → automatisk selvsigneret cert |
| Placering | Site B — datacenter |
