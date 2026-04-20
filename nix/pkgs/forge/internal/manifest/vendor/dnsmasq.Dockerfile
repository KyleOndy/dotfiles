FROM alpine:3.21
RUN apk add --no-cache dnsmasq
EXPOSE 53/udp 53/tcp
ENTRYPOINT ["dnsmasq", "-k", "--log-facility=-"]
