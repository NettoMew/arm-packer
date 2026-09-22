#!/usr/bin/env bash
# Real XZ round trip and failed-publication guards; no root, mounts or devices.
set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_DIR}/lib/log.sh"
source "${PROJECT_DIR}/lib/image.sh"
command -v xz >/dev/null || fatal "Install xz to run this test."
mkdir -p "${PROJECT_DIR}/work"
work="$(mktemp -d "${PROJECT_DIR}/work/test-image-compression.XXXXXX")"
IMAGE_PATH="${work}/firmware image.img"
COMPRESS_IMAGE=1
printf 'arm-packer test image\n' > "${IMAGE_PATH}"
dd if=/dev/zero bs=1024 count=1024 >> "${IMAGE_PATH}" 2>/dev/null
expected="$(sha256sum "${IMAGE_PATH}" | cut -d ' ' -f1)"
expected_mode="$(stat -c %a "${IMAGE_PATH}")"
outer_exit_trap="$(trap -p EXIT)"
compress_image
[[ "$(trap -p EXIT)" == "${outer_exit_trap}" ]]
[[ ! -e "${IMAGE_PATH}" && -s "${IMAGE_PATH}.xz" ]]
[[ "$(stat -c %a "${IMAGE_PATH}.xz")" == "${expected_mode}" ]]
xz -t "${IMAGE_PATH}.xz"
[[ "$(xz -dc "${IMAGE_PATH}.xz" | sha256sum | cut -d ' ' -f1)" == "${expected}" ]]
printf 'PASS real XZ compression / integrity / round trip / permissions / raw removal\n'

xz -dc "${IMAGE_PATH}.xz" > "${IMAGE_PATH}"
COMPRESS_IMAGE=0 compress_image
[[ "$(sha256sum "${IMAGE_PATH}" | cut -d ' ' -f1)" == "${expected}" ]]
printf 'PASS COMPRESS_IMAGE=0 preserves raw image\n'

previous="$(sha256sum "${IMAGE_PATH}.xz" | cut -d ' ' -f1)"
for failure in compression integrity; do
  if (
    xz() {
      if [[ " $* " == *' --test '* ]]; then return 1; fi
      printf 'incomplete xz stream'
      [[ "${failure}" != compression ]]
    }
    compress_image
  ) > "${work}/${failure}.log" 2>&1; then
    fatal "Expected ${failure} failure was accepted."
  fi
  [[ "$(sha256sum "${IMAGE_PATH}" | cut -d ' ' -f1)" == "${expected}" ]]
  [[ "$(sha256sum "${IMAGE_PATH}.xz" | cut -d ' ' -f1)" == "${previous}" ]]
  [[ -z "$(find "${work}" -name '*.tmp.*' -print -quit)" ]]
  printf 'PASS %s failure preserves raw / previous package and removes partial output\n' "${failure}"
done
if (
  command() {
    [[ "$1" != -v || "$2" != xz ]] || return 1
    builtin command "$@"
  }
  compress_image
) > "${work}/missing-xz.log" 2>&1; then
  fatal "Missing xz was accepted."
fi
[[ "$(sha256sum "${IMAGE_PATH}" | cut -d ' ' -f1)" == "${expected}" ]]
[[ "$(sha256sum "${IMAGE_PATH}.xz" | cut -d ' ' -f1)" == "${previous}" ]]
printf 'PASS missing xz fails without changing raw / previous package\n'
printf 'Fixtures: %s\n' "${work}"
