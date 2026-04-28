#!/usr/bin/env bash
# Kernel headers packaging logic for Vivid Unit OS.
#
# This file is intended to be sourced by scripts/vuos-headers.sh.
#
# Goal:
# - Create an optional installable linux-headers .deb for the exact kernel
#   release shipped by a VUOS image.
# - Do not run as part of the default image build.
# - Reuse the already-built kernel source/output trees so Module.symvers,
#   generated headers and host build scripts match the shipped kernel.

set -euo pipefail

# shellcheck source=/dev/null
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

_vuos_headers_usage() {
  cat >&2 <<'USAGE'
Usage:
  vuos headers <target> [options]

Options:
  --clean                 Remove out/headers/<target> before packaging
  --revision <rev>        Header package revision suffix (default: 1)
  --deb-arch <arch>       Debian package architecture (default: arm64)
  --output-name <name>    Output .deb filename override

Environment variables:
  OUT_DIR                 Top-level output dir (default: <repo>/out)
  KERNEL_SRC              Path to the patched Linux source tree
                         (default: out/src/kernel/linux-<version>)
  KERNEL_OUT              Kernel build output dir used as O=
                         (default: out/kernel/<target>/build)
  HEADERS_REVISION        Same as --revision (default: 1)
  HEADERS_DEB_ARCH        Same as --deb-arch (default: arm64)
  HEADERS_DEB_FILENAME    Same as --output-name

Expected input:
  Run the matching kernel build first, for example:
    ./vuos kernel vivid-unit

Output:
  out/headers/<target>/linux-headers-<kernel-release>-<revision>_<arch>.deb

Example:
  ./vuos headers vivid-unit
  sudo apt install ./out/headers/vivid-unit/linux-headers-6.12.73-vuos-1_arm64.deb
USAGE
}

_vuos_headers_find_topdir() {
  local here
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  (cd -- "$here/../.." && pwd)
}

_vuos_headers_load_manifest() {
  local topdir="$1" target="$2"
  local manifest="$topdir/boards/$target/board.toml"
  local py="$topdir/scripts/lib/manifest.py"
  [[ -f "$manifest" ]] || vuos_die "Board manifest not found: $manifest"
  [[ -f "$py" ]] || vuos_die "manifest.py not found: $py"
  eval "$(python3 "$py" "$manifest" --topdir "$topdir")"
}

_vuos_headers_check_input_tree() {
  local ksrc="$1" kout="$2"

  [[ -d "$ksrc" ]] || vuos_die "Kernel source tree not found: $ksrc. Run './vuos kernel <target>' first, or set KERNEL_SRC."
  [[ -d "$kout" ]] || vuos_die "Kernel build tree not found: $kout. Run './vuos kernel <target>' first, or set KERNEL_OUT."
  [[ -f "$kout/.config" ]] || vuos_die "Kernel build tree is missing .config: $kout/.config. Run './vuos kernel <target>' first."
  [[ -f "$ksrc/Makefile" ]] || vuos_die "Kernel source tree is missing Makefile: $ksrc/Makefile"

  if [[ ! -f "$kout/Module.symvers" ]]; then
    vuos_warn "Kernel build tree has no Module.symvers. External modules may build, but symbol-version checks may be incomplete."
  fi
}

_vuos_headers_rsync_source_subset() {
  local ksrc="$1" hdr="$2" arch="$3"

  vuos_log "Headers: copying source headers/build scripts"
  rsync -a --delete \
    --include='/Makefile' \
    --include='/Kbuild' \
    --include='/Kconfig' \
    --include='/include/***' \
    --include='/scripts/***' \
    --include='/arch/' \
    --include="/arch/$arch/" \
    --include="/arch/$arch/***" \
    --exclude='*' \
    "$ksrc/" "$hdr/"
}

_vuos_headers_rsync_build_subset() {
  local kout="$1" hdr="$2" arch="$3"

  vuos_log "Headers: overlaying generated build files"
  rsync -a \
    --include='/.config' \
    --include='/Module.symvers' \
    --include='/System.map' \
    --include='/include/***' \
    --include='/scripts/***' \
    --include='/arch/' \
    --include="/arch/$arch/" \
    --include="/arch/$arch/include/***" \
    --include="/arch/$arch/kernel/" \
    --include="/arch/$arch/kernel/module.lds" \
    --exclude='*' \
    "$kout/" "$hdr/"
}

