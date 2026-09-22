#!/usr/bin/env bash
# Explicit candidate selection -> isolated validation -> hardware testing -> promotion.
set -Eeuo pipefail
IFS=$'\n\t'
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_DIR}/lib/log.sh"
source "${PROJECT_DIR}/config/versions.conf"
source "${PROJECT_DIR}/lib/kernel-update.sh"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/kernel-update.sh show
  BOARD=m28k bash scripts/kernel-update.sh check vX.Y.Z [--dry-run]
  BOARD=m28k bash scripts/kernel-update.sh build vX.Y.Z [--dry-run]
  bash scripts/kernel-update.sh promote /path/to/validation.txt --tested

check: patch kernel/drivers, resolve Kconfig and compile the selected DTB.
build: additionally compile Image, in-tree modules and board out-of-tree modules.
Both use a fresh work/kernel-validation/ directory, not your normal workspace.
Neither builds/updates U-Boot, firmware blobs, rootfs or images; neither runs sudo.
promote requires a build report plus YOUR confirmation of real-device testing.
KERNEL_REF may supply the tag; REPORT and HARDWARE_TESTED=1 may supply promote args.
Ordinary builds never follow latest automatically. See docs/kernel-updates.md.
EOF
}

action="${1:-help}"
(( $# == 0 )) || shift
case "${action}" in
  show)
    (( $# == 0 )) || fatal "show takes no arguments."
    printf 'Kernel: %s @ %s\n' "${DEFAULT_KERNEL_REPO}" "${DEFAULT_KERNEL_REF}" ;;
  check|build)
    ref="${KERNEL_REF:-}"
    if (( $# > 0 )) && [[ "$1" != --dry-run ]]; then ref="$1"; shift; fi
    kernel_require_release_tag "${ref}"
    args=("--kernel-${action}")
    if (( $# > 0 )) && [[ "$1" == --dry-run ]]; then args+=(--dry-run); shift; fi
    (( $# == 0 )) || fatal "Unexpected arguments; use --help."
    export KERNEL_REF="${ref}"
    exec bash "${PROJECT_DIR}/scripts/build.sh" "${args[@]}" ;;
  promote)
    report="${REPORT:-}"; tested="${HARDWARE_TESTED:-0}"
    if (( $# > 0 )) && [[ "$1" != --tested ]]; then report="$1"; shift; fi
    if (( $# > 0 )) && [[ "$1" == --tested ]]; then tested=1; shift; fi
    (( $# == 0 )) || fatal "Unexpected arguments; use --help."
    kernel_promote "${report}" "${tested}" ;;
  help|-h|--help) usage ;;
  *) fatal "Unknown action: ${action}; use --help." ;;
esac
