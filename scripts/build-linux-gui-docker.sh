#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${FLUXDOWN_LINUX_GUI_BUILD_DIR:-/tmp/fluxdown-linux-gui-build}"
NODE_VERSION="${NODE_VERSION:-22.22.2}"
PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required to build Linux GUI artifacts locally." >&2
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync is required to prepare the isolated Docker build context." >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

rsync -a --delete \
  --exclude ".git" \
  --exclude "node_modules" \
  --exclude "target" \
  --exclude "target-linux-docker" \
  --exclude "target-linux-gui-docker" \
  --exclude "dist/linux-gui" \
  --exclude "apps/mobile/build" \
  "$ROOT_DIR/" "$BUILD_DIR/"

docker run --rm --platform "$PLATFORM" \
  -v "$BUILD_DIR:/work" \
  -v fluxdown-cargo-registry:/usr/local/cargo/registry \
  -v fluxdown-cargo-git:/usr/local/cargo/git \
  -v fluxdown-linux-gui-target:/work/target \
  -w /work \
  rust:1-bookworm \
  bash -lc "set -euo pipefail
    APT_OPTS=\"-o Acquire::Retries=5 -o Acquire::http::Timeout=30\"
    apt-get \$APT_OPTS update
    apt-get \$APT_OPTS install -y --no-install-recommends \
      ca-certificates \
      curl \
      file \
      libayatana-appindicator3-dev \
      librsvg2-dev \
      libwebkit2gtk-4.1-dev \
      patchelf \
      rpm \
      xz-utils
    curl -fsSL \"https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz\" -o /tmp/node.tar.xz
    mkdir -p /opt/node
    tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1
    export PATH=\"/opt/node/bin:/usr/local/cargo/bin:\$PATH\"
    export APPIMAGE_EXTRACT_AND_RUN=1
    node --version
    npm --version
    npm ci
    rm -rf target/release/bundle/deb target/release/bundle/rpm target/release/bundle/appimage
    TAURI_BUNDLES=deb,rpm npm run desktop:build
    if ! TAURI_BUNDLES=appimage npm run desktop:build; then
      echo \"AppImage bundling failed in Docker; continuing with deb/rpm and the raw executable.\" >&2
    fi
    mkdir -p dist/linux-gui
    cp target/release/fluxdown-desktop dist/linux-gui/fluxdown-desktop
    find target/release/bundle -maxdepth 4 -type f \
      \( -name '*.deb' -o -name '*.rpm' -o -name '*.AppImage' \) \
      -print -exec cp {} dist/linux-gui/ \; || true
    node scripts/verify-artifacts.mjs linux-gui
    find dist/linux-gui -maxdepth 1 -type f -exec ls -lh {} \;
  "

rm -rf "$ROOT_DIR/dist/linux-gui"
mkdir -p "$ROOT_DIR/dist/linux-gui"
rsync -a "$BUILD_DIR/dist/linux-gui/" "$ROOT_DIR/dist/linux-gui/"
echo "Linux GUI artifacts copied to $ROOT_DIR/dist/linux-gui"
