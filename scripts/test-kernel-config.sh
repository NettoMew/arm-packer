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
    if output="$(env -u KERNEL_REPO -u KERNEL_REF BOARD="${board}" DISTRO="${distro}" \
      bash scripts/build.sh --dry-run 2>&1)"; then
      grep -Fq "kernel source: ${repo} @ ${ref}" <<< "${output}"
      printf 'PASS defaults: %s / %s\n' "${board}" "${distro}"
    else
      # A board whose root is ZFS refuses the distros that cannot boot it.
      grep -Fq "DISTRO=${distro} cannot boot a ZFS root" <<< "${output}"
      printf 'PASS refused: %s / %s (ZFS root)\n' "${board}" "${distro}"
    fi
  done
done

# The incus profile on every board: Debian builds an Incus host held to both
# kernel contracts; the other distros are refused (or a ZFS board refuses first).
for conf in boards/*/board.conf; do
  board="${conf#boards/}"; board="${board%/board.conf}"
  # shellcheck source=/dev/null  # each board.conf in turn
  prefix="$(. "${conf}"; printf '%s' "${BOARD_IMAGE_PREFIX}")"
  for plugin in lib/distro/*.sh; do
    distro="${plugin##*/}"; distro="${distro%.sh}"
    if output="$(BOARD="${board}" DISTRO="${distro}" PROFILE=incus bash scripts/build.sh --dry-run 2>&1)"; then
      [[ "${distro}" == debian ]]
      grep -Fq "${prefix}-debian-incus-<kernelversion>.img (size 4G)" <<< "${output}"
      grep -Fq 'kernel contracts checked against the final .config: 2' <<< "${output}"
      grep -Fq '  - kconfig/incus.contract' <<< "${output}"
      grep -Fq '  - kconfig/dae.contract' <<< "${output}"
      printf 'PASS incus: %s / %s\n' "${board}" "${distro}"
    else
      grep -Eq "DISTRO=${distro} cannot (add|boot a ZFS root)" <<< "${output}"
      printf 'PASS refused incus: %s / %s\n' "${board}" "${distro}"
    fi
  done
done
output="$(BOARD=e20c DISTRO=debian PROFILE=no-such bash scripts/build.sh --dry-run 2>&1)" && exit 1
grep -Fq 'Unknown PROFILE=no-such' <<< "${output}"
printf 'PASS unknown profile refused\n'

# Contract semantics, on synthetic files: =y built in, =m module or built in,
# "is not set" off, strings exact, anything else broken; a contract's request
# never lowers a built-in to a module.
(
  source lib/log.sh
  source lib/kernel.sh
  t="$(mktemp -d)"; trap 'rm -rf "${t}"' EXIT
  printf '%s\n' CONFIG_A=y CONFIG_B=m CONFIG_C=y '# CONFIG_D is not set' 'CONFIG_S="x,y"' > "${t}/config"
  printf '%s\n' '# a comment' '' CONFIG_A=y CONFIG_B=m CONFIG_C=m '# CONFIG_D is not set' \
    '# CONFIG_E is not set' 'CONFIG_S="x,y"' > "${t}/met"
  kernel_contract_check "${t}/config" "${t}/met"
  for broken in CONFIG_B=y CONFIG_D=m CONFIG_E=y '# CONFIG_A is not set' 'CONFIG_S="x"' CONFIG_A=Y 'CONFIG_A = y'; do
    printf '%s\n' CONFIG_A=y "${broken}" > "${t}/broken"
    [[ "$(kernel_contract_check "${t}/config" "${t}/broken")" == "${broken}" ]]
  done
  printf '# only a comment\n' > "${t}/empty"
  if kernel_contract_check "${t}/config" "${t}/empty" >/dev/null; then exit 1; fi
  printf '%s\n' CONFIG_A=m CONFIG_B=m CONFIG_X=m CONFIG_C=y > "${t}/contract"
  printf '%s\n' CONFIG_B=y '# CONFIG_X is not set' > "${t}/fragment"
  kernel_contract_request "${t}/contract" "${t}/request" "${t}/config" "${t}/fragment"
  [[ "$(cat "${t}/request")" == "$(printf '%s\n' CONFIG_X=m CONFIG_C=y)" ]]
  # The shipped contracts parse cleanly: against an empty .config every line is
  # reported exactly as written, none silently skipped.
  printf 'CONFIG_NONE=y\n' > "${t}/none"
  for c in kconfig/*.contract; do
    diff <(kernel_contract_check "${t}/none" "${c}" | grep -v ' is not set$') \
         <(grep -E '^CONFIG_' "${c}") >/dev/null
  done
)
printf 'PASS contract semantics and shipped contracts parse\n'

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
