#!/usr/bin/env bash
# scripts/build.sh — orchestrator for the mainline SBC firmware builder
# (board × vendor × distro: Rockchip/Allwinner/Qualcomm × Alpine/Arch/Debian/eweOS).
#
# Pipeline: parse flags → load board config → source vendor plugin + board hooks
# → derive paths → run the build pipeline. Per-board knowledge lives in
# boards/<board>/board.conf (+ optional hooks.sh); vendor boot-chain differences
# in lib/vendor/<vendor>.sh (+ the lib/boot/*.sh scheme it uses); kernel options
# in kconfig/*.fragment. The engine itself (lib/*.sh) has no board/vendor
# conditionals.
#
# Usage:
#   BOARD=opiz3 scripts/build.sh                 # build (default BOARD=e20c)
#   BOARD=m28k M28K_OLED=0 scripts/build.sh      # variant via env knob
#   BOARD=rock5c scripts/build.sh --dry-run      # resolve + print config, no build
#   BOARD=e20c scripts/build.sh --stop-after-kconfig   # build up to kernel .config
#   BOARD=e20c scripts/build.sh --kernel-check        # isolated patches/config/DTB
#   BOARD=e20c scripts/build.sh --kernel-build        # isolated kernel + modules

set -Eeuo pipefail
IFS=$'\n\t'

# ------------------------------ Flags ----------------------------------------
DRY_RUN=0
KERNEL_ACTION=""
export STOP_AFTER_KCONFIG="${STOP_AFTER_KCONFIG:-0}"
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --stop-after-kconfig) STOP_AFTER_KCONFIG=1 ;;
    --kernel-check|--kernel-build)
      [[ -z "${KERNEL_ACTION}" ]] || { printf 'Choose one kernel validation action.\n' >&2; exit 2; }
      KERNEL_ACTION="${arg#--kernel-}" ;;
    -h|--help)
      sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "${arg}" >&2; exit 2 ;;
  esac
done

# ------------------------------ Layout ---------------------------------------
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SELF_DIR}/.." && pwd)"
LIB_DIR="${PROJECT_DIR}/lib"
BOARD_ASSETS="${BOARD_ASSETS:-${PROJECT_DIR}/boards}"
WORKSPACE="${WORKSPACE:-${PROJECT_DIR}/work}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/out}"
export PROJECT_DIR LIB_DIR BOARD_ASSETS

BOARD="${BOARD:-e20c}"
# Distro axis (userspace = package manager + init system + network), orthogonal to
# board + vendor. Selects lib/distro/<DISTRO>.sh and the <distro> in the image name.
DISTRO="${DISTRO:-alpine}"
export DISTRO

# The distro-grade kernel builds thousands of modules; modfinal then links the
# multi-object ones (amdgpu/nouveau/radeon — argv in the MB range) via `ld -r`.
# execve caps argv+env at RLIMIT_STACK/4, so a small soft stack ulimit (some
# desktop/systemd sessions cap it ~8-12 MB → ~2-3 MB argv) trips "Argument list too
# long" deep in scripts/Makefile.modfinal. Lift the hard limit if we can (no-op
# without privilege / when already high), then raise the soft limit so the full
# ARG_MAX is available. Verified just below — see the fail-fast after log.sh.
# 131072 KB (128 MB) is the empirically proven-sufficient value; do NOT fall back
# to a lower soft limit — 65536 passes a lax guard but still trips modfinal.
KERNEL_STACK_KB=131072
ulimit -H -s unlimited 2>/dev/null || true
ulimit -S -s "${KERNEL_STACK_KB}" 2>/dev/null || true

# ------------------------------ Bootstrap ------------------------------------
# shellcheck source=/dev/null
source "${LIB_DIR}/log.sh"
trap 'fatal "Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

# Fail fast if the soft stack is still below the proven-good value to finish `make
# modules` — a capped HARD limit in this shell blocks the raise above, and the
# modfinal failure would otherwise only surface ~20 min into the kernel build with
# a cryptic E2BIG ("/bin/sh: Argument list too long").
_soft_stack="$(ulimit -Ss)"
if [[ "${_soft_stack}" != "unlimited" && "${_soft_stack}" -lt "${KERNEL_STACK_KB}" ]]; then
  fatal "Stack soft limit is only ${_soft_stack} KB; the kernel modules build needs ≥${KERNEL_STACK_KB} KB (big module links exceed execve's RLIMIT_STACK/4 argv cap). This shell's HARD limit ($(ulimit -Hs) KB) blocks raising it. Fix and retry, e.g.: 'ulimit -Hs unlimited' in this shell (or open a fresh login shell / set systemd DefaultLimitSTACK), then 'make ${BOARD:-<board>}' again."
fi
log "Stack soft limit: ${_soft_stack} KB (hard $(ulimit -Hs) KB) — ok for the kernel modules build."

# Declarative board config (replaces the old `case BOARD`).
BOARD_CONF="${BOARD_ASSETS}/${BOARD}/board.conf"
[[ -f "${BOARD_CONF}" ]] || fatal "Unknown BOARD=${BOARD} (have: $(cd "${BOARD_ASSETS}" && echo */ | tr -d '/'))"
# shellcheck source=/dev/null
source "${BOARD_CONF}"

# Required keys.
: "${BOARD_VENDOR:?board.conf must set BOARD_VENDOR}" \
  "${BOARD_SOC:?board.conf must set BOARD_SOC}" \
  "${BOARD_KERNEL_DTB:?board.conf must set BOARD_KERNEL_DTB}" \
  "${BOARD_IMAGE_PREFIX:?board.conf must set BOARD_IMAGE_PREFIX}" \
  "${BOARD_HOSTNAME:?board.conf must set BOARD_HOSTNAME}" \
  "${BOARD_MENU_TITLE:?board.conf must set BOARD_MENU_TITLE}" \
  "${BOARD_SERIAL_CONSOLE:?board.conf must set BOARD_SERIAL_CONSOLE}"

