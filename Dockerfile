FROM postgres:19.0-alpine@sha256:8b0ff4cdf221f0c53d7fcda681d3b461be725c492cd881c5ec9c0ad25023f188

RUN apk update && apk upgrade --no-cache && apk add --no-cache \
    bash \
    gzip \
    gnupg \
    openssh-client \
    tzdata

# gosu kalles kun av postgres sin docker-entrypoint.sh, som dette imaget aldri kjorer
# (ENTRYPOINT er backup-entrypoint.sh) — fjernes sa sikkerhetsskann ikke flagger
# Go stdlib-CVE-er i en ubrukt binaer (jf. maskemester#171)
RUN rm -f /usr/local/bin/gosu

ENV TZ=Europe/Oslo

COPY backup-entrypoint.sh /usr/local/bin/
COPY restore.sh /usr/local/bin/
# Verifiserte Hetzner StorageBox-flaatenokler — global known_hosts leses av
# ssh/sftp uten at /root/.ssh trenger persistering (safekeeper#190)
COPY ssh_known_hosts /etc/ssh/ssh_known_hosts
RUN chmod +x /usr/local/bin/backup-entrypoint.sh /usr/local/bin/restore.sh && \
    mkdir -p /backups

ENTRYPOINT ["/usr/local/bin/backup-entrypoint.sh"]
