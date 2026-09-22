#!/usr/bin/env bash
# Offline contract/preflight tests, not an upstream compilation/runtime test.
set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"
source lib/log.sh
source lib/swupdate.sh
mkdir -p work
root="$(mktemp -d "${PROJECT_DIR}/work/test-swupdate-config.XXXXXX")"
trap 'printf "Fixtures: %s\n" "${root}"' EXIT
export ENABLE_SWUPDATE=1 BOARD=rock5c DISTRO=alpine SWUPDATE_PACKAGE_DIR="${root}"
export SWUPDATE_PUBLIC_KEY="${root}/public.pem"
distro_install_swupdate() { :; }
reject() {
  if ( "$@" ) > "${root}/rejected.log" 2>&1; then
    printf 'FAIL: accepted invalid configuration\n' >&2; exit 1
  fi
}
( ENABLE_SWUPDATE=0; swupdate_preflight )
reject swupdate_preflight  # missing key
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${root}/private.pem" 2>/dev/null
openssl pkey -in "${root}/private.pem" -pubout -out "${root}/public.pem"
swupdate_preflight
reject bash -c 'source lib/log.sh; source lib/swupdate.sh; swupdate_preflight' # missing distro hook
reject bash -c 'source lib/log.sh; source lib/swupdate.sh; distro_install_swupdate() { :; }; ENABLE_SWUPDATE=2; swupdate_preflight'
(
  SWUPDATE_PUBLIC_KEY="${root}/private.pem"
  reject swupdate_preflight
)
(
  SWUPDATE_PACKAGE_DIR="${root}/missing"
  reject swupdate_preflight
)
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${root}/ec.pem" 2>/dev/null
openssl pkey -in "${root}/ec.pem" -pubout -out "${root}/ec-public.pem"
(
  SWUPDATE_PUBLIC_KEY="${root}/ec-public.pem"
  reject swupdate_preflight
)
(
  unset APK_TOOLS_STATIC_REPO
  FULL_FIRMWARE=0 APK_TOOLS_STATIC_ARCH=aarch64
  source lib/distro/alpine.sh
  [[ "${APK_TOOLS_STATIC_REPO}" == */aarch64 ]]
)
(
  APK_TOOLS_STATIC_REPO=https://example.invalid/apk APK_TOOLS_STATIC_ARCH=aarch64 FULL_FIRMWARE=0
  source lib/distro/alpine.sh
  [[ "${APK_TOOLS_STATIC_REPO}" == https://example.invalid/apk ]]
)
printf 'PASS updater opt-in / required packages / RSA public-only key / distro contract / native ARM builder APK architecture\n'
