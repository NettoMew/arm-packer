#!/usr/bin/env bash
# Offline regression for the optional board-local NVMe-first BootSTD profile.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
tree="$tmp/u-boot"
cleanup() {
  rm -f -- "$tree/include/configs/rock-5c-rk3588s.h" \
    "$tree/arch/arm/dts/rk3588s-rock-5c-u-boot.dtsi"
  rmdir -- "$tree/include/configs" "$tree/include" "$tree/arch/arm/dts" \
    "$tree/arch/arm" "$tree/arch" "$tree" "$tmp"
}
trap cleanup EXIT
mkdir -p "$tree/include/configs" "$tree/arch/arm/dts"
cat > "$tree/include/configs/rock-5c-rk3588s.h" <<'EOF'
/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * Copyright (c) 2024-2025 Radxa Computer (Shenzhen) Co., Ltd.
 */

#ifndef __ROCK_5C_RK3588S_H
#define __ROCK_5C_RK3588S_H

#define ROCKCHIP_DEVICE_SETTINGS \
		"stdout=serial,vidconsole\0" \
		"stderr=serial,vidconsole\0"

#include <configs/rk3588_common.h>

#endif /* __ROCK_5C_RK3588S_H */
EOF
cat > "$tree/arch/arm/dts/rk3588s-rock-5c-u-boot.dtsi" <<'EOF'
// SPDX-License-Identifier: (GPL-2.0+ OR MIT)
/*
 * Copyright (c) 2024-2025 Radxa Computer (Shenzhen) Co., Ltd.
 */

#include "rk3588s-u-boot.dtsi"

&sdhci {
	cap-mmc-highspeed;
	mmc-hs200-1_8v;
};
EOF
LIB_DIR="$root/lib" SRC_DIR=/unused BOARD=rock5c
BOARD_ASSETS="$root/boards" UBOOT_DIR="$tree"
source "$root/config/versions.conf"
ROCK5C_UNLOCK=0
unset ROCK5C_NVME_BOOT
source "$root/boards/rock5c/hooks.sh"
log() { :; }
section() { :; }
fatal() { printf '%s\n' "$*" >&2; exit 1; }
[[ "$ROCK5C_NVME_BOOT" == 0 ]]
board_inject_uboot_sources
! grep -q BOOT_TARGETS "$tree/include/configs/rock-5c-rk3588s.h"
! grep -q bootdev-order "$tree/arch/arm/dts/rk3588s-rock-5c-u-boot.dtsi"
printf 'PASS default profile unchanged\n'
if (ROCK5C_NVME_BOOT=invalid; board_inject_uboot_sources) >/dev/null 2>&1; then
  printf 'FAIL invalid profile accepted\n' >&2; exit 1
fi
printf 'PASS invalid profile rejected\n'
ROCK5C_NVME_BOOT=1
board_inject_uboot_sources
grep -Fxq '#define BOOT_TARGETS ""' "$tree/include/configs/rock-5c-rk3588s.h"
grep -Fq 'bootdev-order = "nvme", "mmc1", "mmc0", "usb";' "$tree/arch/arm/dts/rk3588s-rock-5c-u-boot.dtsi"
grep -Fq 'compatible = "u-boot,extlinux";' "$tree/arch/arm/dts/rk3588s-rock-5c-u-boot.dtsi"
git -C "$tree" apply --reverse --check "$BOARD_ASSETS/rock5c/uboot/patches/0002-rock5c-nvme-first-bootstd.patch"
printf 'PASS NVMe-first patch applied; upstream BootSTD + extlinux + rescue order\n'
