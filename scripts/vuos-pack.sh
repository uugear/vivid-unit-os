#!/usr/bin/env bash
set -euo pipefail

TOPDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$TOPDIR/scripts/lib/pack.sh"

vuos_pack_main "$@"
