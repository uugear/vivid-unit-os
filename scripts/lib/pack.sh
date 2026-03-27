#!/usr/bin/env bash
# Pack logic for Vivid Unit OS.
#
# RAW image is the only supported release artifact.
#
# Responsibilities:
# - Merge kernel modules into rootfs.img
# - Install kernel + DTB + extlinux.conf into rootfs /boot
# - Shrink rootfs.img to minimal size + slack
# - Generate an ext4 boot.img containing Image + DTB + extlinux.conf
# - Assemble a GPT raw disk image for rkdeveloptool flashing

set -euo pipefail

_vuos_pack_usage() {
  cat >&2 <<'USAGE'
Usage:
  sudo vuos pack <target> [options]

Options:
  --clean                 Remove output directory before packing
  --no-modules            Do not merge kernel modules into rootfs.img
  --no-shrink             Do not shrink rootfs.img (keeps size as-is)
  --slack <MiB>           Extra free space after shrink (default: 128)

Environment variables:
  OUT_DIR                 Top-level output dir (default: <repo>/out)

  # Kernel cmdline written into extlinux.conf (rootfs + boot partition)
  BOOT_CMDLINE            Default:
                          earlycon=uart8250,mmio32,0xff1a0000 console=tty1 console=ttyS2,115200n8 root=/dev/mmcblk0p3 rootwait rw rootfstype=ext4 loglevel=7 ignore_loglevel fbcon=nodefer logo.nologo

Expected inputs:
  Kernel outputs:
    out/kernel/<target>/Image
    out/kernel/<target>/dtbs/*.dtb
    out/kernel/<target>/modules/lib/modules/<KERNEL_RELEASE>/...

  Rootfs output:
    out/rootfs/<target>/rootfs.img

Outputs:
  out/pack/<target>/vuos-<version>.img
  out/pack/<target>/Image/rootfs.img
  out/pack/<target>/Image/boot.img
USAGE
}

_vuos_pack_find_topdir() {
  local here
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  (cd -- "$here/../.." && pwd)
}

_vuos_pack_load_board_manifest() {
  local topdir="$1" target="$2"
  local manifest="$topdir/boards/$target/board.toml"
  local py="$topdir/scripts/lib/manifest.py"
  [[ -f "$manifest" ]] || vuos_die "Board manifest not found: $manifest"
  [[ -f "$py" ]] || vuos_die "manifest.py not found: $py"
  eval "$(python3 "$py" "$manifest" --topdir "$topdir")"
}

_vuos_pack_merge_kernel_modules() {
  local rootfs_img="$1" kernel_out="$2" krel="$3"

  local src_mod="$kernel_out/modules/lib/modules/$krel"
  [[ -d "$src_mod" ]] || vuos_die "Kernel modules not found: $src_mod"

  (
    set -euo pipefail
    local mnt
    mnt="$(mktemp -d)"
    trap 'umount -q "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT

    mount -o loop "$rootfs_img" "$mnt"

    rm -rf "$mnt/lib/modules/$krel"
    mkdir -p "$mnt/lib/modules/$krel"
    rsync -aHAX --numeric-ids --safe-links \
      --exclude='build' --exclude='source' \
      "$src_mod/" "$mnt/lib/modules/$krel/"

    sync
    umount "$mnt"
    rmdir "$mnt"
  )
}

_vuos_pack_install_rootfs_extlinux() {
  # Install kernel Image + DTB into rootfs.img and generate /boot/extlinux/extlinux.conf
  # so U-Boot can boot directly from the rootfs partition as a fallback.
  local rootfs_img="$1" kernel_out="$2" dtb_name="$3" cmdline="$4"

  local img="$kernel_out/Image"
  local dtb="$kernel_out/dtbs/$dtb_name"
  [[ -f "$img" ]] || vuos_die "Kernel Image not found: $img"
  [[ -f "$dtb" ]] || vuos_die "DTB not found: $dtb"

  (
    set -euo pipefail
    local mnt
    mnt="$(mktemp -d)"
    trap 'umount -q "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT

    mount -o loop "$rootfs_img" "$mnt"

    mkdir -p "$mnt/boot" "$mnt/boot/dtbs" "$mnt/boot/extlinux"
    cp -fL "$img" "$mnt/boot/Image"
    cp -fL "$dtb" "$mnt/boot/dtbs/$dtb_name"

    cat > "$mnt/boot/extlinux/extlinux.conf" <<EOC
DEFAULT vivid
TIMEOUT 0
MENU TITLE Vivid Unit OS

LABEL vivid
  KERNEL /boot/Image
  FDT /boot/dtbs/$dtb_name
  APPEND $cmdline
EOC

    sync
    umount "$mnt"
    rmdir "$mnt"
  )
}

_vuos_pack_shrink_ext4_image() {
  local img="$1" slack_mib="$2"

  local extra=$((slack_mib*1024*1024))
  local min_bytes

  vuos_need_cmd e2fsck tune2fs resize2fs dumpe2fs awk truncate

  e2fsck -fy "$img" >/dev/null
  tune2fs -m 0 "$img" >/dev/null || true
  resize2fs -M "$img" >/dev/null

  min_bytes="$(dumpe2fs -h "$img" 2>/dev/null | awk -F: '
    /Block count/ {gsub(/ /,"",$2); bc=$2}
    /Block size/  {gsub(/ /,"",$2); bs=$2}
    END {print bc*bs}')"

  [[ -n "$min_bytes" && "$min_bytes" -gt 0 ]] || vuos_die "Failed to determine minimized size for $img"

  truncate -s $((min_bytes + extra)) "$img"
  resize2fs "$img" >/dev/null
}

_vuos_pack_make_boot_img_extlinux() {
  local out_boot_img="$1" kernel_out="$2" dtb_name="$3" slack_mib="$4" cmdline="$5"

  local img="$kernel_out/Image"
  local dtb="$kernel_out/dtbs/$dtb_name"
  [[ -f "$img" ]] || vuos_die "Kernel Image not found: $img"
  [[ -f "$dtb" ]] || vuos_die "DTB not found: $dtb"

  (
    set -euo pipefail
    local tmpdir mnt
    tmpdir="$(mktemp -d)"
    mnt="$(mktemp -d)"
    trap 'umount -q "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; rm -rf "$tmpdir" 2>/dev/null || true' EXIT

    mkdir -p "$tmpdir/extlinux" "$tmpdir/dtbs"
    cp -fL "$img" "$tmpdir/Image"
    cp -fL "$dtb" "$tmpdir/dtbs/$dtb_name"

    cat > "$tmpdir/extlinux/extlinux.conf" <<EOC
DEFAULT vivid
TIMEOUT 0

LABEL vivid
  KERNEL /Image
  FDT /dtbs/$dtb_name
  APPEND $cmdline
EOC

    rm -f "$out_boot_img"
    truncate -s 256M "$out_boot_img"
    mkfs.ext4 -F -L boot -O ^metadata_csum,^64bit,^orphan_file "$out_boot_img" >/dev/null

    mount -o loop "$out_boot_img" "$mnt"
    rsync -aLHAX --numeric-ids "$tmpdir/" "$mnt/"
    sync
    umount "$mnt"

    _vuos_pack_shrink_ext4_image "$out_boot_img" "$slack_mib"
  )
}

# -----------------------------------------------------------------------------
# Raw disk image output
# -----------------------------------------------------------------------------

_vuos_pack_align_up() {
  local v="$1" a="$2"
  echo $(( ( (v + a - 1) / a ) * a ))
}

_vuos_pack_pick_version() {
  local pack_out="$1"

  if [[ -n "${VUOS_VERSION:-}" ]]; then
    echo "$VUOS_VERSION"
    return 0
  fi

  local version_tz="${VUOS_VERSION_TZ:-${VU_TZ:-Europe/Amsterdam}}"
  local build_date
  build_date="$(TZ="$version_tz" date +%Y%m%d)"

  local max_seq=0
  local f base seq
  shopt -s nullglob
  for f in "$pack_out"/vuos-"$build_date"-*.img; do
    base="${f##*/}"
    seq="${base#vuos-$build_date-}"
    seq="${seq%.img}"
    [[ "$seq" =~ ^[0-9]+$ ]] || continue
    if (( seq > max_seq )); then
      max_seq=$seq
    fi
  done
  shopt -u nullglob

  echo "$build_date-$((max_seq + 1))"
}

