#!/usr/bin/env bash
# U-Boot build logic for Vivid Unit OS.
#
# This file is intended to be sourced by scripts/vuos-uboot.sh.
#
# Current flow:
# - Build Rockchip SPL/TPL + FIT style outputs
# - Prefer vendor BL31 from boards/<target>/rkbin/
# - Optionally install resulting artifacts into boards/<target>/pack/rkbin/

set -euo pipefail

# shellcheck source=/dev/null
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

_vuos_uboot_usage() {
  cat >&2 <<'USAGE'
Usage:
  vuos uboot <target> [options]

Options:
  --clean                 Remove out/uboot/<target> and out/build/uboot/<target> before building
  --no-install            Do not copy output into boards/<target>/pack/rkbin/
  --ref <git-ref>         U-Boot git ref (tag/commit), default: v2025.04
  --url <git-url>         U-Boot git URL, default: https://source.denx.de/u-boot/u-boot.git
  --defconfig <name>      Use an in-tree defconfig (e.g. roc-pc-rk3399_defconfig)
  --config <path>         Use a full .config file (copied then olddefconfig)

Environment variables:
  OUT_DIR                 Top-level output dir (default: <repo>/out)
  UBOOT_SRC               Use an existing U-Boot source tree (skip out/cache mirror/worktree fetch)
  UBOOT_VERSION_REF       Same as --ref (takes precedence over default)
  UBOOT_GIT_URL           Same as --url
  UBOOT_DEFCONFIG         Same as --defconfig
  UBOOT_CONFIG_FILE       Same as --config
  CROSS_COMPILE           Toolchain prefix (default: aarch64-linux-gnu-)
  JOBS                    Parallel jobs (default: nproc)

  # Optional override for test builds when vendor BL31 is not used
  BL31                    Path to BL31 ELF/BIN (e.g. out/atf/<target>/bl31.elf)
  ROCKCHIP_TPL           Path to Rockchip DDR/TPL binary (e.g. boards/<target>/rkbin/rk3399_ddr_666MHz_v1.30.bin)

Outputs:
  out/uboot/<target>/{idbloader.img,u-boot.itb,u-boot-rockchip.bin,uboot.img,...}
  (optional) boards/<target>/pack/rkbin/{uboot.img,u-boot.itb,idbloader.img}

Notes:
  - Preferred BL31 location: boards/<target>/rkbin/rk3399_bl31_v1.36.elf
  - If that file is absent, set BL31=/path/to/bl31.elf explicitly.
  - Preferred Rockchip TPL location: boards/<target>/rkbin/rk3399_ddr_666MHz_v1.30.bin
  - If that file is absent, set ROCKCHIP_TPL=/path/to/ddr.bin explicitly.
  - TF-A is not auto-built by this stage.
  - Source cache/worktree live under out/cache/git/u-boot.git and out/src/uboot/<ref>.
  - Build tree lives under out/build/uboot/<target>.
  - Pack stage uses out/uboot/<target>/u-boot-rockchip.bin directly when building the raw image.
  - rkbin/uboot.img remains a convenience copy of u-boot.itb for debugging/transition purposes.
USAGE
}

_vuos_uboot_find_topdir() {
  # scripts/lib/uboot.sh -> scripts/lib -> scripts -> repo
  local here
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  (cd -- "$here/../.." && pwd)
}

_vuos_uboot_load_manifest() {
  local topdir="$1" target="$2"
  local manifest="$topdir/boards/$target/board.toml"
  local py="$topdir/scripts/lib/manifest.py"
  [[ -f "$manifest" ]] || vuos_die "Board manifest not found: $manifest"
  [[ -f "$py" ]] || vuos_die "manifest.py not found: $py"
  eval "$(python3 "$py" "$manifest" --topdir "$topdir")"
}

_vuos_uboot_need_toolchain() {
  local cross="$1"
  local gcc="${cross}gcc"
  command -v "$gcc" >/dev/null 2>&1 \
    || vuos_die "Missing cross compiler: $gcc\nInstall e.g.: gcc-aarch64-linux-gnu (Debian/Ubuntu)"
}

