#!/usr/bin/env bash
# Common helpers for Vivid Unit OS build scripts.
#
# Keep this file Bash-only and dependency-light.

set -euo pipefail

vuos_die() {
  echo "ERROR: $*" >&2
  exit 1
}

vuos_log() {
  echo "==> $*" >&2
}

vuos_warn() {
  echo "WARN: $*" >&2
}

vuos_need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || vuos_die "Missing required command: $c"
  done
}

vuos_abspath() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$p" 2>/dev/null && return 0
  fi
  python3 - <<'PY' "$p"
import os,sys
print(os.path.abspath(sys.argv[1]))
PY
}

vuos_mkdir() {
  mkdir -p "$1"
}

vuos_mounts_under() {
  local root="$1"
  root="$(vuos_abspath "$root")"
  findmnt -R "$root" >/dev/null 2>&1
}

vuos_umount_tree() {
  local root="$1"
  local m

  root="$(vuos_abspath "$root")"
  [[ -n "$root" ]] || return 0
  [[ -e "$root" ]] || return 0

  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
  done < <(findmnt -R -n -o TARGET "$root" 2>/dev/null | tac)
}

vuos_die_if_mounts_under() {
  local root="$1"
  root="$(vuos_abspath "$root")"

  if vuos_mounts_under "$root"; then
    echo "ERROR: active mounts remain under $root:" >&2
    findmnt -R "$root" >&2 || true
    exit 1
  fi
}

vuos_chroot_mount() {
  local root="$1"

  root="$(vuos_abspath "$root")"
  [[ -n "$root" ]] || vuos_die "Refusing empty chroot root"
  [[ "$root" != "/" ]] || vuos_die "Refusing to mount chroot helpers on /"

  mkdir -p "$root/dev" "$root/proc" "$root/sys"

  # Use a recursive bind for /dev so the existing host /dev/pts, /dev/shm and
  # other submounts are mirrored into the chroot exactly as they already exist.
  # DO NOT mount a fresh devpts on $root/dev/pts after bind-mounting /dev: that
  # would target the host's /dev/pts mountpoint and can corrupt the host PTY
  # setup (for example bad ptmxmode/mode options), which is exactly the class of
  # failure we want to avoid here.
  mount --rbind /dev "$root/dev"
  mount --make-rslave "$root/dev"

  mount -t proc proc "$root/proc"
  mount -t sysfs sysfs "$root/sys"
}

vuos_chroot_umount() {
  local root="$1"
  vuos_umount_tree "$root"
}


vuos_sanitize_path_component() {
  local s="$1"
  s="${s//\//_}"
  s="${s// /_}"
  printf '%s\n' "$s" | tr -c 'A-Za-z0-9._-' '_'
}

vuos_git_prepare_mirror() {
  local url="$1" dst="$2"

  if git -C "$dst" rev-parse --is-bare-repository >/dev/null 2>&1; then
    git -C "$dst" remote set-url origin "$url" >/dev/null 2>&1 || true
    git -C "$dst" fetch --prune --tags origin >&2
    return 0
  fi

  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"
  git clone --mirror "$url" "$dst" >&2
}

vuos_git_reset_clean_checkout() {
  local repo="$1" ref="$2"

  git -C "$repo" reset --hard >&2 || true
  git -C "$repo" clean -fdx >&2 || true
  git -C "$repo" checkout -f "$ref" >&2
}

vuos_git_prepare_worktree() {
  local mirror="$1" wt="$2" ref="$3"

  mkdir -p "$(dirname "$wt")"

  if [[ -d "$wt/.git" || -f "$wt/.git" ]]; then
    git -C "$wt" fetch --tags origin >&2 || true
    vuos_git_reset_clean_checkout "$wt" "$ref"
    return 0
  fi

  rm -rf "$wt"
  git -C "$mirror" worktree add --force --detach "$wt" "$ref" >&2
  vuos_git_reset_clean_checkout "$wt" "$ref"
}
