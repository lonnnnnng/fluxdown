#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required to cross-build the Windows GUI artifact locally." >&2
  exit 1
fi

docker run --rm --platform "$PLATFORM" \
  -v "$ROOT_DIR:/work" \
  -v fluxdown-cargo-registry:/usr/local/cargo/registry \
  -v fluxdown-cargo-git:/usr/local/cargo/git \
  -w /work \
  rust:1-bookworm \
  bash -lc "set -euo pipefail
    export PATH=\"/usr/local/cargo/bin:\$PATH\"
    apt-get update
    apt-get install -y --no-install-recommends \
      ca-certificates \
      cmake \
      gcc-mingw-w64-x86-64 \
      make \
      nasm \
      perl \
      pkg-config
    rustup target add x86_64-pc-windows-gnu
    cargo build -p fluxdown-desktop --release \
      --target x86_64-pc-windows-gnu \
      --target-dir /work/target-windows-gui-gnu-docker
    mkdir -p /work/dist/windows-gui-gnu
    cp /work/target-windows-gui-gnu-docker/x86_64-pc-windows-gnu/release/fluxdown-desktop.exe \
      /work/dist/windows-gui-gnu/fluxdown-desktop.exe
    cp /work/target-windows-gui-gnu-docker/x86_64-pc-windows-gnu/release/WebView2Loader.dll \
      /work/dist/windows-gui-gnu/WebView2Loader.dll
    ls -lh /work/dist/windows-gui-gnu/fluxdown-desktop.exe \
      /work/dist/windows-gui-gnu/WebView2Loader.dll
  "

node scripts/verify-artifacts.mjs windows-gui
echo "Windows GUI artifacts copied to $ROOT_DIR/dist/windows-gui-gnu"
