FROM debian:bookworm-slim

# isync fournit mbsync (1.4.x sur bookworm) ; libsasl2-modules apporte PLAIN/LOGIN,
# libsasl2-modules-kdexoauth2 apporte XOAUTH2 (Microsoft 365), curl + jq servent à oauth2-token.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      isync libsasl2-modules libsasl2-modules-kdexoauth2 curl jq \
      ca-certificates tini gosu tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY src/entrypoint src/healthcheck src/oauth2-token /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint /usr/local/bin/healthcheck /usr/local/bin/oauth2-token

ENV DATA_DIR=/data \
    TZ=Europe/Brussels

VOLUME ["/data"]

HEALTHCHECK --interval=5m --timeout=10s --start-period=2m --retries=2 \
  CMD ["/usr/local/bin/healthcheck"]

# tini -g : propage les signaux à tout le groupe de process (arrêt propre).
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint"]