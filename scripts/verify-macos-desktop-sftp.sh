#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in cargo shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    exit 1
  fi
done

export FLUXDOWN_DESKTOP_SFTP_SOURCE="sftp://demo:password@test.rebex.net/readme.txt"
export FLUXDOWN_DESKTOP_SFTP_FILE_NAME="rebex-readme.txt"
export FLUXDOWN_DESKTOP_SFTP_SHA256="b004de45d8a133e9713a369f9c912237e8ad35dd9140c0279d27bada067797f4"

echo "macOS desktop SFTP fixture"
echo "  source: $FLUXDOWN_DESKTOP_SFTP_SOURCE"
echo "  file:   $FLUXDOWN_DESKTOP_SFTP_FILE_NAME"
echo "  sha256: $FLUXDOWN_DESKTOP_SFTP_SHA256"

cd "$ROOT_DIR"
cargo test -p fluxdown-desktop desktop_manual_downloads_public_sftp_task_through_queue -- --ignored --nocapture
