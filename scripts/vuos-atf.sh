#!/usr/bin/env bash
set -euo pipefail

TOPDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$TOPDIR/scripts/lib/common.sh"

_usage() {
  cat >&2 <<'USAGE'
Usage:
  vuos atf <target> [options]

Options:
  --clean                 Remove out/atf/<target> before building
  --ref <git-ref>         TF-A git ref (default from board.toml, else v2.12)
  --url <git-url>         TF-A git URL (default from board.toml, else GitHub)
  --plat <platform>       TF-A PLAT value (default from board.toml, else rk3399)
  --target <image>        Image target (default from board.toml, else bl31)

Environment variables:
  OUT_DIR                 Top-level output dir (default: <repo>/out)
  ATF_SRC                 Use an existing TF-A source tree (skip fetch)
  ATF_VERSION_REF         Same as --ref
  ATF_GIT_URL             Same as --url
  ATF_PLATFORM            Same as --plat
  ATF_TARGET              Same as --target
  CROSS_COMPILE           Toolchain prefix (default: aarch64-linux-gnu-)
  M0_CROSS_COMPILE        M0 toolchain prefix (default: arm-none-eabi-)
  JOBS                    Parallel jobs (default: nproc)

Outputs:
  out/atf/<target>/bl31.elf
USAGE
}

_find_topdir() {
  local here
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  (cd -- "$here/.." && pwd)
}

_load_manifest() {
  local topdir="$1" target="$2"
  local manifest="$topdir/boards/$target/board.toml"
  local py="$topdir/scripts/lib/manifest.py"
  [[ -f "$manifest" ]] || vuos_die "Board manifest not found: $manifest"
  [[ -f "$py" ]] || vuos_die "manifest.py not found: $py"
  eval "$(python3 "$py" "$manifest" --topdir "$topdir")"
}

_git_clone_or_update() {
  local url="$1" ref="$2" dst="$3"
  if [[ -d "$dst/.git" ]]; then
    git -C "$dst" fetch --tags --prune origin >/dev/null 2>&1 || true
    git -C "$dst" checkout -f "$ref" >/dev/null 2>&1 \
      || (git -C "$dst" fetch --tags --prune origin && git -C "$dst" checkout -f "$ref")
    return 0
  fi

  rm -rf "$dst"
  git clone --depth 1 --branch "$ref" "$url" "$dst" \
    || { rm -rf "$dst"; git clone "$url" "$dst"; git -C "$dst" checkout -f "$ref"; }
}

vuos_atf_main() {
  local topdir
  topdir="$(_find_topdir)"

  local target="${1:-}"; shift || true
  [[ -n "$target" ]] || { _usage; exit 2; }

  local do_clean=0
  local url="${ATF_GIT_URL:-https://github.com/ARM-software/arm-trusted-firmware.git}"
  local ref="${ATF_VERSION_REF:-v2.12}"
  local plat="${ATF_PLATFORM:-rk3399}"
  local image_target="${ATF_TARGET:-bl31}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clean) do_clean=1; shift ;;
      --ref) ref="${2:?missing ref}"; shift 2 ;;
      --url) url="${2:?missing url}"; shift 2 ;;
      --plat) plat="${2:?missing plat}"; shift 2 ;;
      --target) image_target="${2:?missing image}"; shift 2 ;;
      -h|--help) _usage; exit 0 ;;
      *) vuos_die "Unknown option: $1" ;;
    esac
  done

  _load_manifest "$topdir" "$target"

  if [[ -n "${ATF_GIT_URL:-}" ]]; then
    url="$ATF_GIT_URL"
  fi
  if [[ -n "${ATF_VERSION_REF:-}" ]]; then
    ref="$ATF_VERSION_REF"
  fi
  if [[ -n "${ATF_PLATFORM:-}" ]]; then
    plat="$ATF_PLATFORM"
  fi
  if [[ -n "${ATF_TARGET:-}" ]]; then
    image_target="$ATF_TARGET"
  fi

  local out_dir="${OUT_DIR:-$topdir/out}"
  out_dir="$(vuos_abspath "$out_dir")"

  local stage_dir="$out_dir/atf/$target"
  local src_dir="${ATF_SRC:-$stage_dir/src}"
  local jobs="${JOBS:-$(nproc)}"
  local cross="${CROSS_COMPILE:-aarch64-linux-gnu-}"
  local m0_cross="${M0_CROSS_COMPILE:-arm-none-eabi-}"

  if [[ "$do_clean" == "1" ]]; then
    rm -rf "$stage_dir"
  fi
  mkdir -p "$stage_dir"

  vuos_need_cmd git make python3
  command -v "${cross}gcc" >/dev/null 2>&1 || vuos_die "Missing AArch64 cross compiler: ${cross}gcc"
  command -v "${m0_cross}gcc" >/dev/null 2>&1 || vuos_die "Missing RK3399 M0 cross compiler: ${m0_cross}gcc (install gcc-arm-none-eabi, or export M0_CROSS_COMPILE=...)"

  if [[ -z "${ATF_SRC:-}" ]]; then
    vuos_log "TF-A: fetch $url @ $ref"
    _git_clone_or_update "$url" "$ref" "$src_dir"
  else
    [[ -d "$src_dir" ]] || vuos_die "ATF_SRC is not a directory: $src_dir"
  fi

  vuos_log "TF-A: clean"
  make -C "$src_dir" distclean >/dev/null 2>&1 || make -C "$src_dir" realclean >/dev/null 2>&1 || true

  vuos_log "TF-A: build PLAT=$plat $image_target"
  make -C "$src_dir" CROSS_COMPILE="$cross" M0_CROSS_COMPILE="$m0_cross" PLAT="$plat" -j"$jobs" "$image_target"

  local img="$src_dir/build/$plat/release/bl31/bl31.elf"
  [[ -f "$img" ]] || vuos_die "Missing build output: $img"

  cp -f "$img" "$stage_dir/bl31.elf"
  cp -f "$src_dir/build/$plat/release/bl31.bin" "$stage_dir/bl31.bin" 2>/dev/null || true

  vuos_log "TF-A: output -> $stage_dir/bl31.elf"
}

vuos_atf_main "$@"
