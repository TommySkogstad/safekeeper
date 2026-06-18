FROM postgres:17-alpine@sha256:0a8a1e76503c091f0feb387d51b10fcd746c2d61cf6cdd6e8356973a45e40a0f

RUN apk update && apk upgrade --no-cache && apk add --no-cache \
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
