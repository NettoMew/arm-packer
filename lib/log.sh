#!/usr/bin/env bash
# lib/log.sh — logging, command runners, downloader, have(). Sourced by scripts/build.sh.

log() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fatal() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
section() { printf '\n\033[1;36m==> %s\033[0m\n' "$*" >&2; }

run() {
  log "+ $*"
  "$@"
}

run_sudo() {
  log "+ ${SUDO:+sudo }$*"
  if [[ -n "${SUDO}" ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

aria2_download() {
  local url="$1" output="$2"
  local out_dir out_name
  out_dir="$(dirname "${output}")"
  out_name="$(basename "${output}")"
  mkdir -p "${out_dir}"
  run aria2c \
    --allow-overwrite=true \
    --auto-file-renaming=false \
    --continue=true \
    --max-connection-per-server=8 \
    --split=8 \
    --min-split-size=1M \
    --dir="${out_dir}" \
    --out="${out_name}" \
    "${url}"
}

have() { command -v "$1" >/dev/null 2>&1; }

# sha256_matches FILE SHA256 — true when FILE exists and has exactly that digest.
sha256_matches() { [[ -f "$1" && "$(sha256sum "$1" | cut -d' ' -f1)" == "$2" ]]; }
