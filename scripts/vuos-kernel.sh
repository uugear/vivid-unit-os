#!/usr/bin/env bash
set -euo pipefail

# Thin wrapper that can be called from anywhere.
TOPDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$TOPDIR/scripts/lib/kernel.sh"

vuos_kernel_main "$@"
