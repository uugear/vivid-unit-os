#!/usr/bin/env bash
# Kernel build logic for Vivid Unit OS.
#
# This file is intended to be sourced by scripts/vuos-kernel.sh.
#
# High-level goals:
# - Build a working arm64 kernel (Image + modules)
# - Build DTB(s) from a TOML-defined whitelist ([kernel].dts)
# - Keep outputs under out/kernel/<target>/
# - Make as few assumptions as possible about the host environment

set -euo pipefail

_vuos_kernel_usage() {
  cat >&2 <<'EOF'
Usage:
  vuos kernel <target> [options]

Options:
  --clean           Remove output directory before building
  --dtb-only        Only build DTBs (no kernel Image/modules)
  --image-only      Only build kernel Image/modules (no DTBs)
  --no-modules-install  Skip "make modules_install" step

Environment variables:
  KERNEL_SRC        Path to Linux kernel source tree (default: out/src/kernel/linux-<version>)
  KERNEL_VERSION    Patch set selector (default: 6.12.73)
  KERNEL_OUT        Kernel build output dir passed as "O=" (default: out/kernel/<target>/build)
  OUT_DIR           Top-level output dir (default: <repo>/out; also holds cache/src trees)
  ARCH              (default: arm64)
  CROSS_COMPILE     (default: aarch64-linux-gnu-)
  JOBS              Parallel jobs for make (default: nproc)

DTB / incbin note:
  If DTS contains /incbin/("<file>") entries, the referenced files must exist in one
  of these directories:
    - boards/<target>/dts/kernel/
    - boards/<target>/dts/common/
    - <KERNEL_SRC>/arch/arm64/boot/dts/rockchip/

  For example, you may place rk3399_ddr_666MHz_v1.30.bin into:
    boards/vivid-unit/dts/common/
EOF
}

_vuos_kernel_find_topdir() {
  # scripts/lib/kernel.sh -> scripts/lib -> scripts -> repo
  local here
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  (cd -- "$here/../.." && pwd)
}


_vuos_kernel_prepare_source_tree() {
  local out_dir="$1"

  [[ "${KERNEL_SOURCE_TYPE:-git}" == "git" ]] \
    || vuos_die "Kernel fetch currently supports only source.type=git"

  local cache_git="$out_dir/cache/git"
  local mirror="$cache_git/linux-stable.git"
  local kver="${KERNEL_VERSION:?missing KERNEL_VERSION}"
  local wt="$out_dir/src/kernel/linux-$kver"

  vuos_mkdir "$cache_git"
  vuos_mkdir "$(dirname "$wt")"

  vuos_log "Kernel: mirror -> $mirror"
  vuos_git_prepare_mirror "${KERNEL_SOURCE_URL:?missing KERNEL_SOURCE_URL}" "$mirror"

  vuos_log "Kernel: source -> $wt (${KERNEL_SOURCE_REF:?missing KERNEL_SOURCE_REF})"
  vuos_git_prepare_worktree "$mirror" "$wt" "$KERNEL_SOURCE_REF"

  echo "$wt"
}

_vuos_kernel_apply_patch_file_git() {
  local src="$1" patch_file="$2"
  if git -C "$src" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    vuos_log "Patch already applied (skip): $(basename "$patch_file")"
    return 0
  fi
  git -C "$src" apply --check "$patch_file" >/dev/null 2>&1 \
    || vuos_die "Patch does not apply cleanly: $patch_file"
  vuos_log "Applying patch: $(basename "$patch_file")"
  git -C "$src" apply "$patch_file"
}

_vuos_kernel_apply_patch_file_patch() {
  local src="$1" patch_file="$2"
  (cd "$src" && patch -R -p1 --dry-run < "$patch_file" >/dev/null 2>&1) && {
    vuos_log "Patch already applied (skip): $(basename "$patch_file")"
    return 0
  }
  (cd "$src" && patch -p1 --dry-run < "$patch_file" >/dev/null 2>&1) \
    || vuos_die "Patch does not apply cleanly: $patch_file"
  vuos_log "Applying patch: $(basename "$patch_file")"
  (cd "$src" && patch -p1 < "$patch_file" >/dev/null)
}

