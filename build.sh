#!/usr/bin/env bash
set -euo pipefail

BINARY="github-agent"
MAIN="./cmd/agent"
DIST="./dist"
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "dev")
BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

LDFLAGS="-s -w -X main.version=${VERSION} -X main.buildTime=${BUILD_TIME}"

do_build() {
  go build -ldflags "${LDFLAGS}" -o "$1" "${MAIN}"
}

mkdir -p "$DIST"

case "${1:-native}" in
  native)
    echo "Building ${BINARY} (native)..."
    do_build "${DIST}/${BINARY}"
    echo "Output: ${DIST}/${BINARY}"
    ;;
  linux)
    echo "Building ${BINARY} (linux/amd64)..."
    GOOS=linux GOARCH=amd64 do_build "${DIST}/${BINARY}-linux-amd64"
    cp "${DIST}/${BINARY}-linux-amd64" "${DIST}/${BINARY}"
    echo "Output: ${DIST}/${BINARY}-linux-amd64 + ${DIST}/${BINARY}"
    ;;
  linux-arm64)
    echo "Building ${BINARY} (linux/arm64)..."
    GOOS=linux GOARCH=arm64 do_build "${DIST}/${BINARY}-linux-arm64"
    cp "${DIST}/${BINARY}-linux-arm64" "${DIST}/${BINARY}"
    echo "Output: ${DIST}/${BINARY}-linux-arm64 + ${DIST}/${BINARY}"
    ;;
  all)
    echo "Building all targets..."
    do_build "${DIST}/${BINARY}"
    GOOS=linux GOARCH=amd64 do_build "${DIST}/${BINARY}-linux-amd64"
    GOOS=linux GOARCH=arm64 do_build "${DIST}/${BINARY}-linux-arm64"
    GOOS=darwin GOARCH=arm64 do_build "${DIST}/${BINARY}-darwin-arm64"
    GOOS=darwin GOARCH=amd64 do_build "${DIST}/${BINARY}-darwin-amd64"
    echo "Output: ${DIST}/"
    ls -lh "${DIST}/"
    ;;
  *)
    echo "Usage: $0 [native|linux|linux-arm64|all]"
    exit 1
    ;;
esac