_vuos_headers_sanitize_host_artifacts() {
  local hdr="$1"

  # The kernel build tree is normally produced on the build host. Files such
  # as scripts/basic/fixdep and scripts/mod/modpost are HOSTCC-built binaries.
  # If they are copied into an arm64 headers package from an x86_64 build host,
  # building external modules on the Vivid Unit fails with "Exec format error".
  #
  # Keep source files, generated headers, Module.symvers and linker scripts,
  # but remove host-built ELF tools and stale Kbuild command/object files.
  # Kbuild will rebuild the needed host tools natively on the target when an
  # external module is compiled.
  vuos_log "Headers: removing host-built build artifacts"

  local base f desc
  for base in "$hdr/scripts" "$hdr/tools"; do
    [[ -d "$base" ]] || continue

    while IFS= read -r -d '' f; do
      desc="$(file -b "$f" 2>/dev/null || true)"
      case "$desc" in
        *ELF*) rm -f "$f" ;;
      esac
    done < <(find "$base" -type f -print0)

    find "$base" -type f \( \
      -name '*.o' -o \
      -name '*.o.cmd' -o \
      -name '.*.cmd' -o \
      -name '*.cmd' -o \
      -name '*.a' -o \
      -name '*.so' -o \
      -name '*.s' \
    \) -delete
  done
}

_vuos_headers_create_tree() {
  local ksrc="$1" kout="$2" hdr="$3" arch="$4" krel="$5" target="$6"

  rm -rf "$hdr"
  mkdir -p "$hdr"

  _vuos_headers_rsync_source_subset "$ksrc" "$hdr" "$arch"
  _vuos_headers_rsync_build_subset "$kout" "$hdr" "$arch"
  _vuos_headers_sanitize_host_artifacts "$hdr"

  # Kbuild normally reads this from include/config/kernel.release when present.
  mkdir -p "$hdr/include/config"
  printf '%s\n' "$krel" > "$hdr/include/config/kernel.release"

  cat > "$hdr/vuos-headers-info" <<EOF_INFO
Target: $target
Kernel-Release: $krel
Kernel-Source: $ksrc
Kernel-Output: $kout
Built-At: $(date -Is)
EOF_INFO
}

_vuos_headers_write_control() {
  local pkgroot="$1" pkg_name="$2" pkg_version="$3" deb_arch="$4" krel="$5" installed_size="$6"

  mkdir -p "$pkgroot/DEBIAN"
  cat > "$pkgroot/DEBIAN/control" <<EOF_CONTROL
Package: $pkg_name
Version: $pkg_version
Architecture: $deb_arch
Maintainer: UUGear <support@uugear.com>
Section: kernel
Priority: optional
Installed-Size: $installed_size
Depends: make, gcc, libc6-dev
Recommends: bc, libelf-dev, flex, bison
Description: Linux kernel headers for Vivid Unit OS $krel
 This package provides the matching kernel header/build tree for building
 out-of-tree kernel modules against the Vivid Unit OS kernel $krel.
EOF_CONTROL
}

_vuos_headers_write_maintainer_scripts() {
  local pkgroot="$1" krel="$2" arch="$3"

  mkdir -p "$pkgroot/DEBIAN"

  cat > "$pkgroot/DEBIAN/postinst" <<EOF_POSTINST
#!/bin/sh
set -e

KREL="$krel"
ARCH="$arch"
HDR="/usr/src/linux-headers-\$KREL"
MODDIR="/lib/modules/\$KREL"
HOSTCC="\${HOSTCC:-gcc}"
HOSTCFLAGS="\${HOSTCFLAGS:--O2 -Wall -Wmissing-prototypes -Wstrict-prototypes}"

compile_fixdep() {
  [ -f "\$HDR/scripts/basic/fixdep.c" ] || return 0
  mkdir -p "\$HDR/scripts/basic"
  \$HOSTCC \$HOSTCFLAGS \
    -I"\$HDR/scripts/include" \
    -o "\$HDR/scripts/basic/fixdep" \
    "\$HDR/scripts/basic/fixdep.c"
}

compile_modpost() {
  [ -f "\$HDR/scripts/mod/modpost.c" ] || return 0
  [ -f "\$HDR/scripts/mod/file2alias.c" ] || return 0
  [ -f "\$HDR/scripts/mod/sumversion.c" ] || return 0
  [ -f "\$HDR/scripts/mod/symsearch.c" ] || return 0
  [ -f "\$HDR/scripts/mod/elfconfig.h" ] || return 0
  [ -f "\$HDR/scripts/mod/devicetable-offsets.h" ] || return 0

  mkdir -p "\$HDR/scripts/mod"
  \$HOSTCC \$HOSTCFLAGS \
    -I"\$HDR/scripts/include" \
    -I"\$HDR/scripts/mod" \
    -o "\$HDR/scripts/mod/modpost" \
    "\$HDR/scripts/mod/modpost.c" \
    "\$HDR/scripts/mod/file2alias.c" \
    "\$HDR/scripts/mod/sumversion.c" \
    "\$HDR/scripts/mod/symsearch.c"
}

case "\$1" in
  configure)
    if [ -d "\$HDR" ]; then
      mkdir -p "\$MODDIR"
      ln -sfn "\$HDR" "\$MODDIR/build"
      ln -sfn "\$HDR" "\$MODDIR/source"

      # Do not call kernel make targets such as scripts_basic here. This
      # package intentionally contains only a headers/build subset, not the
      # full kernel source tree, so those targets may trigger syncconfig and
      # fail when Kconfig files such as init/Kconfig are absent.
      #
      # Instead, build only the small Kbuild host tools that are required
      # when compiling external modules on the Vivid Unit. They must be native
      # arm64 executables, not x86_64 binaries copied from the build host.
      compile_fixdep
      compile_modpost
    fi
    ;;
