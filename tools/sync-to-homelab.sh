#!/usr/bin/env bash
# Mirror this project into the homelab monorepo at linux-fortran-kernel/.
# Deliberately excludes vendor/ (1.7 GB of upstream kernel source) and build/.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-/home/prestonalthaus/claude/homelab-work}/linux-fortran-kernel"

mkdir -p "$DEST"
rsync -a --delete \
  --exclude '.git/' \
  --exclude 'vendor/' \
  --exclude 'build/' \
  --exclude '*.o' --exclude '*.mod' --exclude '*.smod' \
  "$SRC/" "$DEST/"
echo "synced -> $DEST"
du -sh "$DEST"