# Generic knobs + derived paths (uses the BOARD_* values above as defaults).
# shellcheck source=/dev/null
source "${LIB_DIR}/env.sh"

# Vendor boot-chain plugin (its boot scheme, blobs and the vendor_* contract).
VENDOR_LIB="${LIB_DIR}/vendor/${BOARD_VENDOR}.sh"
[[ -f "${VENDOR_LIB}" ]] || fatal "Unknown BOARD_VENDOR=${BOARD_VENDOR} (no ${VENDOR_LIB})"
# shellcheck source=/dev/null
source "${VENDOR_LIB}"

# Keys the vendor's boot scheme needs on top of the generic ones (e.g. a U-Boot
# defconfig); a UEFI vendor needs none.
while IFS= read -r key; do
  [[ -n "${!key:-}" ]] || fatal "board.conf must set ${key} (required by BOARD_VENDOR=${BOARD_VENDOR})"
done < <(vendor_required_keys)

# Distro plugin (userspace: package manager + init system + network).
DISTRO_LIB="${LIB_DIR}/distro/${DISTRO}.sh"
[[ -f "${DISTRO_LIB}" ]] || fatal "Unknown DISTRO=${DISTRO} (no ${DISTRO_LIB}; have: $(cd "${LIB_DIR}/distro" && echo *.sh | sed 's/\.sh//g'))"
# shellcheck source=/dev/null
source "${DISTRO_LIB}"

# Optional per-board hooks (source injection, AIC8800, OLED, …).
[[ -f "${BOARD_ASSETS}/${BOARD}/hooks.sh" ]] && { # shellcheck source=/dev/null
  source "${BOARD_ASSETS}/${BOARD}/hooks.sh"; }

# Finalize the image size from the distro default (Alpine 1G / Arch 4G), unless
# the user pinned IMAGE_SIZE explicitly.
IMAGE_SIZE="${IMAGE_SIZE:-${DISTRO_IMAGE_SIZE:-1G}}"
# Provisional path for early logging; finalize_image_name() rewrites IMAGE_NAME/
# IMAGE_PATH with the resolved kernel version after the source is fetched.
IMAGE_PATH="${OUTPUT_DIR}/${IMAGE_NAME:-${IMAGE_NAME_PREFIX}-pending.img}"

# Resolve vendor blobs (Rockchip) / no-op (Allwinner).
vendor_select_blobs

# Engine modules.
for m in deps workspace sources kernel image rootfs wifi pipeline kernel-update swupdate; do
  # shellcheck source=/dev/null
  source "${LIB_DIR}/${m}.sh"
done

# cleanup() (in workspace.sh) needs the globals from env.sh; install the EXIT trap
# now that everything is sourced.
trap cleanup EXIT

# ------------------------------ Dry run --------------------------------------
if [[ "${DRY_RUN}" == "1" ]]; then
  section "DRY RUN — resolved configuration for BOARD=${BOARD} DISTRO=${DISTRO}"
  log "vendor/soc: ${BOARD_VENDOR}/${BOARD_SOC}"
  distro_env_summary
  vendor_env_summary
  log "kernel source: ${KERNEL_REPO} @ ${KERNEL_REF}"
  if [[ -n "${KERNEL_ACTION}" ]]; then
    kernel_require_release_tag "${KERNEL_REF}"
    log "kernel validation: ${KERNEL_ACTION} (fresh isolated workspace; no bootloader/rootfs/image operations)"
    log "validation root: ${KERNEL_VALIDATION_ROOT:-${PROJECT_DIR}/work/kernel-validation}"
  fi
  log "kernel dtb: ${KERNEL_DTB}"
  log "offline SWUpdate: ${ENABLE_SWUPDATE} (packages + public key required when enabled)"
  log "image: ${OUTPUT_DIR}/${IMAGE_NAME:-${IMAGE_NAME_PREFIX}-<kernelversion>.img} (size ${IMAGE_SIZE})"
  log "console: ${SERIAL_CONSOLE},${SERIAL_BAUD}n8"
  load_partition_layout
  log "partition table: $(vendor_partition_table)"
  while IFS= read -r line; do log "  ${line}"; done < <(describe_partition_layout)
  log "wired NICs (all DHCP): ${BOARD_NICS}"
  log "full linux-firmware: ${FULL_FIRMWARE}"
  log "cmdline extra: ${BOARD_KERNEL_CMDLINE_EXTRA:-<none>}"
  kernel_fragment_list
  log "kernel fragments (${#KERNEL_FRAGMENT_LIST[@]}, merge order):"
  for f in "${KERNEL_FRAGMENT_LIST[@]}"; do log "  - ${f#"${PROJECT_DIR}/"}"; done
  log "board hooks defined:"
  local_any=0
  for h in inject_sources inject_uboot_sources inject_kernel_sources prepare_modules build_modules install_modules install_userspace configure_runtime install_extras; do
    if declare -F "board_${h}" >/dev/null; then log "  ✓ board_${h}"; local_any=1; fi
  done
  [[ "${local_any}" == "0" ]] && log "  (none — pristine board)"
  trap - EXIT
  exit 0
fi

if [[ -n "${KERNEL_ACTION}" ]]; then
  run_kernel_validation "${KERNEL_ACTION}"
else
  run_pipeline "$@"
fi
