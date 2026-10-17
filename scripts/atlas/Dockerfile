# syntax=docker/dockerfile:1
FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY guest_server/go.mod guest_server/go.sum ./
RUN --mount=type=secret,id=proxy_ca --mount=type=cache,target=/go/pkg/mod \
    set -eu; \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca; fi; \
    go mod download
COPY guest_server/*.go ./
ARG WINBOAT_BUILD_COMMIT=unknown
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    set -eu; \
    go test terminal_sessions.go terminal_sessions_test.go; \
    go test helios_status.go helios_status_test.go atlas_status.go atlas_status_test.go atlas_diagnostics.go atlas_diagnostics_test.go atlas_recovery.go atlas_recovery_test.go; \
    GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build \
      -ldflags="-X main.Version=0.8.7 -X main.CommitHash=$WINBOAT_BUILD_COMMIT -X main.BuildTimestamp=$(date -u +%Y-%m-%dT%H:%M:%S)" \
      -o /out/winboat_guest_server.exe .
FROM scratch AS artifacts
COPY --from=build /out/ /
