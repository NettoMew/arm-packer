#!/usr/bin/env bash
# lib/sources.sh — git fetch/clone, shared-tree reset, source fetch + asserts.
#
# Vendor-specific trees (rkbin vs arm-trusted-firmware) are fetched/asserted via
# the vendor_* plugin; per-board DTS/patch injection via the board_inject_sources
# hook. The shared U-Boot/kernel trees are reset to pristine here, unconditionally,
# before any per-board injection so a board's patch never carries to another board.

git_clone_or_update() {
  local repo="$1" ref="$2" dir="$3"
  if [[ -d "${dir}/.git" ]]; then
    section "Updating $(basename "${dir}")"
    run git -C "${dir}" remote set-url origin "${repo}"
    run git -C "${dir}" fetch --tags --prune origin
  else
    section "Cloning $(basename "${dir}")"
    run git clone "${repo}" "${dir}"
  fi
  run git -C "${dir}" checkout "${ref}"
  if [[ "${ref}" == "master" || "${ref}" == "main" ]]; then
    run git -C "${dir}" pull --ff-only origin "${ref}"
  fi
  log "$(basename "${dir}") HEAD: $(git -C "${dir}" rev-parse --short HEAD)"
}

git_clone_or_refresh_shallow() {
  local repo="$1" ref="$2" dir="$3"
  section "Fetching shallow $(basename "${dir}")"
  if [[ -d "${dir}/.git" ]]; then
    run git -C "${dir}" remote set-url origin "${repo}"
    run git -C "${dir}" fetch --depth 1 origin "${ref}"
    run git -C "${dir}" checkout -B "${ref}" FETCH_HEAD
  else
    rm -rf "${dir}"
    run git clone --depth 1 --branch "${ref}" "${repo}" "${dir}"
  fi
  log "$(basename "${dir}") HEAD: $(git -C "${dir}" rev-parse --short HEAD)"
}

# Finalize the output image name now that the kernel version is known:
# <prefix>-<distro>-<kernelversion>.img.
# A user-pinned IMAGE_NAME is respected as-is.
finalize_image_name() {
  if [[ -z "${IMAGE_NAME}" ]]; then
    [[ -n "${RESOLVED_KERNEL_VERSION}" ]] || fatal "Kernel version not resolved; cannot compose image name."
    IMAGE_NAME="${IMAGE_NAME_PREFIX}-${RESOLVED_KERNEL_VERSION}.img"
  fi
  IMAGE_PATH="${OUTPUT_DIR}/${IMAGE_NAME}"
  log "Output image: ${IMAGE_NAME}"
}

resolve_kernel_identity() {
  section "Resolving mainline Linux Git identity"
  [[ -d "${KERNEL_SRC_DIR}/.git" ]] || fatal "Kernel source is not cloned yet: ${KERNEL_SRC_DIR}"
  local version commit describe
  version="$(make -s -C "${KERNEL_SRC_DIR}" kernelversion 2>/dev/null || true)"
  commit="$(git -C "${KERNEL_SRC_DIR}" rev-parse --short HEAD)"
  describe="$(git -C "${KERNEL_SRC_DIR}" describe --tags --always --dirty 2>/dev/null || true)"
  RESOLVED_KERNEL_VERSION="${version:-${describe:-${commit}}}"
  log "Linux kernelversion: ${RESOLVED_KERNEL_VERSION}"
  log "Linux Git commit: ${commit}${describe:+ (${describe})}"
}

reset_shared_trees() {
  # Reset the shared U-Boot tree to pristine first, so a per-board U-Boot patch
  # (e.g. the rock5c rk3582 unlock) never carries over to another board. Only
  # tracked files: U-Boot builds in-tree and SKIP_BUILD=1 reuses its outputs.
  if [[ -d "${UBOOT_DIR:-}/.git" ]]; then
    run git -C "${UBOOT_DIR}" checkout -- . || true
  fi
  # The kernel builds out of tree (O=), so its source tree can be made pristine
  # outright: tracked edits reverted and files a board added removed (m28k's DTS,
  # the new drivers and DTS a patch series creates), whatever board ran last.
  if [[ -d "${KERNEL_SRC_DIR}/.git" ]]; then
    run git -C "${KERNEL_SRC_DIR}" checkout -- . || true
    run git -C "${KERNEL_SRC_DIR}" clean -fdq || true
  fi
}

fetch_sources() {
  # Reset the shared U-Boot/kernel trees to pristine BEFORE any fetch/checkout: a
  # prior board leaves tracked edits behind (m28k appends its dtb to the rockchip
  # Makefile; rock5c patches U-Boot), and those edits would otherwise block this
  # board's `git checkout -B <ref> FETCH_HEAD` / `git pull --ff-only`
  # ("local changes would be overwritten"). Order-independent across boards.
  reset_shared_trees

  # The vendor fetches its boot chain (U-Boot, rkbin, ATF, systemd-boot, ...).
  if [[ "${SKIP_FETCH}" == "1" ]]; then
    section "SKIP_FETCH=1: reusing existing source trees"
    vendor_fetch_assert_skip
    [[ -d "${KERNEL_SRC_DIR}/.git" ]] || fatal "SKIP_FETCH=1 but Linux tree missing: ${KERNEL_SRC_DIR}"
  else
    vendor_fetch_extra
    git_clone_or_refresh_shallow "${KERNEL_REPO}" "${KERNEL_REF}" "${KERNEL_SRC_DIR}"
  fi

  board_hook inject_sources

  vendor_assert_sources
  [[ -f "${KERNEL_SRC_DIR}/arch/arm64/boot/dts/${KERNEL_DTS}" ]] || fatal "Kernel DTS source missing: arch/arm64/boot/dts/${KERNEL_DTS}"
  resolve_kernel_identity
  finalize_image_name
}
