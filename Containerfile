FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        proftpd-basic \
        proftpd-mod-ldap \
        gettext-base \
        ca-certificates \
        openssl && \
    rm -rf /var/lib/apt/lists/* && \
    userdel proftpd 2>/dev/null || true && \
    useradd --uid 1000 --home-dir /home/vsftpd --no-create-home \
        --shell /usr/sbin/nologin ftpuser && \
    install -d -o ftpuser -g ftpuser -m 755 /home/vsftpd && \
    install -d -o root -g root -m 755 /var/run/proftpd && \
    install -d /etc/ldap && \
    printf 'REFERRALS off\n' >> /etc/ldap/ldap.conf

COPY proftpd.conf.tmpl  /etc/proftpd/proftpd.conf.tmpl
COPY entrypoint.sh      /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 21 50000-50100

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
