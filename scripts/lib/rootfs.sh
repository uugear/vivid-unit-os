#!/usr/bin/env bash
# Rootfs build logic for Vivid Unit OS.
#
# This file is intended to be sourced by scripts/vuos-rootfs.sh.
#
# High-level goals:
# - Build an arm64 Debian rootfs directory using mmdebstrap
# - Apply overlay directories as if they were '/' in the rootfs
# - Optionally pack the rootfs directory into an ext4 image (rootfs.img)
# - Keep outputs under out/rootfs/<target>/

set -euo pipefail

_vuos_rootfs_usage() {
  cat >&2 <<'USAGE'
Usage:
  vuos rootfs <target> [options]

Options:
  --clean                 Remove output directory before building
  --no-image              Do not create ext4 image (only out/.../rootfs dir)
  --img-size <SIZE>       Size for ext4 image (default: 3800M)
  --mirror <URL>          Debian mirror (default: http://deb.debian.org/debian)
  --components <LIST>     Debian components (default: main)

Environment variables:
  OUT_DIR                 Top-level output dir (default: <repo>/out)
  ARCH                    (default: from board.toml, usually arm64)
  ROOTFS_SUITE            (default: from board.toml, usually bookworm)
  ROOTFS_VARIANT          (default: from board.toml, usually minbase)
  MMDEBSTRAP_MODE         Optional mmdebstrap mode (e.g. unshare, root)

Notes:
  - This stage does not (yet) import vendor blobs or kernel modules.
    Those can be merged later in a pack/assemble stage.
  - Overlay directories listed in board.toml [rootfs] are applied in order.
USAGE
}

_vuos_rootfs_find_topdir() {
  # scripts/lib/rootfs.sh -> scripts/lib -> scripts -> repo
  local here
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  (cd -- "$here/../.." && pwd)
}

_vuos_rootfs_assert_safe_path() {
  local path="$1"
  path="$(vuos_abspath "$path")"

  [[ -n "$path" ]] || vuos_die "Refusing empty path"
  [[ "$path" != "/" ]] || vuos_die "Refusing to operate on /"
  [[ "$path" == */out/rootfs/* ]] || vuos_die "Refusing unexpected rootfs path: $path"
}

_vuos_rootfs_prepare_clean_path() {
  local path="$1"
  path="$(vuos_abspath "$path")"

  _vuos_rootfs_assert_safe_path "$path"
  [[ -e "$path" ]] || return 0

  if vuos_mounts_under "$path"; then
    vuos_warn "Active mounts detected under $path; attempting recursive unmount"
    findmnt -R "$path" >&2 || true
    vuos_umount_tree "$path"
    sync
  fi

  vuos_die_if_mounts_under "$path"
}

_vuos_rootfs_require_no_mounts() {
  local path="$1"
  path="$(vuos_abspath "$path")"

  _vuos_rootfs_assert_safe_path "$path"
  [[ -e "$path" ]] || return 0

  if vuos_mounts_under "$path"; then
    echo "ERROR: refusing to remove $path because active mounts still exist underneath it:" >&2
    findmnt -R "$path" >&2 || true
    echo "ERROR: please unmount the paths above manually before re-running the build." >&2
    exit 1
  fi
}


_vuos_rootfs_load_board_manifest() {
  local topdir="$1" target="$2"
  local manifest="$topdir/boards/$target/board.toml"
  local py="$topdir/scripts/lib/manifest.py"

  [[ -f "$manifest" ]] || vuos_die "Board manifest not found: $manifest"
  [[ -f "$py" ]] || vuos_die "manifest.py not found: $py"

  # Load TOML -> shell variables into current shell.
  # NOTE: arrays (e.g. ROOTFS_OVERLAYS) cannot be exported, so we must eval here.
  eval "$(python3 "$py" "$manifest" --topdir "$topdir")"
}

_vuos_rootfs_read_pkg_file() {
  # Read a line-based package list file.
  # - empty lines and comments are ignored
  # - commas are allowed but not required
  local f="$1"
  [[ -f "$f" ]] || return 0
  sed -e 's/#.*$//' -e 's/[[:space:]]\+$//' -e '/^[[:space:]]*$/d' "$f" \
    | tr ',' '\n' \
    | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//' -e '/^$/d'
}

_vuos_rootfs_default_packages() {
  # Legacy fallback list.
  # NOTE: Starting from .05, the default package lists are moved into files:
  #   - rootfs/common/packages.base
  #   - rootfs/suites/<suite>/packages.desktop
  # This function is kept only for backward-compatibility but should no longer
  # be used in normal builds.
  cat <<'PKGS'
sudo
ca-certificates
locales
tzdata
PKGS
}

_vuos_rootfs_collect_packages() {
  local topdir="$1" suite="$2"

  local -a pkgs=()

  # Optional package files (line-based) if you create them later.
  # These are NOT required.
  local f
  f="$topdir/rootfs/common/packages.base"
  if [[ -f "$f" ]]; then
    while IFS= read -r p; do pkgs+=("$p"); done < <(_vuos_rootfs_read_pkg_file "$f")
  fi

  f="$topdir/rootfs/suites/$suite/packages.desktop"
  if [[ -f "$f" ]]; then
    while IFS= read -r p; do pkgs+=("$p"); done < <(_vuos_rootfs_read_pkg_file "$f")
  fi

  # Enforce package files exist. We intentionally avoid embedding large package
  # lists in scripts to keep the build system maintainable.
  if ((${#pkgs[@]} == 0)); then
    vuos_die "No package list files found. Please create:\n  - $topdir/rootfs/common/packages.base\n  - $topdir/rootfs/suites/$suite/packages.desktop"
  fi

  # De-duplicate, keep stable ordering.
  # shellcheck disable=SC2207
  pkgs=($(printf '%s\n' "${pkgs[@]}" | sed '/^$/d' | awk '!seen[$0]++'))

  printf '%s\n' "${pkgs[@]}"
}

_vuos_rootfs_apply_overlays() {
  local rootfs_dir="$1"; shift
  local -a overlays=("$@")

  ((${#overlays[@]})) || return 0

  local ov
  for ov in "${overlays[@]}"; do
    if [[ ! -d "$ov" ]]; then
      vuos_warn "Overlay not found (skip): $ov"
      continue
    fi
    vuos_log "Applying overlay: $ov"
    # Treat overlay root as '/'
    rsync -aHAX --numeric-ids --no-owner --no-group --exclude='.DS_Store' --exclude='__MACOSX' "$ov/" "$rootfs_dir/"
  done
  
  chown root:root "$rootfs_dir" "$rootfs_dir/etc" "$rootfs_dir/etc/xdg"
  chmod 0755      "$rootfs_dir" "$rootfs_dir/etc" "$rootfs_dir/etc/xdg"
  find "$rootfs_dir/etc/xdg" -type d -exec chmod 0755 {} +
  find "$rootfs_dir/etc/xdg" -type f -exec chmod go-w {} +
}

_vuos_rootfs_make_ext4_image() {
  local rootfs_dir="$1" img="$2" img_size="$3"

  # Create and populate an ext4 filesystem image.
  # NOTE: We intentionally DO NOT shrink the image here. Shrinking should be
  # done later in the pack stage after kernel/modules and other payloads are
  # merged into the final image.
  vuos_need_cmd truncate mkfs.ext4 mount umount rsync du awk

  # Basic size sanity check (best-effort)
  local bytes_required bytes_img
  bytes_required=$(du -xsb "$rootfs_dir" | awk '{print $1}')

  # Convert size string to bytes (supports M/G suffix)
  bytes_img=$(python3 - <<'PY' "$img_size"
import re, sys

s = sys.argv[1].strip()
m = re.match(r'^([0-9]+)([KMG]?)$', s, re.I)
if not m:
    print(0)
    raise SystemExit(0)

n = int(m.group(1))
u = m.group(2).upper()
mul = {'': 1, 'K': 1024, 'M': 1024**2, 'G': 1024**3}.get(u, 1)
print(n * mul)
PY
) || bytes_img=0

  if [[ "$bytes_img" -gt 0 && "$bytes_required" -gt "$bytes_img" ]]; then
    vuos_die "rootfs appears too large for image size $img_size (need ~${bytes_required} bytes)"
  fi

  rm -f "$img"
  truncate -s "$img_size" "$img"
  mkfs.ext4 -F -L rootfs "$img" >/dev/null

  # Use a subshell so the cleanup trap cannot leak outside this function.
  (
    set -euo pipefail
    mnt="$(mktemp -d)"
    trap 'umount -q "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT

    mount -o loop "$img" "$mnt"
    rsync -aHAXx --numeric-ids "$rootfs_dir/" "$mnt/"
    sync
    umount "$mnt"
    rmdir "$mnt"
  )

}

_vuos_rootfs_run_hooks() {
  # Run hooks after overlays, before packing the rootfs image.
  #
  # Hook directories (in order):
  #   1) rootfs/common/hooks
  #   2) rootfs/suites/<suite>/hooks
  #   3) boards/<target>/hooks
  #
  # Hook scripts must be executable and named like: NN-description
  # Each hook receives the rootfs directory as its first argument.
  local topdir="$1" target="$2" suite="$3" rootfs_dir="$4"

  vuos_need_cmd find sort

  _vuos_rootfs_assert_safe_path "$rootfs_dir"
  _vuos_rootfs_prepare_clean_path "$rootfs_dir"

  local -a hook_dirs=(
    "$topdir/rootfs/common/hooks"
    "$topdir/rootfs/suites/$suite/hooks"
    "$topdir/boards/$target/hooks"
  )

  local -a hooks=()
  local d
  for d in "${hook_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d '' f; do
      hooks+=("$f")
    done < <(find "$d" -maxdepth 1 -type f -name '[0-9][0-9]-*' -perm -u=x -print0 | sort -z)
  done

  ((${#hooks[@]})) || { vuos_log "No hooks found (skip)"; return 0; }

  # Export common context for hooks.
  export TOPDIR="$topdir"
  export TARGET="$target"
  export ROOTFS_SUITE="$suite"
  export ROOTFS_DIR="$rootfs_dir"

  # Backward compatible variables (customize used these names)
  export VU_USER="${VU_USER:-${VUOS_USER:-vivid}}"
  export VU_PASS="${VU_PASS:-${VUOS_PASS:-unit}}"
  export VU_VNC_PASS="${VU_VNC_PASS:-${VUOS_VNC_PASS:-unit}}"
  export VU_HOSTNAME="${VU_HOSTNAME:-${VUOS_HOSTNAME:-$target}}"
  export VU_TZ="${VU_TZ:-${VUOS_TZ:-Europe/Amsterdam}}"
  export VU_LOCALE="${VU_LOCALE:-${VUOS_LOCALE:-en_US.UTF-8}}"
  export XORG_DRIVER="${XORG_DRIVER:-${VUOS_XORG_DRIVER:-modesetting}}"
  export VU_KMSDEV="${VU_KMSDEV:-${VUOS_KMSDEV:-/dev/dri/card1}}"

  # Run the chroot hook phase in a private mount namespace. This prevents any
  # mount/remount activity inside hooks (or package maintainer scripts they
  # trigger) from mutating the host's /dev,/dev/pts,/proc,/sys state.
  local hooks_file common_sh
  hooks_file="$(mktemp)"
  common_sh="$topdir/scripts/lib/common.sh"
  printf '%s\0' "${hooks[@]}" > "$hooks_file"

  export TOPDIR TARGET ROOTFS_SUITE ROOTFS_DIR
  export VU_USER VU_PASS VU_VNC_PASS VU_HOSTNAME VU_TZ VU_LOCALE XORG_DRIVER VU_KMSDEV
  export HOOKS_FILE="$hooks_file"
  export COMMON_SH="$common_sh"

  unshare --mount --propagation private --fork -- bash -s <<'EOS'
set -euo pipefail
source "$COMMON_SH"

cleanup() {
  vuos_chroot_umount "$ROOTFS_DIR" || true
}
trap cleanup EXIT INT TERM

vuos_chroot_mount "$ROOTFS_DIR"

while IFS= read -r -d '' h; do
  vuos_log "Running hook: ${h#$TOPDIR/}"
  "$h" "$ROOTFS_DIR"
done < "$HOOKS_FILE"
EOS

  rm -f "$hooks_file"

  # Paranoia: ensure nothing remains mounted underneath the rootfs path after
  # the hook namespace exits before any later rm -rf or image packing touches it.
  _vuos_rootfs_prepare_clean_path "$rootfs_dir"
}

vuos_rootfs_main() {
  local topdir
  topdir="$(_vuos_rootfs_find_topdir)"

  # shellcheck source=/dev/null
  source "$topdir/scripts/lib/common.sh"

  local target="${1:-}"; shift || true
  [[ -n "$target" ]] || { _vuos_rootfs_usage; exit 2; }

  local do_clean=0 do_image=1
  local img_size="${ROOTFS_IMG_SIZE:-3800M}"
  local mirror="${MIRROR:-http://deb.debian.org/debian}"
  local components="${COMPONENTS:-main}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clean) do_clean=1; shift ;;
      --no-image) do_image=0; shift ;;
      --img-size) img_size="${2:?missing value for --img-size}"; shift 2 ;;
      --mirror) mirror="${2:?missing value for --mirror}"; shift 2 ;;
      --components) components="${2:?missing value for --components}"; shift 2 ;;
      -h|--help) _vuos_rootfs_usage; exit 0 ;;
      *) vuos_die "Unknown option: $1" ;;
    esac
  done

  # mmdebstrap usually requires root when run in root mode.
  if [[ "${EUID:-$(id -u)}" != "0" ]]; then
    vuos_die "Please run as root (e.g. sudo ./vuos rootfs $target)."
  fi

  _vuos_rootfs_load_board_manifest "$topdir" "$target"

  local suite="${ROOTFS_SUITE:-bookworm}"
  local variant="${ROOTFS_VARIANT:-minbase}"
  local arch="${ARCH:-arm64}"

  local out_dir="${OUT_DIR:-$topdir/out}"
  out_dir="$(vuos_abspath "$out_dir")"

  local out_base="$out_dir/rootfs/$target"
  local rootfs_dir="$out_base/rootfs"
  local img="$out_base/rootfs.img"

  if [[ "$do_clean" == "1" ]]; then
    _vuos_rootfs_prepare_clean_path "$out_base"
    vuos_log "Cleaning output: $out_base"
    rm -rf "$out_base"
  fi

  vuos_mkdir "$out_base"

  # Logging
  local ts log_dir
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  log_dir="$out_base/logs/$ts"
  vuos_mkdir "$log_dir"

  # Redirect stdout/stderr into log file, but keep console output.
  exec > >(tee -a "$log_dir/rootfs.log") 2>&1

  cat >"$log_dir/config.env" <<CFG
TARGET=$target
SUITE=$suite
VARIANT=$variant
ARCH=$arch
MIRROR=$mirror
COMPONENTS=$components
IMG_SIZE=$img_size
OUT_BASE=$out_base
CFG

  vuos_need_cmd mmdebstrap rsync

  # Build package list
  local pkgs_file
  pkgs_file="$log_dir/mmdebstrap.packages.txt"
  _vuos_rootfs_collect_packages "$topdir" "$suite" > "$pkgs_file"

  local include_pkgs
  include_pkgs="$(paste -sd, "$pkgs_file")"

  # Build rootfs dir
  # Hard safety rule: if anything is still mounted below rootfs_dir, do not try
  # to remove it. A stale proc/sys/dev bind mount here can otherwise make rm -rf
  # operate on live host pseudo-filesystems or /dev nodes.
  _vuos_rootfs_require_no_mounts "$rootfs_dir"
  rm -rf "$rootfs_dir"
  vuos_mkdir "$rootfs_dir"

  local -a mm_args=()
  if [[ -n "${MMDEBSTRAP_MODE:-}" ]]; then
    mm_args+=("--mode=$MMDEBSTRAP_MODE")
  fi

  vuos_log "mmdebstrap: suite=$suite arch=$arch variant=$variant"
  mmdebstrap \
    "${mm_args[@]}" \
    --architectures="$arch" \
    --variant="$variant" \
    --components="$components" \
    --include="$include_pkgs" \
    "$suite" \
    "$rootfs_dir" \
    "$mirror"

  # Apply overlays
  if declare -p ROOTFS_OVERLAYS >/dev/null 2>&1 && ((${#ROOTFS_OVERLAYS[@]})); then
    _vuos_rootfs_apply_overlays "$rootfs_dir" "${ROOTFS_OVERLAYS[@]}"
  fi

  # Run hooks after overlays, before packing image.
  _vuos_rootfs_run_hooks "$topdir" "$target" "$suite" "$rootfs_dir"

  # Write build info
  {
    echo "target=$target"
    echo "suite=$suite"
    echo "variant=$variant"
    echo "arch=$arch"
    echo "mirror=$mirror"
    echo "components=$components"
    echo "built_at=$(date -Is)"
  } > "$out_base/build-info.txt"

  if [[ "$do_image" == "1" ]]; then
    # Hooks run in a chroot environment and may leave proc/sys/dev mounts behind
    # if a build is interrupted or a cleanup path is missed. Make one final pass
    # to ensure the pack path is free of active mounts before sizing / copying it
    # into rootfs.img.
    _vuos_rootfs_prepare_clean_path "$rootfs_dir"
    vuos_log "Creating ext4 image: $img ($img_size)"
    _vuos_rootfs_make_ext4_image "$rootfs_dir" "$img" "$img_size"
  else
    vuos_log "Skipping ext4 image (--no-image)"
  fi

  vuos_log "Done. Outputs: $out_base"
}
