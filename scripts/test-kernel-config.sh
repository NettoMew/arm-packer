#!/usr/bin/env bash
# Offline regression checks for the pinned kernel defaults and env overrides.
# Run: bash scripts/test-kernel-config.sh
set -Eeuo pipefail
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

source config/versions.conf
repo="${DEFAULT_KERNEL_REPO}"
ref="${DEFAULT_KERNEL_REF}"
[[ "${ref}" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]

# Each board/distro combination must inherit the same kernel pin. Dry runs
# exercise the real orchestrator without fetching sources, sudo, or a compiler.
for conf in boards/*/board.conf; do
  board="${conf#boards/}"; board="${board%/board.conf}"
  for plugin in lib/distro/*.sh; do
    distro="${plugin##*/}"; distro="${distro%.sh}"
    output="$(env -u KERNEL_REPO -u KERNEL_REF BOARD="${board}" DISTRO="${distro}" \
      bash scripts/build.sh --dry-run 2>&1)"
    grep -Fq "kernel source: ${repo} @ ${ref}" <<< "${output}"
    printf 'PASS defaults: %s / %s\n' "${board}" "${distro}"
  done
done

output="$(KERNEL_REPO=https://example.invalid/linux.git KERNEL_REF=test-kernel \
  BOARD=e20c DISTRO=alpine bash scripts/build.sh --dry-run 2>&1)"
grep -Fq 'kernel source: https://example.invalid/linux.git @ test-kernel' <<< "${output}"
printf 'PASS custom kernel repository and ref\n'

output="$(env -u KERNEL_REPO KERNEL_REF=v99.0.1 BOARD=e20c DISTRO=alpine \
  bash scripts/build.sh --dry-run 2>&1)"
grep -Fq "kernel source: ${repo} @ v99.0.1" <<< "${output}"
printf 'PASS ref-only override\n'

# Output names must reflect the resolved source, not a hard-coded default.
source lib/log.sh
source lib/sources.sh
IMAGE_NAME=""
IMAGE_NAME_PREFIX=radxa-e20c-alpine
OUTPUT_DIR=/unused
RESOLVED_KERNEL_VERSION="${ref#v}"
finalize_image_name
[[ "${IMAGE_PATH}" == "/unused/radxa-e20c-alpine-${ref#v}.img" ]]
IMAGE_NAME=""
RESOLVED_KERNEL_VERSION=99.0.1
finalize_image_name
[[ "${IMAGE_PATH}" == /unused/radxa-e20c-alpine-99.0.1.img ]]
IMAGE_NAME=custom.img
finalize_image_name
[[ "${IMAGE_PATH}" == /unused/custom.img ]]
printf 'PASS resolved and custom image names\n'

# Central boot defaults and explicit overrides must both reach the dry run.
output="$(env -u UBOOT_REPO -u UBOOT_REF -u RKBIN_REPO -u RKBIN_REF \
  BOARD=e20c DISTRO=alpine bash scripts/build.sh --dry-run 2>&1)"
grep -Fq "u-boot source: ${DEFAULT_UBOOT_REPO} @ ${DEFAULT_UBOOT_REF}" <<< "${output}"
[[ "${DEFAULT_RKBIN_REF}" =~ ^[0-9a-f]{40}$ ]]
grep -Fq "rkbin source: ${DEFAULT_RKBIN_REPO} @ ${DEFAULT_RKBIN_REF}" <<< "${output}"
output="$(UBOOT_REPO=https://example.invalid/u-boot.git UBOOT_REF=test-uboot \
  RKBIN_REPO=https://example.invalid/rkbin.git RKBIN_REF=test-rkbin \
  BOARD=e20c DISTRO=alpine bash scripts/build.sh --dry-run 2>&1)"
grep -Fq 'u-boot source: https://example.invalid/u-boot.git @ test-uboot' <<< "${output}"
grep -Fq 'rkbin source: https://example.invalid/rkbin.git @ test-rkbin' <<< "${output}"
printf 'PASS boot defaults and overrides\n'

for board in m28k rock5c; do
  (
    LIB_DIR="$(pwd)/lib" SRC_DIR=/unused BOARD="${board}"
    source "boards/${board}/hooks.sh"
    calls=""
    board_inject_uboot_sources() { calls+=U; }
    board_inject_kernel_sources() { calls+=K; }
    board_prepare_modules() { calls+=M; }
    board_inject_sources
    case "${board}" in
      m28k) [[ "${calls}" == UKM ]] ;;
      rock5c) [[ "${calls}" == UM ]] ;;
    esac
  )
  printf 'PASS full-image hook order: %s\n' "${board}"
done
