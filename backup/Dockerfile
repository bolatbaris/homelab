FROM alpine:latest

RUN apk add --no-cache rsync tzdata

ENV TZ=Europe/Istanbul

COPY crontab /etc/crontabs/root
COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

CMD ["crond", "-f", "-l", "2"]
