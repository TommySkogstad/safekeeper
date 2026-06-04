FROM postgres:17.10-alpine@sha256:979c4379dd698aba0b890599a6104e082035f98ef31d9b9291ec22f2b13059ca

RUN apk add --no-cache \
    bash \
    gzip \
    gnupg \
    openssh-client \
    tzdata

ENV TZ=Europe/Oslo

COPY backup-entrypoint.sh /usr/local/bin/
COPY restore.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup-entrypoint.sh /usr/local/bin/restore.sh && \
    mkdir -p /backups

ENTRYPOINT ["/usr/local/bin/backup-entrypoint.sh"]
