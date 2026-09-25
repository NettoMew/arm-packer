#!/usr/bin/env bash
# lib/kernel.sh — mainline Linux build via composable kconfig fragments.
#
# Replaces the old ~150 inline `ensure_kernel_config_option` calls. The kernel
# .config is built as: defconfig → ONE merge_config.sh over an ordered fragment
# list → olddefconfig. Order is load-bearing (later fragments win): the distro
# dump goes first, then essentials/vendor/SoC/board/leds, then docker/modern, so
# the boot-critical built-ins are re-forced after the broad distro merge. See
# kconfig/README.md. No `-r` (strict) — distro vs feature fragments intentionally
# redefine some symbols (e.g. BRIDGE=y → =m).

# True when the kernel tree can build KERNEL_DTB: from its own .dts, or, for a
# DTB composed of a base and overlays (e.g. an EL2 variant), from the
# "<name>-dtbs := ..." rule in its directory's Makefile.
kernel_dtb_has_source() {
  local dir name
  dir="${KERNEL_SRC_DIR}/arch/arm64/boot/dts/$(dirname "${KERNEL_DTB}")"
  name="$(basename "${KERNEL_DTB}" .dtb)"
  [[ -f "${dir}/${name}.dts" ]] || grep -Eq "^${name}-dtbs[[:space:]]*:=" "${dir}/Makefile" 2>/dev/null
}

# Assemble KERNEL_FRAGMENT_LIST (absolute paths, in merge order).
kernel_fragment_list() {
  local -a list=()
  if [[ "${DISTRO_KERNEL}" == "1" && -f "${DISTRO_CONFIG_FRAGMENT}" ]]; then
    list+=("${DISTRO_CONFIG_FRAGMENT}")
  fi
  list+=("${KCONFIG_DIR}/essentials.fragment")
  local f
  # Vendor + SoC fragments (rockchip [+ rk3588] | allwinner-h618).
  while IFS= read -r f; do
    [[ -n "${f}" ]] && list+=("${KCONFIG_DIR}/${f}.fragment")
  done < <(vendor_default_fragments)
  # Distro fragments (e.g. systemd requirements for Arch; none for Alpine).
  while IFS= read -r f; do
    [[ -n "${f}" ]] && list+=("${KCONFIG_DIR}/${f}.fragment")
  done < <(distro_default_fragments)
  # Board fragments: prefer the co-located boards/<board>/<name>.fragment.
  local bfrags; IFS=' ' read -r -a bfrags <<< "${BOARD_KERNEL_FRAGMENTS}"  # global IFS has no space
  for f in "${bfrags[@]}"; do
    if [[ -f "${BOARD_ASSETS}/${BOARD}/${f}.fragment" ]]; then
      list+=("${BOARD_ASSETS}/${BOARD}/${f}.fragment")
    else
      list+=("${KCONFIG_DIR}/${f}.fragment")
    fi
  done
  list+=("${KCONFIG_DIR}/leds-input.fragment")
  [[ "${DOCKER_KERNEL}" == "1" ]] && list+=("${KCONFIG_DIR}/docker.fragment")
  [[ "${MODERN_KERNEL}" == "1" ]] && list+=("${KCONFIG_DIR}/modern.fragment")
  KERNEL_FRAGMENT_LIST=("${list[@]}")
}

build_kernel() {
  section "Building mainline Linux kernel"
  # Incremental by default: reuse the build dir so `make` only recompiles what
  # changed. The .config is fully regenerated below (defconfig → fragments →
  # olddefconfig), a pure function of the inputs, so reuse never carries stale
  # options across boards. CLEAN_KERNEL=1 forces a from-scratch build.
  if [[ "${CLEAN_KERNEL}" == "1" ]]; then
    warn "CLEAN_KERNEL=1: wiping ${KERNEL_BUILD_DIR} for a from-scratch build."
    rm -rf "${KERNEL_BUILD_DIR}"
  elif [[ -f "${KERNEL_BUILD_DIR}/arch/arm64/boot/Image" ]]; then
    log "Reusing kernel build dir (incremental; CLEAN_KERNEL=1 to rebuild from scratch)."
  fi
  mkdir -p "${KERNEL_BUILD_DIR}"

  # We always build out-of-tree with O=. If a stray in-tree configuration is
  # present (e.g. from a manual in-tree make), the O= build aborts with
  # "source tree is not clean"; mrproper removes generated files only and keeps
  # the injected board .dts sources.
  if [[ -e "${KERNEL_SRC_DIR}/.config" || -d "${KERNEL_SRC_DIR}/include/config" ]]; then
    warn "In-tree kernel build artifacts found; running mrproper to clean source tree."
    run make -C "${KERNEL_SRC_DIR}" ARCH=arm64 mrproper
  fi

  run make -C "${KERNEL_SRC_DIR}" O="${KERNEL_BUILD_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- "${KERNEL_DEFCONFIG}"

  # Merge the ordered fragment list on top of defconfig in a single pass. -m =
  # merge-only (no conf); the distro fragment is first so the later board/docker/
  # modern fragments re-force boot essentials. Unknown/unsatisfiable symbols are
  # warned about here and dropped by olddefconfig below (matches the old `|| true`).
  kernel_fragment_list
  local frags="${#KERNEL_FRAGMENT_LIST[@]}"
  section "Merging ${frags} kconfig fragments on top of ${KERNEL_DEFCONFIG}"
  local f
  for f in "${KERNEL_FRAGMENT_LIST[@]}"; do
    [[ -f "${f}" ]] || fatal "Kernel fragment missing: ${f}"
    log "fragment: ${f#"${PROJECT_DIR}/"}"
  done
  run "${KERNEL_SRC_DIR}/scripts/kconfig/merge_config.sh" -m -O "${KERNEL_BUILD_DIR}" \
    "${KERNEL_BUILD_DIR}/.config" "${KERNEL_FRAGMENT_LIST[@]}"

  run make -C "${KERNEL_SRC_DIR}" O="${KERNEL_BUILD_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

  # Verification escape hatch: stop right after the .config is resolved so the new
  # engine's .config can be diffed against the old build.sh's (no compile needed).
  if [[ "${STOP_AFTER_KCONFIG:-0}" == "1" ]]; then
    log "STOP_AFTER_KCONFIG=1: kernel .config resolved at ${KERNEL_BUILD_DIR}/.config; stopping before compile."
    return 0
  fi

  run make -C "${KERNEL_SRC_DIR}" O="${KERNEL_BUILD_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"${JOBS}" Image dtbs modules

  [[ -f "${KERNEL_BUILD_DIR}/arch/arm64/boot/Image" ]] || fatal "Kernel Image not generated."
  [[ -f "${KERNEL_BUILD_DIR}/arch/arm64/boot/dts/${KERNEL_DTB}" ]] || fatal "Kernel DTB not generated: ${KERNEL_DTB}"
}

install_kernel_modules() {
  section "Installing kernel modules into rootfs"
  # INSTALL_MOD_STRIP=1: the distro-grade config builds thousands of modules and
  # DEBUG_INFO_BTF leaves heavy debug info (~600 MB unstripped); strip on install
  # to keep the rootfs small. vmlinux BTF stays in the Image (dae/CO-RE works).
  run_sudo make -C "${KERNEL_SRC_DIR}" O="${KERNEL_BUILD_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"${JOBS}" \
    INSTALL_MOD_PATH="${MOUNTPOINT_ROOT}" INSTALL_MOD_STRIP=1 modules_install
}
