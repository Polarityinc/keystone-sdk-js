FROM alpine:3.20
RUN apk add --no-cache socat
COPY sandbox-agent.sh /usr/local/bin/sandbox-agent
RUN chmod +x /usr/local/bin/sandbox-agent
ENTRYPOINT ["/usr/local/bin/sandbox-agent"]
