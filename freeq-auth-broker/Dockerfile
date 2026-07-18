# Standalone container build for freeq-auth-broker (used for direct Docker
# deploys, e.g. the Hetzner box behind auth.freeq.at). Build from the REPO
# ROOT so the workspace manifests resolve:
#
#   docker build -f freeq-auth-broker/Dockerfile -t freeq-auth-broker .
#   docker run -d --name freeq-auth-broker --restart unless-stopped \
#     -p 127.0.0.1:8081:8081 -v freeq-broker-data:/data \
#     --env-file /root/freeq-broker.env freeq-auth-broker
#
# Required env: BROKER_SHARED_SECRET, BROKER_PUBLIC_URL, FREEQ_SERVER_URL.
# Sessions persist in the /data volume (BROKER_DB_PATH).

FROM rust:1-slim-bookworm AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends pkg-config libssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN cargo build --release -p freeq-auth-broker

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libssl3 curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/freeq-auth-broker /usr/local/bin/freeq-auth-broker
ENV BROKER_DB_PATH=/data/broker.db
VOLUME /data
EXPOSE 8081
HEALTHCHECK --interval=30s --timeout=5s CMD curl -sf http://127.0.0.1:8081/health || exit 1
CMD ["freeq-auth-broker"]
