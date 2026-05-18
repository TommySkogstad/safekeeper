FROM postgres:16.14-alpine@sha256:16bc17c64a573ef34162af9298258d1aec548232985b33ed7b1eac33ba35c229

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
