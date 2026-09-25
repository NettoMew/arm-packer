#!/usr/bin/env bash
# lib/qebspil.sh — qebspil (stephan-gh/qebspil), a UEFI boot driver that starts
# Qualcomm remoteprocs (ADSP, CDSP) right before ExitBootServices(). At EL2 Linux
# cannot start them through the PAS interface; it attaches to what qebspil
# started instead. Shared by the Qualcomm UEFI boards that boot an EL2 entry;
# each board's hooks.sh sets QEBSPIL_PATCH_DIR and QEBSPIL_FIRMWARE and wires its
# board_* hooks to these helpers.
#
# systemd-boot loads every driver in \EFI\systemd\drivers\ before its menu.
# qebspil reads the DTB the chosen entry installs and starts only remoteprocs
# marked qcom,broken-reset, so an entry whose DTB lacks the property (the EL1
# one) boots exactly as it would without the driver. The firmware comes from
# \firmware\ on the ESP, at the DTB's firmware-name paths.

QEBSPIL_REPO="${QEBSPIL_REPO:-${DEFAULT_QEBSPIL_REPO}}"
QEBSPIL_COMMIT="${QEBSPIL_COMMIT:-${DEFAULT_QEBSPIL_COMMIT}}"
QEBSPIL_DIR="${QEBSPIL_DIR:-${SRC_DIR}/qebspil}"
QEBSPIL_EFI="${QEBSPIL_DIR}/out/qebspilaa64.efi"

# Clone/refresh the pinned source and its pinned submodules (gnu-efi, dtc), reset
# everything to a clean tree, then apply the board's patches. Idempotent.
qebspil_prepare_source() {
  section "Preparing qebspil source"
  if [[ -d "${QEBSPIL_DIR}/.git" ]]; then
    if [[ "${SKIP_FETCH}" == "1" ]]; then
      log "SKIP_FETCH=1: reusing existing qebspil clone."
    else
      run git -C "${QEBSPIL_DIR}" fetch --depth 1 origin "${QEBSPIL_COMMIT}"
    fi
  else
    run git clone --filter=blob:none "${QEBSPIL_REPO}" "${QEBSPIL_DIR}"
  fi
  run git -C "${QEBSPIL_DIR}" checkout -q -f "${QEBSPIL_COMMIT}"
  run git -C "${QEBSPIL_DIR}" submodule update -q --init --recursive --depth 1
  run git -C "${QEBSPIL_DIR}" clean -fdxq
  run git -C "${QEBSPIL_DIR}" submodule foreach -q --recursive git clean -fdxq
  local p count=0
  for p in "${QEBSPIL_PATCH_DIR}"/*.patch; do
    [[ -f "${p}" ]] || continue
    git -C "${QEBSPIL_DIR}" apply "${p}" || fatal "qebspil patch failed to apply: $(basename "${p}")"
    count=$((count + 1))
  done
  log "qebspil HEAD: $(git -C "${QEBSPIL_DIR}" rev-parse --short HEAD) (+${count} patch(es))"
}

qebspil_build() {
  section "Building qebspil"
  [[ -d "${QEBSPIL_DIR}/.git" ]] || fatal "qebspil source missing at ${QEBSPIL_DIR}; run without SKIP_FETCH first."
  run make -C "${QEBSPIL_DIR}" -j"${JOBS}" CROSS_COMPILE=aarch64-linux-gnu-
  [[ -f "${QEBSPIL_EFI}" ]] || fatal "qebspil build produced no ${QEBSPIL_EFI}"
  log "qebspil: ${QEBSPIL_EFI}"
}

# The driver into \EFI\systemd\drivers\, and the firmware it starts into
# \firmware\ from the rootfs copy firmware.lock already verified.
qebspil_install() {
  section "Installing qebspil and its DSP firmware on the ESP"
  local esp="${MOUNTPOINT_ROOT}${ESP_MOUNT:?no ESP in the partition layout}"
  [[ -f "${QEBSPIL_EFI}" ]] || fatal "qebspil was not built (${QEBSPIL_EFI})"
  run_sudo install -D -m 0644 "${QEBSPIL_EFI}" "${esp}/EFI/systemd/drivers/qebspilaa64.efi"
  local -a fw
  IFS=' ' read -r -a fw <<< "${QEBSPIL_FIRMWARE}"   # global IFS has no space
  local f
  for f in "${fw[@]}"; do
    [[ -f "${MOUNTPOINT_ROOT}/lib/firmware/${f}" ]] || fatal "qebspil firmware missing from the rootfs: ${f}"
    run_sudo install -D -m 0644 "${MOUNTPOINT_ROOT}/lib/firmware/${f}" "${esp}/firmware/${f}"
  done
  log "qebspil driver and ${#fw[@]} firmware file(s) on the ESP."
}
