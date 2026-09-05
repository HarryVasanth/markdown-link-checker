FROM alpine:3

COPY check-links.sh /check-links.sh
RUN chmod +x /check-links.sh && \
    apk add --no-cache bash curl jq perl findutils coreutils

ENTRYPOINT ["/check-links.sh"]