_vuos_pack_make_raw_image() {
  local topdir="$1" out_dir="$2" target="$3" pack_out="$4" rkbin_dir="$5" version="$6"

  local bootloader_bin="$out_dir/uboot/$target/u-boot-rockchip.bin"
  if [[ ! -s "$bootloader_bin" ]]; then
    vuos_die "Raw image: missing u-boot-rockchip.bin at: $bootloader_bin (run: ./vuos uboot $target)"
  fi

  local boot_img="$pack_out/Image/boot.img"
  local rootfs_img="$pack_out/Image/rootfs.img"

  if [[ ! -s "$boot_img" ]]; then
    vuos_die "Raw image: missing boot.img at: $boot_img"
  fi
  if [[ ! -s "$rootfs_img" ]]; then
    vuos_die "Raw image: missing rootfs.img at: $rootfs_img"
  fi

  local raw_img="$pack_out/vuos-${version}.img"

  local SECTOR=512
  local ALIGN4M=$((4*1024*1024))
  local ALIGN1M=$((1*1024*1024))

  local env_start_b=$((16*1024*1024))
  local env_size_b=$((64*1024))
  local boot_start_b=$((20*1024*1024))

  local boot_size_b
  boot_size_b=$(stat -c '%s' "$boot_img")
  local boot_part_b
  boot_part_b=$(_vuos_pack_align_up "$boot_size_b" "$ALIGN4M")

  local rootfs_start_b
  rootfs_start_b=$(_vuos_pack_align_up $((boot_start_b + boot_part_b)) "$ALIGN4M")

  local rootfs_size_b
  rootfs_size_b=$(stat -c '%s' "$rootfs_img")
  local rootfs_part_b
  rootfs_part_b=$(_vuos_pack_align_up "$rootfs_size_b" "$ALIGN4M")

  local disk_end_b
  disk_end_b=$(_vuos_pack_align_up $((rootfs_start_b + rootfs_part_b + 16*1024*1024)) "$ALIGN1M")

  local env_start_lba=$((env_start_b / SECTOR))
  local env_last_lba=$(((env_start_b + env_size_b) / SECTOR - 1))

  local boot_start_lba=$((boot_start_b / SECTOR))
  local boot_last_lba=$(((boot_start_b + boot_part_b) / SECTOR - 1))

  local rootfs_start_lba=$((rootfs_start_b / SECTOR))
  local rootfs_last_lba=$(((rootfs_start_b + rootfs_part_b) / SECTOR - 1))

  echo "==> Raw image: creating GPT image: $raw_img"
  python3 "$topdir/scripts/lib/vuos_gpt.py" \
    --image "$raw_img" \
    --size-bytes "$disk_end_b" \
    --part "uboot-env:${env_start_lba}:${env_last_lba}" \
    --part "boot:${boot_start_lba}:${boot_last_lba}" \
    --part "rootfs:${rootfs_start_lba}:${rootfs_last_lba}"

  dd if="$bootloader_bin" of="$raw_img" bs=1K seek=32 conv=notrunc status=none

  echo "==> Raw image: writing boot.img @ LBA ${boot_start_lba}"
  dd if="$boot_img" of="$raw_img" bs=512 seek="$boot_start_lba" conv=notrunc status=progress

  echo "==> Raw image: writing rootfs.img @ LBA ${rootfs_start_lba}"
  dd if="$rootfs_img" of="$raw_img" bs=512 seek="$rootfs_start_lba" conv=notrunc status=progress

  sync

  echo "==> Raw image: done: $raw_img"
  echo "==> Flash example (rkdeveloptool):"
  echo "==>   rkdeveloptool db <rk3399_loader_v1.xx.bin>"
  echo "==>   rkdeveloptool wl 0 \"$raw_img\""
  echo "==>   rkdeveloptool rd"
}

