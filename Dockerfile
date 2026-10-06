# syntax=docker/dockerfile:1
#
# Runtime image for the fips-peer Helm chart.
#
# Installs the released FIPS Debian package (no systemd) and runs the daemon
# via entrypoint.sh, which enables IPv6 forwarding in the pod network
# namespace and loads the default-deny nftables baseline once fips0 exists.
#
# Build:
#   podman build --build-arg FIPS_VERSION=0.5.2 -t ghcr.io/notmandatory/fips-peer:0.5.2 .
#
# FIPS_DEB_URL overrides the download URL entirely and FIPS_DEB_SHA256 pins
# the artifact when set.

ARG DEBIAN_BASE=debian:trixie-slim
FROM ${DEBIAN_BASE}

ARG FIPS_REPO=jmcorgan/fips
ARG FIPS_VERSION=0.5.2
ARG FIPS_DEB_ARCH=amd64
ARG FIPS_DEB_URL=
ARG FIPS_DEB_SHA256=

# dpkg-deb -x extracts the package instead of installing it: installing would
# pull in the declared Depends: systemd, which the container never uses. The
# runtime libraries the binaries actually link are installed by hand: libc6
# (in the base) and libdbus-1-3. iproute2 provides `ip` (entrypoint waits for
# fips0), nftables provides `nft` (mesh firewall baseline), procps provides
# `sysctl` (IPv6 forwarding), ca-certificates is for outbound TLS.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        iproute2 \
        nftables \
        procps \
        libdbus-1-3; \
    if [ -z "${FIPS_DEB_URL}" ]; then \
        test -n "${FIPS_VERSION}" || { echo "set FIPS_VERSION or FIPS_DEB_URL" >&2; exit 1; }; \
        FIPS_DEB_URL="https://github.com/${FIPS_REPO}/releases/download/v${FIPS_VERSION}/fips_${FIPS_VERSION}_${FIPS_DEB_ARCH}.deb"; \
    fi; \
    curl --retry 3 --retry-connrefused --proto '=https' --tlsv1.2 -fsSL \
        "${FIPS_DEB_URL}" -o /tmp/fips.deb; \
    if [ -n "${FIPS_DEB_SHA256}" ]; then \
        echo "${FIPS_DEB_SHA256}  /tmp/fips.deb" | sha256sum -c -; \
    fi; \
    dpkg-deb -x /tmp/fips.deb /tmp/fips-root; \
    install -d -m 0755 /etc/fips; \
    cp -a /tmp/fips-root/usr/. /usr/; \
    cp -a /tmp/fips-root/etc/fips/. /etc/fips/; \
    install -d -m 0750 -o root -g root /run/fips /var/log/fips; \
    rm -rf /tmp/fips.deb /tmp/fips-root /var/lib/apt/lists/*; \
    /usr/bin/fips --version

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--config", "/etc/fips/fips.yaml"]
