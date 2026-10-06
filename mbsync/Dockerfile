FROM debian:bookworm-slim

# isync fournit mbsync (1.4.x sur bookworm) ; libsasl2-modules apporte PLAIN/LOGIN.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      isync libsasl2-modules ca-certificates tini gosu tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY src/entrypoint src/healthcheck /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint /usr/local/bin/healthcheck

ENV DATA_DIR=/data \
    TZ=Europe/Brussels

VOLUME ["/data"]

HEALTHCHECK --interval=5m --timeout=10s --start-period=2m --retries=2 \
  CMD ["/usr/local/bin/healthcheck"]

# tini -g : propage les signaux à tout le groupe de process (arrêt propre).
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint"]