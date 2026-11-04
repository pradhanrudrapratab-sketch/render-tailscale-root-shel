# syntax=docker/dockerfile:1

# Pull the official static Tailscale binaries from Tailscale's own image.
# Pin a version with: --build-arg TAILSCALE_TAG=v1.80.0
ARG TAILSCALE_TAG=stable
FROM docker.io/tailscale/tailscale:${TAILSCALE_TAG} AS tailscale

# Render containers lack CAP_AUDIT_WRITE, so Debian's sshd (built with libaudit)
# aborts every login with "linux_audit_write_entry failed: Operation not permitted".
# This shim makes audit_open() report "no audit support" (EAFNOSUPPORT), which
# sshd treats as "skip auditing" instead of "block the login".
FROM debian:bookworm-slim AS noaudit
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev \
 && rm -rf /var/lib/apt/lists/* \
 && printf '#include <errno.h>\nint audit_open(void) { errno = EAFNOSUPPORT; return -1; }\n' > /tmp/noaudit.c \
 && gcc -shared -fPIC -O2 -o /noaudit.so /tmp/noaudit.c

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server \
      python3 \
      ca-certificates \
      procps \
      tini \
      curl \
      nano \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd /var/lib/tailscale /var/run/tailscale

COPY --from=tailscale /usr/local/bin/tailscale  /usr/local/bin/tailscale
COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=noaudit   /noaudit.so               /usr/local/lib/noaudit.so

COPY entrypoint.sh /entrypoint.sh
COPY health.py     /health.py

# Strip Windows line endings (CRLF) just in case, then make executable.
RUN sed -i 's/\r$//' /entrypoint.sh /health.py \
 && chmod +x /entrypoint.sh /health.py

# Render sets $PORT (default 10000). Health server binds to it.
EXPOSE 10000

# tini = proper PID 1 (signal forwarding + zombie reaping). No systemd needed.
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
