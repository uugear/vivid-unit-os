#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shlex
import sys
from pathlib import Path

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # pip install tomli (fallback)

def die(msg: str, code: int = 2) -> None:
    print(f"manifest.py: {msg}", file=sys.stderr)
    raise SystemExit(code)

def find_topdir(start: Path) -> Path:
    """Walk upwards to find repo topdir (has scripts/ and boards/)."""
    p = start.resolve()
    for parent in [p] + list(p.parents):
        if (parent / "scripts").is_dir() and (parent / "boards").is_dir():
            return parent
    # Fallback: assume manifest's grandparent is repo root
    return start.resolve().parents[1] if len(start.resolve().parents) >= 2 else start.resolve().parent

def rpath(topdir: Path, s: str) -> str:
    """Resolve a repo-relative path into an absolute path string."""
    # Allow absolute paths in TOML too.
    p = Path(s)
    if p.is_absolute():
        return str(p)
    return str((topdir / p).resolve())

def emit_kv(key: str, value) -> None:
    # Scalar export
    if isinstance(value, bool):
        v = "1" if value else "0"
        print(f"export {key}={v}")
    elif isinstance(value, (int, float)):
        print(f"export {key}={value}")
    else:
        print(f"export {key}={shlex.quote(str(value))}")

def emit_array(key: str, items: list[str]) -> None:
    # Bash array (not exportable, but OK for eval in current shell)
    q = " ".join(shlex.quote(str(x)) for x in items)
    print(f"{key}=({q})")

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest", help="Path to TOML manifest (e.g. boards/vivid-unit/board.toml)")
    ap.add_argument("--topdir", default="", help="Repo topdir (optional). If omitted, auto-detect.")
    args = ap.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        die(f"manifest not found: {manifest_path}")

    topdir = Path(args.topdir).resolve() if args.topdir else find_topdir(manifest_path.parent)

    with manifest_path.open("rb") as f:
        data = tomllib.load(f)

    # Basic fields
    name = data.get("name") or manifest_path.parent.name
    arch = data.get("arch", "arm64")
    soc  = data.get("soc", "")

    emit_kv("TOPDIR", str(topdir))
    emit_kv("TARGET", name)
    emit_kv("ARCH", arch)
    if soc:
        emit_kv("SOC", soc)

    # Kernel section
    k = data.get("kernel", {})
    if not k:
        die("missing [kernel] section in manifest")

    emit_kv("KERNEL_VERSION", k.get("version", ""))
    emit_kv("KERNEL_RELEASE", k.get("release", k.get("version", "")))
    emit_kv("KERNEL_DEFCONFIG", rpath(topdir, k["defconfig"]))

    dts_list = k.get("dts", [])
    if not isinstance(dts_list, list) or not dts_list:
        die("[kernel].dts must be a non-empty list")
    emit_array("KERNEL_DTS", [rpath(topdir, p) for p in dts_list])

    patch_dirs = k.get("patch_dirs", [])
    if patch_dirs:
        if not isinstance(patch_dirs, list):
            die("[kernel].patch_dirs must be a list")
        emit_array("KERNEL_PATCH_DIRS", [rpath(topdir, p) for p in patch_dirs])
    else:
        emit_array("KERNEL_PATCH_DIRS", [])

    src = k.get("source", {})
    emit_kv("KERNEL_SOURCE_TYPE", src.get("type", "git"))
    emit_kv("KERNEL_SOURCE_URL",  src.get("url",  "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"))
    emit_kv("KERNEL_SOURCE_REF",  src.get("ref",  f"v{k.get('version','')}"))


    # ATF / TF-A section
    a = data.get("atf", {})
    if a:
        if a.get("ref"):
            emit_kv("ATF_VERSION_REF", a.get("ref"))
        if a.get("url"):
            emit_kv("ATF_GIT_URL", a.get("url"))
        if a.get("platform"):
            emit_kv("ATF_PLATFORM", a.get("platform"))
        if a.get("target"):
            emit_kv("ATF_TARGET", a.get("target"))

    # U-Boot section
    u = data.get("uboot", {})
    if u:
        # These variables are consumed by scripts/vuos-uboot.sh
        if u.get("ref"):
            emit_kv("UBOOT_VERSION_REF", u.get("ref"))
        if u.get("url"):
            emit_kv("UBOOT_GIT_URL", u.get("url"))
        if u.get("defconfig"):
            emit_kv("UBOOT_DEFCONFIG", u.get("defconfig"))
        if u.get("device_tree"):
            emit_kv("UBOOT_DEVICE_TREE", u.get("device_tree"))

        u_dts = u.get("dts", [])
        if u_dts:
            if not isinstance(u_dts, list):
                die("[uboot].dts must be a list")
            emit_array("UBOOT_DTS", [rpath(topdir, pp) for pp in u_dts])
        else:
            emit_array("UBOOT_DTS", [])

        u_patch_dirs = u.get("patch_dirs", [])
        if u_patch_dirs:
            if not isinstance(u_patch_dirs, list):
                die("[uboot].patch_dirs must be a list")
            emit_array("UBOOT_PATCH_DIRS", [rpath(topdir, pp) for pp in u_patch_dirs])
        else:
            emit_array("UBOOT_PATCH_DIRS", [])

        u_overlay_dirs = u.get("overlay_dirs", [])
        if u_overlay_dirs:
            if not isinstance(u_overlay_dirs, list):
                die("[uboot].overlay_dirs must be a list")
            emit_array("UBOOT_OVERLAY_DIRS", [rpath(topdir, pp) for pp in u_overlay_dirs])
        else:
            emit_array("UBOOT_OVERLAY_DIRS", [])
    else:
        emit_array("UBOOT_DTS", [])
        emit_array("UBOOT_PATCH_DIRS", [])
        emit_array("UBOOT_OVERLAY_DIRS", [])

    # Rootfs section
    r = data.get("rootfs", {})
    if r:
        emit_kv("ROOTFS_SUITE", r.get("suite", "bookworm"))
        emit_kv("ROOTFS_VARIANT", r.get("variant", "minbase"))

        overlays = []
        for key in ("common_overlay", "suite_overlay", "board_overlay"):
            if r.get(key):
                overlays.append(rpath(topdir, r[key]))
        emit_array("ROOTFS_OVERLAYS", overlays)
    else:
        emit_array("ROOTFS_OVERLAYS", [])

    # Pack section
    p = data.get("pack", {})
    if p:
        # Used by scripts/vuos-pack.sh / scripts/lib/pack.sh
        if p.get("boot_format"):
            emit_kv("PACK_BOOT_FORMAT", p.get("boot_format"))
        if p.get("splash"):
            emit_kv("PACK_SPLASH", rpath(topdir, p.get("splash")))

if __name__ == "__main__":
    main()