esac

exit 0
EOF_POSTINST

  cat > "$pkgroot/DEBIAN/postrm" <<EOF_POSTRM
#!/bin/sh
set -e

KREL="$krel"
HDR="/usr/src/linux-headers-\$KREL"
MODDIR="/lib/modules/\$KREL"

case "\$1" in
  remove|purge)
    rm -f "\$MODDIR/build" "\$MODDIR/source"
    # dpkg removes packaged files, but postinst-generated Kbuild helper
    # tools are not tracked as package payload. Remove the whole header
    # tree to avoid stale native build artifacts after package removal.
    rm -rf "\$HDR"
    ;;
esac

exit 0
EOF_POSTRM

  chmod 0755 "$pkgroot/DEBIAN/postinst" "$pkgroot/DEBIAN/postrm"
}

_vuos_headers_write_md5sums() {
  local pkgroot="$1"

  (
    cd "$pkgroot"
    find . -type f ! -path './DEBIAN/*' -printf '%P\0' \
      | sort -z \
      | xargs -0 --no-run-if-empty md5sum
  ) > "$pkgroot/DEBIAN/md5sums"
}

vuos_headers_main() {
  local topdir
  topdir="$(_vuos_headers_find_topdir)"

  local target="${1:-}"
  shift || true
  [[ -n "$target" ]] || { _vuos_headers_usage; exit 2; }

  local do_clean=0
  local revision="${HEADERS_REVISION:-1}"
  local deb_arch="${HEADERS_DEB_ARCH:-arm64}"
  local output_name="${HEADERS_DEB_FILENAME:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clean) do_clean=1; shift ;;
      --revision) revision="${2:?missing revision}"; shift 2 ;;
      --deb-arch) deb_arch="${2:?missing Debian architecture}"; shift 2 ;;
      --output-name) output_name="${2:?missing output filename}"; shift 2 ;;
      -h|--help) _vuos_headers_usage; exit 0 ;;
      *) vuos_die "Unknown option: $1" ;;
    esac
  done

  _vuos_headers_load_manifest "$topdir" "$target"

  local krel="${KERNEL_RELEASE:-}"
  [[ -n "$krel" ]] || vuos_die "KERNEL_RELEASE is empty; check boards/$target/board.toml"

  local arch="${ARCH:-arm64}"
  local kver="${KERNEL_VERSION:-$krel}"
  local out_dir="${OUT_DIR:-$topdir/out}"
  out_dir="$(vuos_abspath "$out_dir")"

  local ksrc="${KERNEL_SRC:-$out_dir/src/kernel/linux-$kver}"
  local kout="${KERNEL_OUT:-$out_dir/kernel/$target/build}"
  ksrc="$(vuos_abspath "$ksrc")"
  kout="$(vuos_abspath "$kout")"

  _vuos_headers_check_input_tree "$ksrc" "$kout"

  local out_base="$out_dir/headers/$target"
  if [[ "$do_clean" == "1" ]]; then
    vuos_log "Cleaning output: $out_base"
    rm -rf "$out_base"
  fi

  local pkgroot="$out_base/pkgroot"
  local hdr="$pkgroot/usr/src/linux-headers-$krel"
  rm -rf "$pkgroot"
  mkdir -p "$pkgroot"

  _vuos_headers_create_tree "$ksrc" "$kout" "$hdr" "$arch" "$krel" "$target"

  mkdir -p "$pkgroot/lib/modules/$krel"
  ln -sfn "/usr/src/linux-headers-$krel" "$pkgroot/lib/modules/$krel/build"
  ln -sfn "/usr/src/linux-headers-$krel" "$pkgroot/lib/modules/$krel/source"

  local pkg_name="linux-headers-$krel"
  local pkg_version="$krel-$revision"
  if [[ -z "$output_name" ]]; then
    output_name="linux-headers-${krel}-${revision}_${deb_arch}.deb"
  fi

  local installed_size
  installed_size="$(du -sk "$pkgroot/usr" "$pkgroot/lib" 2>/dev/null | awk '{s += $1} END {print s + 0}')"

  _vuos_headers_write_control "$pkgroot" "$pkg_name" "$pkg_version" "$deb_arch" "$krel" "$installed_size"
  _vuos_headers_write_maintainer_scripts "$pkgroot" "$krel" "$arch"
  _vuos_headers_write_md5sums "$pkgroot"

  mkdir -p "$out_base"
  local deb="$out_base/$output_name"
  rm -f "$deb"

  vuos_need_cmd dpkg-deb rsync awk sort xargs md5sum file
  vuos_log "Headers: building package -> $deb"
  dpkg-deb --build --root-owner-group "$pkgroot" "$deb" >/dev/null

  vuos_log "Done. Output: $deb"
}