_vuos_uboot_git_clone_or_update() {
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


_vuos_uboot_apply_patch_file_git() {
  local src="$1" patch_file="$2"
  if git -C "$src" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    vuos_log "Patch already applied (skip): $(basename "$patch_file")"
    return 0
  fi
  git -C "$src" apply --check "$patch_file" >/dev/null 2>&1     || vuos_die "Patch does not apply cleanly: $patch_file"
  vuos_log "Applying patch: $(basename "$patch_file")"
  git -C "$src" apply "$patch_file"
}

_vuos_uboot_apply_patch_file_patch() {
  local src="$1" patch_file="$2"
  (cd "$src" && patch -R -p1 --dry-run < "$patch_file" >/dev/null 2>&1) && {
    vuos_log "Patch already applied (skip): $(basename "$patch_file")"
    return 0
  }
  (cd "$src" && patch -p1 --dry-run < "$patch_file" >/dev/null 2>&1)     || vuos_die "Patch does not apply cleanly: $patch_file"
  vuos_log "Applying patch: $(basename "$patch_file")"
  (cd "$src" && patch -p1 < "$patch_file" >/dev/null)
}

_vuos_uboot_apply_patches_dir() {
  local src="$1" dir="$2"
  [[ -d "$dir" ]] || return 0

  shopt -s nullglob
  local patches=("$dir"/*.patch "$dir"/*.diff)
  shopt -u nullglob

  ((${#patches[@]})) || return 0

  IFS=$'
' patches=($(printf '%s
' "${patches[@]}" | sort))
  unset IFS

  if git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local p
    for p in "${patches[@]}"; do
      _vuos_uboot_apply_patch_file_git "$src" "$p"
    done
  else
    vuos_warn "U-Boot source is not a git repo; using 'patch' to apply patches"
    vuos_need_cmd patch
    local p
    for p in "${patches[@]}"; do
      _vuos_uboot_apply_patch_file_patch "$src" "$p"
    done
  fi
}

_vuos_uboot_apply_overlays_dir() {
  local src="$1" build="$2" dir="$3"
  [[ -d "$dir" ]] || return 0

  local rel dst_src dst_build
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    dst_src="$src/$rel"
    mkdir -p "$(dirname "$dst_src")"
    cp -fL "$dir/$rel" "$dst_src"

    case "$rel" in
      *.dts|*.dtsi|*.bin)
        dst_build="$build/$rel"
        mkdir -p "$(dirname "$dst_build")"
        cp -fL "$dir/$rel" "$dst_build"
        ;;
    esac
  done < <(cd "$dir" && find . -type f -print0 | sort -z)
}

_vuos_uboot_resolve_bl31() {
  local topdir="$1" target="$2"

  local vendor_bl31="$topdir/boards/$target/rkbin/rk3399_bl31_v1.36.elf"
  if [[ -f "$vendor_bl31" ]]; then
    echo "$vendor_bl31"
    return 0
  fi

  if [[ -n "${BL31:-}" ]]; then
    echo "$BL31"
    return 0
  fi

  return 1
}

_vuos_uboot_resolve_rockchip_tpl() {
  local topdir="$1" target="$2"

  local vendor_tpl="$topdir/boards/$target/rkbin/rk3399_ddr_666MHz_v1.30.bin"
  if [[ -f "$vendor_tpl" ]]; then
    echo "$vendor_tpl"
    return 0
  fi

  local generic_tpl=""
  shopt -s nullglob
  local matches=("$topdir/boards/$target/rkbin"/rk3399_ddr*.bin)
  shopt -u nullglob
  if (( ${#matches[@]} > 0 )); then
    generic_tpl="${matches[0]}"
    echo "$generic_tpl"
    return 0
  fi

  if [[ -n "${ROCKCHIP_TPL:-}" ]]; then
    echo "$ROCKCHIP_TPL"
    return 0
  fi

  return 1
}

_vuos_uboot_apply_board_sources() {
  # Copy board-provided DTS / DTSI files and any /incbin/ blobs into BOTH:
  #   - the cloned U-Boot source tree (so DEVICE_TREE can reference them)
  #   - the U-Boot build tree (dtc /incbin/ may also resolve relative to build)
  # Uses manifest-provided array UBOOT_DTS.
  local src_dir="$1"
  local build_dir="$2"
  local topdir="$3"
  local target="$4"

  local -a dts_list=()
  if declare -p UBOOT_DTS >/dev/null 2>&1; then
    # shellcheck disable=SC2154
    dts_list=("${UBOOT_DTS[@]}")
  fi
  ((${#dts_list[@]})) || return 0

  local dest_rel=""
  if [[ -d "$src_dir/dts/upstream/src/arm64/rockchip" ]]; then
    dest_rel="dts/upstream/src/arm64/rockchip"
  elif [[ -d "$src_dir/arch/arm/dts" ]]; then
    dest_rel="arch/arm/dts"
  else
    return 0
  fi

  local dest_src="$src_dir/$dest_rel"
  local dest_obj="$build_dir/$dest_rel"
  mkdir -p "$dest_src" "$dest_obj"

  _vuos_uboot_copy_matches() {
    local pattern="$1" dst_src="$2" dst_obj="$3" dst_root="${4:-}"
    if compgen -G "$pattern" >/dev/null; then
      cp -fL $pattern "$dst_src/" 2>/dev/null || true
      cp -fL $pattern "$dst_obj/" 2>/dev/null || true
      if [[ -n "$dst_root" ]]; then
        cp -fL $pattern "$dst_root/" 2>/dev/null || true
      fi
    fi
  }

  local dts ddir base
  for dts in "${dts_list[@]}"; do
    [[ -f "$dts" ]] || vuos_die "UBOOT_DTS missing: $dts"
    ddir="$(dirname "$dts")"
    base="$(basename "$dts")"

    cp -fL "$dts" "$dest_src/$base"
    cp -fL "$dts" "$dest_obj/$base" 2>/dev/null || true

    # Copy adjacent board-local include files and blobs.
    _vuos_uboot_copy_matches "$ddir/*.dtsi" "$dest_src" "$dest_obj"
    _vuos_uboot_copy_matches "$ddir/*.bin"  "$dest_src" "$dest_obj" "$build_dir"
  done

  # Copy shared board DTS include files from boards/<target>/dts/common/.
  if [[ -n "$topdir" && -n "$target" && -d "$topdir/boards/$target/dts/common" ]]; then
    _vuos_uboot_copy_matches "$topdir/boards/$target/dts/common/*.dtsi" "$dest_src" "$dest_obj"
    _vuos_uboot_copy_matches "$topdir/boards/$target/dts/common/*.bin"  "$dest_src" "$dest_obj" "$build_dir"
  fi

  # Also copy board rkbin blobs. This is now the preferred location for
  # Rockchip vendor binaries referenced via /incbin/() by the U-Boot DTS.
  if [[ -n "$topdir" && -n "$target" && -d "$topdir/boards/$target/rkbin" ]]; then
    _vuos_uboot_copy_matches "$topdir/boards/$target/rkbin/*.bin" "$dest_src" "$dest_obj" "$build_dir"
  fi
}

vuos_uboot_main() {
  local topdir
  topdir="$(_vuos_uboot_find_topdir)"

  local target="${1:-}"; shift || true
  [[ -n "$target" ]] || { _vuos_uboot_usage; exit 2; }

  unset KCONFIG_CONFIG KCONFIG_DEFCONFIG KCONFIG_OVERWRITECONFIG

  python3 -c "import elftools" >/dev/null 2>&1 || {
    echo "ERROR: missing python module 'elftools' (install: sudo apt-get install python3-pyelftools)" >&2
    exit 2
  }

  local do_clean=0 do_install=1
  local url="${UBOOT_GIT_URL:-https://source.denx.de/u-boot/u-boot.git}"
  local ref="${UBOOT_VERSION_REF:-v2025.04}"
  # IMPORTANT: board.toml is loaded *after* CLI parsing. Do not capture
  # manifest-provided UBOOT_DEFCONFIG/UBOOT_CONFIG_FILE too early.
  local defconfig=""
  local config_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clean) do_clean=1; shift ;;
      --no-install) do_install=0; shift ;;
      --ref) ref="${2:?missing ref}"; shift 2 ;;
      --url) url="${2:?missing url}"; shift 2 ;;
      --defconfig) defconfig="${2:?missing defconfig}"; shift 2 ;;
      --config) config_file="${2:?missing config}"; shift 2 ;;
      -h|--help) _vuos_uboot_usage; exit 0 ;;
      *) vuos_die "Unknown option: $1" ;;
    esac
  done

  _vuos_uboot_load_manifest "$topdir" "$target"

  local soc="${SOC:-}"
  [[ -n "$soc" ]] || vuos_warn "SOC not set in board.toml (continuing)"

  # Take defaults from manifest (board.toml) unless overridden by CLI.
  # manifest.py exports UBOOT_DEFCONFIG as an *absolute path* (repo-relative in TOML).
  if [[ -z "$defconfig" && -z "$config_file" ]]; then
    if [[ -n "${UBOOT_CONFIG_FILE:-}" ]]; then
      config_file="${UBOOT_CONFIG_FILE}"
    elif [[ -n "${UBOOT_DEFCONFIG:-}" ]]; then
      # If it's a file path (recommended), treat it as seed .config.
      if [[ -f "${UBOOT_DEFCONFIG}" ]]; then
        config_file="${UBOOT_DEFCONFIG}"
      else
        defconfig="${UBOOT_DEFCONFIG}"
      fi
    fi
  fi

  # If defconfig looks like a path, treat it as a seed config.
  if [[ -z "$config_file" && -n "$defconfig" && "$defconfig" == */* && -f "$defconfig" ]]; then
    config_file="$defconfig"
    defconfig=""
  fi

  # Sensible fallback defconfig per SoC (only if still unspecified).
  if [[ -z "$defconfig" && -z "$config_file" ]]; then
    case "$soc" in
      rk3399|RK3399|"") defconfig="roc-pc-rk3399_defconfig" ;;
      rk3588|rk3588s|RK3588|RK3588S) defconfig="rock-5b-rk3588_defconfig" ;;
      *) defconfig="" ;;
    esac
  fi

  local out_dir="${OUT_DIR:-$topdir/out}"
  out_dir="$(vuos_abspath "$out_dir")"

  local stage_dir="$out_dir/uboot/$target"
  local cache_git="$out_dir/cache/git"
  local mirror="$cache_git/u-boot.git"
  local ref_slug
  ref_slug="$(vuos_sanitize_path_component "$ref")"
  local src_dir="${UBOOT_SRC:-$out_dir/src/uboot/$ref_slug}"
  local build_dir="$out_dir/build/uboot/$target"
  local jobs="${JOBS:-$(nproc)}"

  if [[ "$do_clean" == "1" ]]; then
    rm -rf "$stage_dir" "$build_dir"
  fi
  mkdir -p "$stage_dir" "$cache_git" "$(dirname "$src_dir")" "$(dirname "$build_dir")"

  # Tool requirements for SPL/TPL route
  vuos_need_cmd git make python3 swig dtc

  local cross="${CROSS_COMPILE:-aarch64-linux-gnu-}"
  _vuos_uboot_need_toolchain "$cross"

  # BL31 is required for rockchip binman FIT in this flow.
  # Prefer the vendor BL31 kept in boards/<target>/rkbin/. For manual TF-A
  # experiments, the caller may still provide BL31=/path/to/bl31.elf.
  BL31="$(_vuos_uboot_resolve_bl31 "$topdir" "$target")" || \
    vuos_die "BL31 not found. Place vendor BL31 at boards/$target/rkbin/rk3399_bl31_v1.36.elf or export BL31=/path/to/bl31.elf"
  BL31="$(vuos_abspath "$BL31")"
  [[ -f "$BL31" ]] || vuos_die "BL31 not found: $BL31"

  # U-Boot/binman picks up BL31 from the make environment / command line.
  # Keep it exported so every subsequent make invocation can see it.
  export BL31
  vuos_log "U-Boot: BL31 -> $BL31"

  ROCKCHIP_TPL="$(_vuos_uboot_resolve_rockchip_tpl "$topdir" "$target")" || \
    vuos_die "Rockchip TPL not found. Place vendor DDR/TPL at boards/$target/rkbin/rk3399_ddr_666MHz_v1.30.bin or export ROCKCHIP_TPL=/path/to/ddr.bin"
  ROCKCHIP_TPL="$(vuos_abspath "$ROCKCHIP_TPL")"
  [[ -f "$ROCKCHIP_TPL" ]] || vuos_die "Rockchip TPL not found: $ROCKCHIP_TPL"

  export ROCKCHIP_TPL
  vuos_log "U-Boot: ROCKCHIP_TPL -> $ROCKCHIP_TPL"

  if [[ -n "${UBOOT_SRC:-}" ]]; then
    [[ -d "$src_dir" ]] || vuos_die "UBOOT_SRC was set but not a directory: $src_dir"
  else
    vuos_log "U-Boot: mirror -> $mirror"
    vuos_git_prepare_mirror "$url" "$mirror"
    vuos_log "U-Boot: source -> $src_dir ($ref)"
    vuos_git_prepare_worktree "$mirror" "$src_dir" "$ref"
  fi

  if git -C "$src_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    vuos_log "U-Boot: reset source tree -> $src_dir"
    vuos_git_reset_clean_checkout "$src_dir" "$ref"
  else
    vuos_warn "U-Boot source is not a git repo; cannot auto-reset/clean before build: $src_dir"
  fi

  if declare -p UBOOT_PATCH_DIRS >/dev/null 2>&1; then
    local -a patch_dirs=("${UBOOT_PATCH_DIRS[@]}")
    local pd
    for pd in "${patch_dirs[@]}"; do
      _vuos_uboot_apply_patches_dir "$src_dir" "$pd"
    done
  fi

  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  # Inject board DTS and any /incbin/ blobs into both src and build trees
  _vuos_uboot_apply_board_sources "$src_dir" "$build_dir" "$topdir" "$target"

  if declare -p UBOOT_OVERLAY_DIRS >/dev/null 2>&1; then
    local -a overlay_dirs=("${UBOOT_OVERLAY_DIRS[@]}")
    local od
    for od in "${overlay_dirs[@]}"; do
      _vuos_uboot_apply_overlays_dir "$src_dir" "$build_dir" "$od"
    done
  fi

  if [[ -n "$config_file" ]]; then
    config_file="$(vuos_abspath "$config_file")"
    [[ -f "$config_file" ]] || vuos_die "Config file not found: $config_file"
    cp -f "$config_file" "$build_dir/.config"
    vuos_log "U-Boot: olddefconfig (seed: $(basename "$config_file"))"
    make -C "$src_dir" O="$build_dir" ARCH=arm CROSS_COMPILE="$cross" BL31="$BL31" ROCKCHIP_TPL="$ROCKCHIP_TPL" olddefconfig
  else
    [[ -n "$defconfig" ]] || vuos_die "No defconfig selected. Provide --defconfig <name> or --config <file>."
    vuos_log "U-Boot: $defconfig"
    make -C "$src_dir" O="$build_dir" ARCH=arm CROSS_COMPILE="$cross" BL31="$BL31" ROCKCHIP_TPL="$ROCKCHIP_TPL" "$defconfig"
  fi

  # Force board device tree (if provided in manifest)
  # For upstream rockchip U-Boot, DT names are typically referenced with 'rockchip/' prefix.
  if [[ -n "${UBOOT_DEVICE_TREE:-}" ]]; then
    [[ -x "$src_dir/scripts/config" ]] || vuos_die "U-Boot scripts/config not found (unexpected): $src_dir/scripts/config"
    local dt
    dt="${UBOOT_DEVICE_TREE}"
    if [[ "$dt" != */* ]]; then
      if [[ -d "$src_dir/dts/upstream/src/arm64/rockchip" || -d "$src_dir/arch/arm/dts/rockchip" ]]; then
        dt="rockchip/$dt"
      fi
    fi
    "$src_dir/scripts/config" --file "$build_dir/.config" --set-str DEFAULT_DEVICE_TREE "$dt"
    "$src_dir/scripts/config" --file "$build_dir/.config" --set-str OF_LIST "$dt"
  fi

  # Prefer a deterministic local MMC boot path for Vivid Unit.
  # Rationale:
  # - bootflow scan -lb alone proved unreliable on this image layout.
  # - We already know the board boots when U-Boot runs these exact loads.
  # - Keep bootstd/extlinux enabled as a fallback, but do not depend on it.
  if [[ -x "$src_dir/scripts/config" ]]; then
    local bootcmd preboot
    # Assert USB host 5V as soon as U-Boot proper starts.
    # GPIO 32 == GPIO1_A0 == vcc5v0_host_en, active-high.
    #
    # Darken the panel immediately before booti so the remaining U-Boot -> Linux
    # handoff window shows as a short black screen instead of random MIPI noise.
    # GPIO 45 == GPIO1_A5 == led_pwr_en (panel/LED supply enable), active-high.
    bootcmd='gpio set 32; if mmc dev 0; then setenv bootargs earlycon=uart8250,mmio32,0xff1a0000 console=tty1 console=ttyS2,115200n8 root=/dev/mmcblk0p3 rootwait rw rootfstype=ext4 loglevel=7 ignore_loglevel fbcon=nodefer logo.nologo; if ext4load mmc 0:2 ${kernel_addr_r} /Image; then if ext4load mmc 0:2 ${fdt_addr_r} /dtbs/rk3399-vivid-unit.dtb; then gpio clear 45; booti ${kernel_addr_r} - ${fdt_addr_r}; fi; fi; if ext4load mmc 0:3 ${kernel_addr_r} /boot/Image; then if ext4load mmc 0:3 ${fdt_addr_r} /boot/dtbs/rk3399-vivid-unit.dtb; then gpio clear 45; booti ${kernel_addr_r} - ${fdt_addr_r}; fi; fi; fi; bootflow scan -lb'
    preboot='setenv stdout serial,vidconsole; setenv stderr serial,vidconsole; gpio set 32'

    "$src_dir/scripts/config" --file "$build_dir/.config" \
      -e BOOTSTD -e BOOTSTD_FULL -e BOOTSTD_DEFAULTS \
      -e BOOTMETH_EXTLINUX -e BOOTMETH_DISTRO \
      -e USE_BOOTCOMMAND -e USE_PREBOOT \
      -e CONSOLE_MUX -e SYS_CONSOLE_IS_IN_ENV \
      -e CMD_GPIO \
      --set-str BOOTCOMMAND "$bootcmd" \
      --set-str PREBOOT "$preboot"
  fi

  make -C "$src_dir" O="$build_dir" ARCH=arm CROSS_COMPILE="$cross" BL31="$BL31" ROCKCHIP_TPL="$ROCKCHIP_TPL" olddefconfig

  vuos_log "U-Boot: build (jobs=$jobs)"
  # Build the key artifacts explicitly to avoid surprises.
  # Build default targets (this will also generate u-boot-rockchip.bin and usually idbloader.img)
  make -C "$src_dir" O="$build_dir" ARCH=arm CROSS_COMPILE="$cross" BL31="$BL31" ROCKCHIP_TPL="$ROCKCHIP_TPL" -j"$jobs"

  # Some U-Boot versions do NOT provide an explicit make target "idbloader.img" (it is generated as a by-product).
  # Ensure u-boot.itb exists (binman output) in case the default target set changes.
  if [[ ! -f "$build_dir/u-boot.itb" ]]; then
    make -C "$src_dir" O="$build_dir" ARCH=arm CROSS_COMPILE="$cross" BL31="$BL31" ROCKCHIP_TPL="$ROCKCHIP_TPL" -j"$jobs" u-boot.itb
  fi

  # Collect outputs
  [[ -f "$build_dir/idbloader.img" ]] || vuos_die "Missing build output: $build_dir/idbloader.img"
  [[ -f "$build_dir/u-boot.itb" ]] || vuos_die "Missing build output: $build_dir/u-boot.itb"

  cp -f "$build_dir/idbloader.img" "$stage_dir/idbloader.img"
  cp -f "$build_dir/u-boot.itb" "$stage_dir/u-boot.itb"
  [[ -f "$build_dir/u-boot-rockchip.bin" ]] && cp -f "$build_dir/u-boot-rockchip.bin" "$stage_dir/u-boot-rockchip.bin"
  [[ -f "$build_dir/u-boot.bin" ]] && cp -f "$build_dir/u-boot.bin" "$stage_dir/u-boot.bin"
  [[ -f "$build_dir/u-boot-dtb.bin" ]] && cp -f "$build_dir/u-boot-dtb.bin" "$stage_dir/u-boot-dtb.bin"
  [[ -f "$build_dir/.config" ]] && cp -f "$build_dir/.config" "$stage_dir/uboot.config"

  # Scheme B payload mapping for current Rockchip pack scripts:
  # - uboot partition still uses filename "uboot.img" but content is u-boot.itb
  cp -f "$stage_dir/u-boot.itb" "$stage_dir/uboot.img"

  vuos_log "U-Boot: scheme B outputs:"
  vuos_log "  idbloader.img -> $stage_dir/idbloader.img"
  vuos_log "  u-boot.itb    -> $stage_dir/u-boot.itb"
  vuos_log "  uboot.img     -> $stage_dir/uboot.img (copy of u-boot.itb)"

  # Install into board pack dir so 'vuos pack' will pick it up.
  if [[ "$do_install" == "1" ]]; then
    local rkbin_dir="$topdir/boards/$target/pack/rkbin"
    if [[ -d "$rkbin_dir" ]]; then
      mkdir -p "$rkbin_dir"

      # Backup existing files if present
      local ts
      ts="$(date +%Y%m%d-%H%M%S)"
      for f in idbloader.img u-boot.itb uboot.img; do
        if [[ -e "$rkbin_dir/$f" ]]; then
          cp -fL "$rkbin_dir/$f" "$rkbin_dir/$f.bak.$ts" 2>/dev/null || true
        fi
      done

      # Avoid following symlinks (some repos keep rkbin/* as symlinks into RKSDK).
      cp -f --remove-destination "$stage_dir/idbloader.img" "$rkbin_dir/idbloader.img"
      cp -f --remove-destination "$stage_dir/u-boot.itb" "$rkbin_dir/u-boot.itb"
      cp -f --remove-destination "$stage_dir/uboot.img" "$rkbin_dir/uboot.img"

      vuos_log "Installed (scheme B):"
      vuos_log "  $rkbin_dir/uboot.img         (u-boot.itb content)"
      vuos_log "  $rkbin_dir/u-boot.itb        (kept for reference)"
      vuos_log "  $rkbin_dir/idbloader.img     (kept for reference)"
    else
      vuos_warn "Board rkbin dir not found (skip install): $rkbin_dir"
    fi
  fi

  vuos_log "Done. Outputs in: $stage_dir"
}
