#!/usr/bin/env bash
# boards/m28k/hooks.sh — Widora MangoPi M28K (RK3528) board hooks.
#
# Injects the board's U-Boot/Linux DTS + defconfig + RK3528 USB backports if needed,
# wires the AIC8800 (SDIO) Wi-Fi/BT driver via lib/aic8800.sh, and installs the
# optional OLED ECG dashboard.

# AIC8800 over SDIO: WiFi+BT together in aic8800_fdrv with the aic8800_bsp loader.
AIC8800_BUS="sdio"
AIC8800_DRV_SUBDIR="src/SDIO/driver_fw/driver/aic8800"
AIC8800_FW_SUBDIR="src/SDIO/driver_fw/fw"
AIC8800_FW_DEST="/lib/firmware/aic8800/sdio"
AIC8800_PATCH="aic8800/0001-aic8800-sdio-mainline-7.1-port.patch"
# shellcheck source=/dev/null
source "${LIB_DIR}/aic8800.sh"

board_inject_uboot_sources() {
  section "Injecting Widora MangoPi M28K U-Boot sources"
  local assets="${BOARD_ASSETS}/m28k"
  [[ -d "${assets}" ]] || fatal "Board assets missing: ${assets}"

  # --- U-Boot: OF_UPSTREAM board DTS + -u-boot.dtsi overlay + defconfig -------
  local ub_dts_dir="${UBOOT_DIR}/dts/upstream/src/arm64/rockchip"
  [[ -d "${ub_dts_dir}" ]] || fatal "U-Boot OF_UPSTREAM dts dir missing: ${ub_dts_dir}"
  run cp -f "${assets}/uboot/dts/rk3528-mangopi-m28.dtsi"  "${ub_dts_dir}/"
  run cp -f "${assets}/uboot/dts/rk3528-mangopi-m28k.dts"  "${ub_dts_dir}/"
  run cp -f "${assets}/uboot/dtsi/rk3528-mangopi-m28k-u-boot.dtsi" "${UBOOT_DIR}/arch/arm/dts/"
  run cp -f "${assets}/uboot/configs/mangopi-m28k-rk3528_defconfig" "${UBOOT_DIR}/configs/"
}

board_inject_kernel_sources() {
  local assets="${BOARD_ASSETS}/m28k"
  # --- Linux: reset tree, apply needed board patches, drop in board DTS ------
  local lx_dts_dir="${KERNEL_SRC_DIR}/arch/arm64/boot/dts/rockchip"
  section "Applying M28K kernel patches"
  run git -C "${KERNEL_SRC_DIR}" checkout -- .
  # Linux 7.2.7 already provides the RK3528 PHY driver and USB DT nodes. The
  # older USB series (including its prerequisite PHY refactors) conflicts with
  # that implementation. Detect the capability, not KERNEL_REF, so custom refs
  # and older kernels still work. M28K uses host ports, not Type-C VBUS detection.
  local native_usb=0
  if grep -q '"rockchip,rk3528-usb2phy"' "${KERNEL_SRC_DIR}/drivers/phy/rockchip/phy-rockchip-inno-usb2.c" &&
     grep -q '"rockchip,rk3528-usb2phy"' "${lx_dts_dir}/rk3528.dtsi"; then
    native_usb=1
    log "Using native RK3528 USB support; skipping the USB backport series."
  fi
  local p
  for p in "${assets}/linux/patches/"*.patch; do
    case "${p##*/}" in
      121-*.patch|131-02-*.patch)
        [[ "${native_usb}" == "1" ]] && continue ;;
    esac
    # Non-USB fixes (notably SDIO pwrseq) are still required. Never silently
    # ignore an unexpected patch failure.
    log "git apply $(basename "${p}")"
    git -C "${KERNEL_SRC_DIR}" apply "${p}" || fatal "Kernel patch failed to apply: $(basename "${p}")"
  done
  run cp -f "${assets}/linux/dts/rk3528-mangopi-m28.dtsi" "${lx_dts_dir}/"
  run cp -f "${assets}/linux/dts/rk3528-mangopi-m28k.dts" "${lx_dts_dir}/"
  if ! grep -q 'rk3528-mangopi-m28k.dtb' "${lx_dts_dir}/Makefile"; then
    log "Registering rk3528-mangopi-m28k.dtb in kernel Makefile"
    printf 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3528-mangopi-m28k.dtb\n' \
      >> "${lx_dts_dir}/Makefile"
  fi

}

board_prepare_modules() { aic8800_prepare_source; }

# Full-image path retains the same ordered operations. Kernel validation invokes
# only the kernel/module hooks, never the bootloader hook.
board_inject_sources() {
  board_inject_uboot_sources
  board_inject_kernel_sources
  board_prepare_modules
}

board_build_modules()     { aic8800_build; }
board_install_modules()   { aic8800_install; }
board_install_userspace() { wifi_install_userspace; }
board_configure_runtime() { wifi_configure_runtime; }

