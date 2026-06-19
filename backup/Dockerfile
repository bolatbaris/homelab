FROM alpine:latest

RUN apk add --no-cache restic tzdata

ENV TZ=UTC

COPY crontab /etc/crontabs/root
COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

CMD ["crond", "-f", "-l", "2"]
