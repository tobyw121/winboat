# syntax=docker/dockerfile:1
FROM golang:1.25-bookworm@sha256:3b4a11519ad929d1e1d261a12cff056f0c85b735253d7d861346b9c6f8b36437 AS go
FROM docker:28-cli@sha256:625d9431a9f54c5a2bc90f24f0e1c3d55b1349fd857dd85035f98c2c9acbdd4d AS dockercli

FROM node:24-bookworm-slim@sha256:a5f4366e834695d5f363b920c104953a535d3a9864d1bdf74566a0ebe01daee5 AS viewer-toolchain
RUN --mount=type=secret,id=proxy_ca \
    set -eu; \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca; fi; \
    apt-get ${SSL_CERT_FILE:+-o Acquire::https::CaInfo=$SSL_CERT_FILE} update; \
    apt-get ${SSL_CERT_FILE:+-o Acquire::https::CaInfo=$SSL_CERT_FILE} install -y --no-install-recommends \
      build-essential pkg-config libgtk-4-dev libepoxy-dev xvfb xauth dbus python3-gi \
      libgl1-mesa-dri mesa-utils; \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src

FROM viewer-toolchain AS native-viewer
RUN --mount=type=bind,target=/source \
    bash /source/native/helios-viewer/build.sh /out/winboat-helios-viewer

# Override with --build-context installer=/path/to/verified/windows-artifact.
FROM scratch AS installer
COPY resources/helios/ /

FROM node:24-bookworm-slim@sha256:a5f4366e834695d5f363b920c104953a535d3a9864d1bdf74566a0ebe01daee5 AS toolchain
RUN --mount=type=secret,id=proxy_ca \
    set -eu; \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca; fi; \
    apt-get ${SSL_CERT_FILE:+-o Acquire::https::CaInfo=$SSL_CERT_FILE} update; \
    apt-get ${SSL_CERT_FILE:+-o Acquire::https::CaInfo=$SSL_CERT_FILE} install -y --no-install-recommends \
      ca-certificates git curl unzip zip python3 build-essential pkg-config \
      libudev-dev libusb-1.0-0-dev rpm xz-utils; \
    rm -rf /var/lib/apt/lists/*
COPY --from=go /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH
ENV GOPATH=/go GOTOOLCHAIN=local
WORKDIR /src
COPY package.json package-lock.json .npmrc ./
RUN --mount=type=secret,id=proxy_ca \
    --mount=type=cache,target=/root/.npm \
    set -eu; \
    if [ -f /run/secrets/proxy_ca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/proxy_ca; fi; \
    ELECTRON_GET_USE_PROXY=1 npm ci --strict-ssl=true

FROM toolchain AS build
ARG WINBOAT_BUILD_COMMIT=unknown
ARG PACKAGE_TARGETS=AppImage
ENV WINBOAT_BUILD_COMMIT=$WINBOAT_BUILD_COMMIT
RUN --mount=type=secret,id=proxy_ca \
    --mount=type=secret,id=github_token \
    --mount=type=bind,target=/context \
    --mount=from=installer,target=/installer \
    --mount=from=native-viewer,source=/out,target=/native-viewer \
    --mount=from=dockercli,source=/usr/local/bin/docker,target=/usr/local/bin/docker \
    --mount=from=dockercli,source=/usr/local/libexec/docker/cli-plugins,target=/usr/local/libexec/docker/cli-plugins \
    --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/electron-builder \
    set -eu; \
    if [ -f /run/secrets/proxy_ca ]; then \
      export NODE_EXTRA_CA_CERTS=/run/secrets/proxy_ca SSL_CERT_FILE=/run/secrets/proxy_ca \
        CURL_CA_BUNDLE=/run/secrets/proxy_ca GIT_SSL_CAINFO=/run/secrets/proxy_ca; \
    fi; \
    cp -a /context/. /src/; \
    rm -rf resources/helios; mkdir -p resources/helios; \
    for file in HeliosSetup.exe helios-build.json; do \
      if [ -e "/installer/$file" ]; then cp -a "/installer/$file" resources/helios/; fi; \
    done; \
    bash scripts/helios/build-app.sh "$PACKAGE_TARGETS"

# BuildKit exports only finished packages; no compilers, node_modules or source.
FROM scratch AS artifacts
COPY --from=build /out/ /