board_install_extras() {
  # M28K "screen" flavour only: the SSD1306 OLED ECG dashboard. oled-dash.c is
  # cross-compiled statically (a static glibc binary runs fine on the musl
  # rootfs) and auto-started at boot via the OpenRC 'local' service.
  [[ "${M28K_OLED}" == "1" ]] || { log "OLED dashboard not included (M28K_OLED=${M28K_OLED:-0})."; return 0; }
  section "Installing OLED ECG dashboard (cross-compiling oled-dash)"
  local src="${BOARD_ASSETS}/m28k/oled/oled-dash.c"
  local start="${BOARD_ASSETS}/m28k/oled/oled-dash.start"
  [[ -f "${src}" && -f "${start}" ]] || fatal "OLED assets missing under ${BOARD_ASSETS}/m28k/oled/"
  run aarch64-linux-gnu-gcc -O2 -static -o "${BUILD_DIR}/oled-dash" "${src}" -lm
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/usr/local/bin" "${MOUNTPOINT_ROOT}/usr/local/src"
  run_sudo cp "${BUILD_DIR}/oled-dash" "${MOUNTPOINT_ROOT}/usr/local/bin/oled-dash"
  run_sudo cp "${src}" "${MOUNTPOINT_ROOT}/usr/local/src/oled-dash.c"
  run_sudo chmod +x "${MOUNTPOINT_ROOT}/usr/local/bin/oled-dash"
  # Boot autostart — init-system specific (the binary is the same on both):
  if [[ "${DISTRO}" == "alpine" ]]; then
    # OpenRC 'local' service runs /etc/local.d/*.start at boot.
    run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/local.d"
    run_sudo cp "${start}" "${MOUNTPOINT_ROOT}/etc/local.d/oled-dash.start"
    run_sudo chmod +x "${MOUNTPOINT_ROOT}/etc/local.d/oled-dash.start"
  elif [[ "${DISTRO}" == "eweos" ]]; then
    # dinit: a process service that waits for the ssd130x framebuffer then execs
    # oled-dash. NB dinit does $-variable substitution on the `command` setting, so
    # an inline `sh -c '…$i…$((…))…'` makes it choke ("invalid variable name after
    # '$'") and FAILS THE BOOT. Keep the shell logic in a separate script the
    # /bin/sh interprets at runtime; the dinit command contains no '$'.
    run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/dinit.d/boot.d" "${MOUNTPOINT_ROOT}/usr/local/bin"
    run_sudo tee "${MOUNTPOINT_ROOT}/usr/local/bin/oled-dash-run" >/dev/null <<'EOF'
#!/bin/sh
# 等 ssd130x framebuffer 就绪(i2c 探测可能略晚),再 exec oled-dash(exec 让 dinit
# 直接跟踪守护进程而非等待用的 shell）。
i=0
while [ ! -e /dev/fb0 ] && [ "$i" -lt 30 ]; do sleep 0.5; i=$((i + 1)); done
exec /usr/local/bin/oled-dash
EOF
    run_sudo chmod +x "${MOUNTPOINT_ROOT}/usr/local/bin/oled-dash-run"
    run_sudo tee "${MOUNTPOINT_ROOT}/etc/dinit.d/oled-dash" >/dev/null <<'EOF'
type = process
command = /usr/local/bin/oled-dash-run
restart = true
restart-delay = 2.0
depends-on: rc.target
EOF
    run_sudo ln -sf /etc/dinit.d/oled-dash "${MOUNTPOINT_ROOT}/etc/dinit.d/boot.d/oled-dash"
  else
    # systemd: run the binary directly (Type=simple), waiting for the ssd130x
    # framebuffer (its i2c probe can be slightly late) before starting.
    run_sudo tee "${MOUNTPOINT_ROOT}/usr/lib/systemd/system/oled-dash.service" >/dev/null <<'EOF'
[Unit]
Description=M28K OLED ECG dashboard (SSD1306)
# NB: do NOT add "After=multi-user.target" — this unit is WantedBy that same
# target, and ordering a unit after the target that pulls it in is a documented
# systemd antipattern: the start job never runs at boot (it waits for a target
# that is itself waiting on this job's slice to settle). The framebuffer race is
# already handled by the ExecStartPre /dev/fb0 poll below, so no ordering needed.

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'i=0; while [ ! -e /dev/fb0 ] && [ "$i" -lt 30 ]; do sleep 0.5; i=$((i+1)); done; [ -e /dev/fb0 ]'
ExecStart=/usr/local/bin/oled-dash
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/systemd/system/multi-user.target.wants"
    run_sudo ln -sf /usr/lib/systemd/system/oled-dash.service \
      "${MOUNTPOINT_ROOT}/etc/systemd/system/multi-user.target.wants/oled-dash.service"
  fi
  log "OLED ECG dashboard installed (oled-dash + ${DISTRO} boot autostart)."
}
