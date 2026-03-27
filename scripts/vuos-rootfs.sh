#!/usr/bin/env bash
set -euo pipefail

# Thin wrapper that can be called from anywhere.
TOPDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$TOPDIR/scripts/lib/rootfs.sh"

vuos_rootfs_main "$@"