vuos_pack_main() {
  local topdir
  topdir="$(_vuos_pack_find_topdir)"

  # shellcheck source=/dev/null
  source "$topdir/scripts/lib/common.sh"

  local target="${1:-}"; shift || true
  [[ -n "$target" ]] || { _vuos_pack_usage; exit 2; }

  local do_clean=0 do_modules=1 do_shrink=1
  local slack_mib=128

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clean) do_clean=1; shift ;;
      --no-modules) do_modules=0; shift ;;
      --no-shrink) do_shrink=0; shift ;;
      --slack) slack_mib="${2:?missing MiB}"; shift 2 ;;
      -h|--help) _vuos_pack_usage; exit 0 ;;
      *) vuos_die "Unknown option: $1" ;;
    esac
  done

  [[ "${EUID:-$(id -u)}" == "0" ]] || vuos_die "Pack stage needs root (loop mount). Please run with sudo."

  _vuos_pack_load_board_manifest "$topdir" "$target"

  local out_dir="${OUT_DIR:-$topdir/out}"
  out_dir="$(vuos_abspath "$out_dir")"

  local kernel_out="$out_dir/kernel/$target"
  local rootfs_out="$out_dir/rootfs/$target"
  local pack_out="$out_dir/pack/$target"

  local rootfs_img_src="$rootfs_out/rootfs.img"
  [[ -f "$rootfs_img_src" ]] || vuos_die "rootfs.img not found. Please run: sudo ./vuos rootfs $target"
  [[ -f "$kernel_out/Image" ]] || vuos_die "Kernel Image not found. Please run: ./vuos kernel $target"

  local krel="${KERNEL_RELEASE:-${KERNEL_VERSION:-}}"
  [[ -n "$krel" ]] || vuos_die "KERNEL_RELEASE/KERNEL_VERSION missing"

  local dtb_name
  dtb_name="$(basename "${KERNEL_DTS[0]}" .dts).dtb"

  if [[ "$do_clean" == "1" ]]; then
    rm -rf "$pack_out"
  fi
  mkdir -p "$pack_out" "$pack_out/Image" "$pack_out/logs"

  local board_pack="$topdir/boards/$target/pack"
  local rkbin="$board_pack/rkbin"
  mkdir -p "$rkbin"

  local rootfs_img="$pack_out/Image/rootfs.img"
  cp -fL "$rootfs_img_src" "$rootfs_img"

  if [[ "$do_modules" == "1" ]]; then
    vuos_log "Merging kernel modules into rootfs.img ($krel)"
    _vuos_pack_merge_kernel_modules "$rootfs_img" "$kernel_out" "$krel"
  else
    vuos_warn "Skipping kernel modules merge (requested)"
  fi

  local default_cmdline="earlycon=uart8250,mmio32,0xff1a0000 console=tty1 console=ttyS2,115200n8 root=/dev/mmcblk0p3 rootwait rw rootfstype=ext4 loglevel=7 ignore_loglevel fbcon=nodefer logo.nologo"
  local rootfs_cmdline="${BOOT_CMDLINE:-$default_cmdline}"
  _vuos_pack_install_rootfs_extlinux "$rootfs_img" "$kernel_out" "$dtb_name" "$rootfs_cmdline"

  if [[ "$do_shrink" == "1" ]]; then
    vuos_log "Shrinking rootfs.img to minimum + ${slack_mib}MiB"
    _vuos_pack_shrink_ext4_image "$rootfs_img" "$slack_mib"
  else
    vuos_warn "Skipping rootfs.img shrink (requested)"
  fi

  local boot_img="$pack_out/Image/boot.img"
  local boot_cmdline="${BOOT_CMDLINE:-$default_cmdline}"
  vuos_log "Generating boot.img (extlinux)"
  _vuos_pack_make_boot_img_extlinux "$boot_img" "$kernel_out" "$dtb_name" 32 "$boot_cmdline"

  local pack_version
  pack_version="$(_vuos_pack_pick_version "$pack_out")"

  _vuos_pack_make_raw_image "$topdir" "$out_dir" "$target" "$pack_out" "$rkbin" "$pack_version"

  vuos_log "Done. Outputs: $pack_out"
  echo "Raw image: $pack_out/vuos-${pack_version}.img"
}
