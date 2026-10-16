# syntax=docker/dockerfile:1
FROM ghcr.io/dockur/windows:5.07@sha256:00d59df9af7cfc6e8cd7137c52f126f9671c773fee10adcf8fc75aafedfb5052 AS builder
ARG HELIOS_BUILD_JOBS=4
# The optional build secret is the session's trusted CA bundle, never an image layer.
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca GIT_SSL_CAINFO=/run/secrets/proxy_ca CURL_CA_BUNDLE=/run/secrets/proxy_ca PIP_CERT=/run/secrets/proxy_ca; fi; \
    set -eu; \
    apt-get ${SSL_CERT_FILE:+-o Acquire::https::CaInfo=$SSL_CERT_FILE} update; \
    apt-get ${SSL_CERT_FILE:+-o Acquire::https::CaInfo=$SSL_CERT_FILE} install -y --no-install-recommends \
      git build-essential pkg-config python3 python3-pip python3-venv python3-mako python3-yaml \
      python3-setuptools meson ninja-build bison flex libglib2.0-dev libpixman-1-dev \
      libepoxy-dev libegl-dev libgbm-dev libdrm-dev libvulkan-dev libssl-dev \
      libslirp-dev libcap-ng-dev libattr1-dev libusb-1.0-0-dev libspice-server-dev \
      libusbredirparser-dev liburing-dev libaio-dev libzstd-dev libpng-dev libjpeg-dev check cmake
COPY helios/host/fetch-stack.sh /fetch-stack.sh
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca GIT_SSL_CAINFO=/run/secrets/proxy_ca CURL_CA_BUNDLE=/run/secrets/proxy_ca; fi; \
    bash /fetch-stack.sh
COPY helios/host/build-stack.sh /build-stack.sh
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca GIT_SSL_CAINFO=/run/secrets/proxy_ca CURL_CA_BUNDLE=/run/secrets/proxy_ca; fi; \
    bash /build-stack.sh
# Runtime shares the builder's Debian ABI without shipping its compiler/source tree.
FROM ghcr.io/dockur/windows:5.07@sha256:00d59df9af7cfc6e8cd7137c52f126f9671c773fee10adcf8fc75aafedfb5052 AS runtime
RUN --mount=type=secret,id=proxy_ca \
    set -eu; \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca; fi; \
    apt-get ${SSL_CERT_FILE:+-o Acquire::https::CaInfo=$SSL_CERT_FILE} update; \
    apt-get ${SSL_CERT_FILE:+-o Acquire::https::CaInfo=$SSL_CERT_FILE} install -y --no-install-recommends \
      libglib2.0-0t64 libpixman-1-0 libepoxy0 libegl1 libgbm1 libdrm2 libvulkan1 \
      libssl3t64 libslirp0 libcap-ng0 libattr1 libusb-1.0-0 libspice-server1 \
      libusbredirparser1 liburing2 libaio1t64 libzstd1 libpng16-16t64 libjpeg62-turbo \
      mesa-vulkan-drivers libegl-mesa0 libgl1-mesa-dri; \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/helios /opt/helios
LABEL org.winboat.helios.revision="d82ce565ac792eb48da5e59f2a82a12ff221851d"
COPY --chmod=755 helios/host/display.sh /run/display.sh
COPY --chmod=755 helios/host/qemu.sh /usr/bin/qemu-system-x86_64
COPY --chmod=755 helios/host/qemu.sh /usr/local/bin/qemu-system-x86_64
RUN /usr/bin/qemu-system-x86_64 --version && \
    /usr/bin/qemu-system-x86_64 -device virtio-gpu-gl-pci,help | grep venus
ENV HELIOS=1 HELIOS_REVISION=d82ce565ac792eb48da5e59f2a82a12ff221851d