_vuos_kernel_apply_patches_dir() {
  local src="$1" dir="$2"
  [[ -d "$dir" ]] || return 0

  shopt -s nullglob
  local patches=("$dir"/*.patch "$dir"/*.diff)
  shopt -u nullglob

  ((${#patches[@]})) || return 0

  # Stable ordering
  IFS=$'\n' patches=($(printf '%s\n' "${patches[@]}" | sort))
  unset IFS

  if git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local p
    for p in "${patches[@]}"; do
      _vuos_kernel_apply_patch_file_git "$src" "$p"
    done
  else
    vuos_warn "Kernel source is not a git repo; using 'patch' to apply patches"
    vuos_need_cmd patch
    local p
    for p in "${patches[@]}"; do
      _vuos_kernel_apply_patch_file_patch "$src" "$p"
    done
  fi
}

_vuos_kernel_resolve_dtc() {
  local ksrc="$1" kout="$2"

  if [[ -x "$kout/scripts/dtc/dtc" ]]; then
    echo "$kout/scripts/dtc/dtc"
    return 0
  fi
  if [[ -x "$ksrc/scripts/dtc/dtc" ]]; then
    echo "$ksrc/scripts/dtc/dtc"
    return 0
  fi
  command -v dtc >/dev/null 2>&1 && { echo "dtc"; return 0; }
  return 1
}

_vuos_kernel_check_incbin_files() {
  local dts_file="$1"; shift
  local -a search_dirs=("$@")

  local -a incbins
  mapfile -t incbins < <(grep -oE '/incbin/\("[^"]+"\)' "$dts_file" \
    | sed -E 's#^.*/incbin/\("([^"]+)"\).*#\1#' \
    | sort -u)

  ((${#incbins[@]})) || return 0

  local f d found
  for f in "${incbins[@]}"; do
    found=""
    for d in "${search_dirs[@]}"; do
      [[ -f "$d/$f" ]] && { found="$d/$f"; break; }
    done
    [[ -n "$found" ]] || {
      vuos_die "Missing incbin file referenced by DTS: $f\n\
Searched in:\n\
  - ${search_dirs[*]}\n\
Hint: place the file into boards/<target>/dts/common/ (recommended)."
    }
  done
}

_vuos_kernel_load_board_manifest() {
  local topdir="$1" target="$2"
  local manifest="$topdir/boards/$target/board.toml"
  local py="$topdir/scripts/lib/manifest.py"

  [[ -f "$manifest" ]] || vuos_die "Board manifest not found: $manifest"
  [[ -f "$py" ]] || vuos_die "manifest.py not found: $py"

  # Load TOML -> shell variables into current shell.
  # NOTE: arrays (e.g. KERNEL_DTS) cannot be exported, so we must eval here.
  eval "$(python3 "$py" "$manifest" --topdir "$topdir")"
}

_vuos_kernel_build_dtbs() {
  local topdir="$1" target="$2" ksrc="$3" kout="$4" out_base="$5"
  shift 5
  local -a dts_files=("$@")

  local board_dir="$topdir/boards/$target"
  local dts_dir="$board_dir/dts/kernel"
  local common_dir="$board_dir/dts/common"
  [[ -d "$dts_dir" ]] || vuos_die "DTS directory not found: $dts_dir"

  local rockchip_dts_dir="$ksrc/arch/arm64/boot/dts/rockchip"
  [[ -d "$rockchip_dts_dir" ]] || vuos_die "Kernel rockchip dts dir not found: $rockchip_dts_dir"

  local dtb_out="$out_base/dtbs"
  vuos_mkdir "$dtb_out"

  local dtc
  dtc="$(_vuos_kernel_resolve_dtc "$ksrc" "$kout")" \
    || vuos_die "dtc not found (install device-tree-compiler or build kernel scripts)"
  vuos_need_cmd cpp

  ((${#dts_files[@]})) || {
    vuos_die "No DTS specified. Please set [kernel].dts in boards/$target/board.toml"
  }

  local dts
  for dts in "${dts_files[@]}"; do
    [[ -f "$dts" ]] || vuos_die "DTS not found: $dts"
  done

  local cpp_includes=(
    "-I$ksrc/include"
    "-I$ksrc/arch/arm64/boot/dts"
    "-I$rockchip_dts_dir"
    "-I$dts_dir"
  )

  local dtc_includes=(
    "-i" "$rockchip_dts_dir"
    "-i" "$dts_dir"
  )

  # common dir is optional
  if [[ -d "$common_dir" ]]; then
    cpp_includes+=("-I$common_dir")
    dtc_includes+=("-i" "$common_dir")
  fi

  local tmpdir
  (
    set -euo pipefail
    tmpdir="$(mktemp -d)"
    trap 'rm -rf -- "$tmpdir"' EXIT

    local base pre out dts_dir_this
    for dts in "${dts_files[@]}"; do
      dts_dir_this="$(dirname "$dts")"
      base="$(basename "$dts" .dts)"
      out="$dtb_out/$base.dtb"
      pre="$tmpdir/$base.pre.dts"
  
      # Search incbin files in DTS dir, board common dir (optional), and kernel rockchip dir.
      if [[ -d "$common_dir" ]]; then
        _vuos_kernel_check_incbin_files "$dts" "$dts_dir_this" "$common_dir" "$rockchip_dts_dir"
      else
        _vuos_kernel_check_incbin_files "$dts" "$dts_dir_this" "$rockchip_dts_dir"
      fi
  
      vuos_log "DTB: preprocessing $base.dts"
      cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
        "${cpp_includes[@]}" "-I$dts_dir_this" "$dts" > "$pre"
  
      vuos_log "DTB: compiling $base.dtb"
      "$dtc" -@ -H epapr -O dtb -o "$out" "${dtc_includes[@]}" -i "$dts_dir_this" "$pre"
    done
  )
}

_vuos_kernel_build_image_and_modules() {
  local ksrc="$1" kout="$2" arch="$3" cross="$4" jobs="$5" defconfig_file="$6" out_base="$7" no_mod_install="$8"

  [[ -f "$defconfig_file" ]] || vuos_die "Defconfig not found: $defconfig_file"

  vuos_mkdir "$kout"

  # Seed config
  cp -f "$defconfig_file" "$kout/.config"

  vuos_log "Kernel: olddefconfig"
  make -C "$ksrc" O="$kout" ARCH="$arch" CROSS_COMPILE="$cross" KERNELRELEASE="$krel" olddefconfig

  vuos_log "Kernel: build Image + modules (jobs=$jobs)"
  make -C "$ksrc" O="$kout" ARCH="$arch" CROSS_COMPILE="$cross" -j"$jobs" KERNELRELEASE="$krel" Image modules

  local img="$kout/arch/$arch/boot/Image"
  [[ -f "$img" ]] || vuos_die "Kernel Image not found after build: $img"

  cp -f "$img" "$out_base/Image"
  cp -f "$kout/System.map" "$out_base/System.map" 2>/dev/null || true
  cp -f "$kout/.config" "$out_base/kernel.config" 2>/dev/null || true

  if [[ "$no_mod_install" == "1" ]]; then
    vuos_warn "Skipping modules_install (requested)"
    return 0
  fi

  local mod_dest="$out_base/modules"
  vuos_mkdir "$mod_dest"
  vuos_log "Kernel: modules_install -> $mod_dest"
  make -C "$ksrc" O="$kout" ARCH="$arch" CROSS_COMPILE="$cross" KERNELRELEASE="$krel" \
    modules_install INSTALL_MOD_PATH="$mod_dest" INSTALL_MOD_STRIP=1
}

vuos_kernel_main() {
  local topdir
  topdir="$(_vuos_kernel_find_topdir)"

  # shellcheck source=/dev/null
  source "$topdir/scripts/lib/common.sh"

  local target="${1:-}"
  shift || true
  [[ -n "$target" ]] || { _vuos_kernel_usage; exit 2; }

  local do_clean=0 do_dtb=1 do_img=1 no_mod_install=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clean) do_clean=1; shift ;;
      --dtb-only) do_img=0; do_dtb=1; shift ;;
      --image-only) do_img=1; do_dtb=0; shift ;;
      --no-modules-install) no_mod_install=1; shift ;;
      -h|--help) _vuos_kernel_usage; exit 0 ;;
      *) vuos_die "Unknown option: $1" ;;
    esac
  done

  # Load board manifest (TOML) into current shell. This provides:
  #   KERNEL_DTS (array), KERNEL_DEFCONFIG, KERNEL_PATCH_DIRS (array), etc.
  _vuos_kernel_load_board_manifest "$topdir" "$target"

  local kver="${KERNEL_VERSION:-}"
  local arch="${ARCH:-arm64}"
  local cross="${CROSS_COMPILE:-aarch64-linux-gnu-}"
  local jobs="${JOBS:-$(nproc)}"

  local out_dir="${OUT_DIR:-$topdir/out}"
  out_dir="$(vuos_abspath "$out_dir")"
  local out_base="$out_dir/kernel/$target"

  if [[ -z "${KERNEL_SRC:-}" ]]; then
    KERNEL_SRC="$(_vuos_kernel_prepare_source_tree "$out_dir")"
  fi
  local ksrc="${KERNEL_SRC:-}"
  [[ -n "$ksrc" ]] || vuos_die "KERNEL_SRC is required (path to Linux source tree)"
  ksrc="$(vuos_abspath "$ksrc")"
  [[ -d "$ksrc" ]] || vuos_die "KERNEL_SRC not found: $ksrc"

  if git -C "$ksrc" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    vuos_log "Kernel: reset source tree -> $ksrc"
    vuos_git_reset_clean_checkout "$ksrc" "${KERNEL_SOURCE_REF:-HEAD}"
  else
    vuos_warn "Kernel source is not a git repo; cannot auto-reset/clean before build: $ksrc"
  fi

  local kout_default="$out_base/build"
  local kout="${KERNEL_OUT:-$kout_default}"
  kout="$(vuos_abspath "$kout")"

  local krel="${KERNEL_RELEASE:-}"

  if [[ "$do_clean" == "1" ]]; then
    vuos_log "Cleaning output: $out_base"
    rm -rf "$out_base"
  fi

  vuos_mkdir "$out_base"

  # Apply patches (from TOML, in order). If unset, keep legacy fallback.
  if declare -p KERNEL_PATCH_DIRS >/dev/null 2>&1 && ((${#KERNEL_PATCH_DIRS[@]})); then
    local pd
    for pd in "${KERNEL_PATCH_DIRS[@]}"; do
      [[ -d "$pd" ]] || { vuos_warn "Patch dir not found (skip): $pd"; continue; }
      vuos_log "Applying kernel patches: $pd"
      _vuos_kernel_apply_patches_dir "$ksrc" "$pd"
    done
  else
    local pbase="$topdir/kernel/patches/$kver"
    if [[ -d "$pbase" ]]; then
      vuos_log "Applying kernel patches (legacy): $pbase"
      _vuos_kernel_apply_patches_dir "$ksrc" "$pbase/common"
      _vuos_kernel_apply_patches_dir "$ksrc" "$pbase/$target"
    else
      vuos_warn "No patch set directory found: $pbase (skip patches)"
    fi
  fi

  local defconfig_file="${KERNEL_DEFCONFIG:-$topdir/kernel/configs/vivid_unit_defconfig}"

  if [[ "$do_img" == "1" ]]; then
    _vuos_kernel_build_image_and_modules "$ksrc" "$kout" "$arch" "$cross" "$jobs" "$defconfig_file" "$out_base" "$no_mod_install"
  fi

  if [[ "$do_dtb" == "1" ]]; then
    # Only build DTBs listed in [kernel].dts from board.toml
    _vuos_kernel_build_dtbs "$topdir" "$target" "$ksrc" "$kout" "$out_base" "${KERNEL_DTS[@]}"
  fi

  # Write a tiny build manifest.
  {
    echo "target=$target"
    echo "kernel_src=$ksrc"
    echo "kernel_version_selector=$kver"
    echo "arch=$arch"
    echo "cross_compile=$cross"
    echo "kout=$kout"
    date -Is | sed 's/^/built_at=/'
    if [[ -x "$ksrc/Makefile" ]]; then :; fi
  } > "$out_base/build-info.txt"

  vuos_log "Done. Outputs: $out_base"
}