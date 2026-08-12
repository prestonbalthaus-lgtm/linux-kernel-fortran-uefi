#!/usr/bin/env bash
# Every compile/test runs inside the rootless podman container.
# The host toolchain and host kernel are never touched.
set -euo pipefail
cd "$(dirname "$0")/.."
exec podman run --rm -v "$PWD:/work:Z" -w /work fortran-kernel-dev:f44 \
     make "$@"
