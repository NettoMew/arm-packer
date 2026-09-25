#!/usr/bin/env bash
# lib/workspace.sh — cleanup trap fn, sudo setup, workspace prep.

cleanup() {
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    warn "Build failed with exit code ${rc}. Running cleanup."
  fi

  if [[ "${KEEP_MOUNTS_ON_ERROR}" == "1" && ${rc} -ne 0 ]]; then
    warn "KEEP_MOUNTS_ON_ERROR=1 set; leaving mounts/loop device for inspection."
    exit "${rc}"
  fi

  set +e
  if [[ -n "${MOUNTPOINT_ROOT}" && -d "${MOUNTPOINT_ROOT}" ]]; then
    if mountpoint -q "${MOUNTPOINT_ROOT}"; then
      sync
      # Recursive + lazy: a distro may have bind-mounted /proc,/sys,/dev under the
      # rootfs (e.g. Arch's build-time pacman-key chroot); plain umount would EBUSY.
      run_sudo umount -lR "${MOUNTPOINT_ROOT}" || run_sudo umount "${MOUNTPOINT_ROOT}"
    fi
    fs_release    # e.g. export the ZFS pool, which would otherwise hold the loop device
  fi
  if [[ -n "${LOOPDEV}" ]]; then
    run_sudo losetup -d "${LOOPDEV}"
  fi
  exit "${rc}"
}

setup_sudo() {
  if [[ ${EUID} -eq 0 ]]; then
    SUDO=""
  else
    have sudo || fatal "sudo is required for dependency installation, loop devices, partitioning, and rootfs extraction."
    SUDO="sudo"
  fi
}

require_root_capability() {
  setup_sudo
  if [[ -n "${SUDO}" ]]; then
    run_sudo -v
  fi
}

prepare_workspace() {
  section "Preparing workspace"
  if [[ "${CLEAN_WORKSPACE}" == "1" ]]; then
    warn "CLEAN_WORKSPACE=1: removing ${WORKSPACE}"
    rm -rf "${WORKSPACE}"
  fi
  mkdir -p "${DOWNLOAD_DIR}" "${SRC_DIR}" "${BUILD_DIR}" "${OUTPUT_DIR}"
  [[ -d "${WORKSPACE}" ]] || fatal "Workspace was not created: ${WORKSPACE}"
  log "Workspace ready: ${WORKSPACE}"
}
