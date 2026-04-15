FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        vsftpd \
        libpam-ldapd \
        gettext-base \
        ca-certificates \
        openssl && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --uid 1000 --home-dir /home/vsftpd --no-create-home \
        --shell /usr/sbin/nologin ftpuser && \
    install -d -o ftpuser -g ftpuser -m 755 /home/vsftpd

COPY nslcd.conf.tmpl    /etc/nslcd.conf.tmpl
COPY vsftpd.conf.tmpl   /etc/vsftpd.conf.tmpl
COPY pam.vsftpd         /etc/pam.d/vsftpd
COPY entrypoint.sh      /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 21 50000-50100

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
