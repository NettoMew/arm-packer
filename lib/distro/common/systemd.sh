#!/usr/bin/env bash
# lib/distro/common/systemd.sh — offline systemd primitives shared by the
# systemd-based distro plugins (archlinux, debian). Each one edits the mounted
# rootfs the way `systemctl --root` would, so the target's systemd never has to
# run at build time. Sourced by the plugins themselves, not by the engine.

SYSTEMD_UNIT_DIR=/usr/lib/systemd/system

# systemd_enable_unit UNIT [TARGET] — link UNIT into TARGET's .wants directory
# (default multi-user.target). A template instance resolves to its template file
# (serial-getty@ttyS2.service → serial-getty@.service). Returns 1 when the unit
# is not installed, so callers decide whether to queue, warn or fail.
systemd_enable_unit() {
  local unit="$1" target="${2:-multi-user.target}"
  local src="${SYSTEMD_UNIT_DIR}/${unit/@*./@.}"
  [[ -e "${MOUNTPOINT_ROOT}${src}" ]] || return 1
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/systemd/system/${target}.wants"
  run_sudo ln -sf "${src}" "${MOUNTPOINT_ROOT}/etc/systemd/system/${target}.wants/${unit}"
}

# systemd_mask_units UNIT... — mask each unit (a /dev/null link in /etc wins over
# any enablement, now or after a package upgrade).
systemd_mask_units() {
  local unit
  for unit in "$@"; do
    run_sudo ln -sf /dev/null "${MOUNTPOINT_ROOT}/etc/systemd/system/${unit}"
  done
}

# Serial login on the board's console. agetty takes the baud rate from the
# kernel console= argument, so the instance name is all it needs.
systemd_enable_serial_getty() {
  systemd_enable_unit "serial-getty@${SERIAL_CONSOLE}.service" getty.target \
    || fatal "serial-getty@.service is not installed in the rootfs."
}

# Early first-boot rootfs grow (sfdisk + partx, then resize2fs or zpool online
# -e; no network): the disk is full-size within seconds of the first boot.
systemd_install_rootfs_grow() {
  run_sudo install -D -m 0755 "${RESOURCES_DIR}/systemd/grow-rootfs" \
    "${MOUNTPOINT_ROOT}/usr/local/sbin/grow-rootfs"
  run_sudo install -D -m 0644 "${RESOURCES_DIR}/systemd/firstboot-grow.service" \
    "${MOUNTPOINT_ROOT}${SYSTEMD_UNIT_DIR}/firstboot-grow.service"
  systemd_enable_unit firstboot-grow.service sysinit.target
  log "First-boot rootfs auto-expand installed (firstboot-grow.service, early, no network)."
}

# Adapt OpenRC /etc/local.d/*.start boot scripts (overlaid by a board's files/,
# e.g. the M28K LED triggers) to systemd: one enabled oneshot unit each, so the
# same board overlay works on every init system.
systemd_adapt_local_d() {
  local d="${MOUNTPOINT_ROOT}/etc/local.d" f base name
  [[ -d "${d}" ]] || return 0
  shopt -s nullglob
  for f in "${d}"/*.start; do
    base="$(basename "${f}")"
    name="localcompat-${base%.start}"
    run_sudo tee "${MOUNTPOINT_ROOT}${SYSTEMD_UNIT_DIR}/${name}.service" >/dev/null <<EOF
[Unit]
Description=local.d compat: ${base}
# No "After=multi-user.target": this unit is WantedBy that target, and ordering
# a unit after the target that pulls it in is a systemd antipattern that can wedge
# the boot job. local.d scripts are best-effort late boot tasks; default ordering
# (alongside the target's wants) is correct.

[Service]
Type=oneshot
ExecStart=/etc/local.d/${base}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemd_enable_unit "${name}.service"
    log "local.d → systemd oneshot: ${name}.service (${base})"
  done
  shopt -u nullglob
}
