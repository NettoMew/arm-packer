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

# The profile's capability contracts (kconfig/<name>.contract), as absolute paths.
kernel_contract_list() {
  local -a list=() names
  local n
  IFS=' ' read -r -a names <<< "$(profile_kernel_contracts)"   # global IFS has no space
  for n in "${names[@]}"; do
    list+=("${KCONFIG_DIR}/${n}.contract")
  done
  KERNEL_CONTRACT_LIST=("${list[@]}")
}

# Check CONFIG against one CONTRACT and print each line it breaks. "=y" must be
# built in, "=m" may be a module or built in, "# … is not set" must be off and a
# quoted value must match exactly; any other line that is not a comment is
# broken by definition, so a typo can never drop out of the check. Returns
# nonzero when anything is broken (or the contract states nothing).
kernel_contract_check() {
  local config="$1" contract="$2" line key want count=0 broken=0
  [[ -s "${config}" && -s "${contract}" ]] || { printf 'missing config or contract\n'; return 1; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^(CONFIG_[A-Z0-9_]+)=([ym])$ ]]; then
      key="${BASH_REMATCH[1]}"; want="${BASH_REMATCH[2]}"
      [[ "${want}" == m ]] && want='[ym]'
      grep -Eq "^${key}=${want}$" "${config}" || { printf '%s\n' "${line}"; broken=1; }
    elif [[ "${line}" =~ ^(CONFIG_[A-Z0-9_]+)=(\".*\")$ ]]; then
      grep -Fxq "${line}" "${config}" || { printf '%s\n' "${line}"; broken=1; }
    elif [[ "${line}" =~ ^#\ (CONFIG_[A-Z0-9_]+)\ is\ not\ set$ ]]; then
      key="${BASH_REMATCH[1]}"
      grep -Eq "^${key}=[ym]$" "${config}" && { printf '%s\n' "${line}"; broken=1; }
    elif [[ -z "${line//[[:space:]]/}" || "${line}" == \#* ]]; then
      continue
    else
      printf '%s\n' "${line}"; broken=1
    fi
    count=$((count + 1))
  done < "${contract}"
  ((count > 0 && broken == 0))
}

# Write OUT, the request CONTRACT makes of the merge: the contract itself, less
# each "=m" whose symbol the files merged BEFORE it already build in, since "=m"
# means at least a module and must never lower a built-in to one.
kernel_contract_request() {
  local contract="$1" out="$2" line key; shift 2
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^(CONFIG_[A-Z0-9_]+)=m$ ]]; then
      key="${BASH_REMATCH[1]}"
      [[ "$(grep -h -E "^${key}=|^# ${key} is not set" "$@" | tail -n1)" == "${key}=y" ]] && continue
    fi
    printf '%s\n' "${line}"
  done < "${contract}" > "${out}"
}

# Every contract against the resolved .config, before anything is compiled.
kernel_validate_contracts() {
  local cfg="${KERNEL_BUILD_DIR}/.config" c line key have failed=0 missing
  for c in "${KERNEL_CONTRACT_LIST[@]}"; do
    if missing="$(kernel_contract_check "${cfg}" "${c}")"; then
      log "contract met: ${c#"${PROJECT_DIR}/"}"
      continue
    fi
    while IFS= read -r line; do
      key="$(grep -oE 'CONFIG_[A-Z0-9_]+' <<< "${line}" | head -n1)"
      have="$(grep -E "^${key}=|^# ${key} is not set" "${cfg}" || printf 'unset')"
      warn "${c##*/}: wants '${line}', the .config has '${have}'"
    done <<< "${missing}"
    failed=1
  done
  ((failed == 0)) || fatal "The kernel .config breaks a capability contract (see above): a fragment overrides it, or a Kconfig dependency is missing (BTF needs pahole on the host)."
}

# A .config that asks for BTF must produce it: when pahole is missing or too
# old, kbuild drops it without failing, and only the loader of a CO-RE program
# finds out. Checked for every build, whatever the profile.
kernel_validate_btf() {
  local cfg="${KERNEL_BUILD_DIR}/.config" ko
  grep -qx 'CONFIG_DEBUG_INFO_BTF=y' "${cfg}" || return 0
  _kernel_has_btf "${KERNEL_BUILD_DIR}/vmlinux" || fatal "CONFIG_DEBUG_INFO_BTF=y but vmlinux has no .BTF section (pahole missing or failed)."
  grep -qx 'CONFIG_DEBUG_INFO_BTF_MODULES=y' "${cfg}" || { log "BTF: vmlinux"; return 0; }
  ko="$(find "${KERNEL_BUILD_DIR}" -name '*.ko' -print -quit)"
  if [[ -z "${ko}" ]] || ! _kernel_has_btf "${ko}"; then
    fatal "CONFIG_DEBUG_INFO_BTF_MODULES=y but modules carry no .BTF section (${ko:-no module built})."
  fi
  log "BTF: vmlinux and modules"
}

# True when ELF file $1 has a non-empty .BTF section. The section index may be
# split over two fields ("[ 9]"), so the size is found relative to the name.
_kernel_has_btf() {
  readelf -SW "$1" 2>/dev/null | awk '
    { for (i = 1; i <= NF; i++)
        if ($i == ".BTF" && $(i + 1) == "PROGBITS") { size = $(i + 4); gsub(/0/, "", size); if (size != "") found = 1 } }
    END { exit !found }'
}

# Assemble KERNEL_FRAGMENT_LIST (absolute paths, in merge order).
kernel_fragment_list() {
  local -a list=()
  if [[ "${DISTRO_KERNEL}" == "1" && -f "${DISTRO_CONFIG_FRAGMENT}" ]]; then
    list+=("${DISTRO_CONFIG_FRAGMENT}")
  fi
  # The profile's contracts, as requests: after the distro base, before everything
  # board-specific, so a board can still build in what a contract asks as a module
  # (and a board turning off what a contract needs fails the gate, not the board).
  kernel_contract_list
  list+=("${KERNEL_CONTRACT_LIST[@]}")
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
  # A contract enters the merge as its request (kernel_contract_request), judged
  # against defconfig and the fragments ahead of it.
  local f
  local -a merge=() before=("${KERNEL_BUILD_DIR}/.config")
  for f in "${KERNEL_FRAGMENT_LIST[@]}"; do
    [[ -f "${f}" ]] || fatal "Kernel fragment missing: ${f}"
    log "fragment: ${f#"${PROJECT_DIR}/"}"
    if [[ "${f}" == *.contract ]]; then
      kernel_contract_request "${f}" "${KERNEL_BUILD_DIR}/${f##*/}.request" "${before[@]}"
      f="${KERNEL_BUILD_DIR}/${f##*/}.request"
    fi
    merge+=("${f}")
    before+=("${f}")
  done
  run "${KERNEL_SRC_DIR}/scripts/kconfig/merge_config.sh" -m -O "${KERNEL_BUILD_DIR}" \
    "${KERNEL_BUILD_DIR}/.config" "${merge[@]}"

  run make -C "${KERNEL_SRC_DIR}" O="${KERNEL_BUILD_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
  kernel_validate_contracts

  # Verification escape hatch: stop right after the .config is resolved so the new
  # engine's .config can be diffed against the old build.sh's (no compile needed).
  if [[ "${STOP_AFTER_KCONFIG:-0}" == "1" ]]; then
    log "STOP_AFTER_KCONFIG=1: kernel .config resolved at ${KERNEL_BUILD_DIR}/.config; stopping before compile."
    return 0
  fi

  run make -C "${KERNEL_SRC_DIR}" O="${KERNEL_BUILD_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"${JOBS}" Image dtbs modules

  [[ -f "${KERNEL_BUILD_DIR}/arch/arm64/boot/Image" ]] || fatal "Kernel Image not generated."
  [[ -f "${KERNEL_BUILD_DIR}/arch/arm64/boot/dts/${KERNEL_DTB}" ]] || fatal "Kernel DTB not generated: ${KERNEL_DTB}"
  kernel_validate_btf
}

# The release string of the built kernel (its /lib/modules directory name).
kernel_release() {
  local krel
  krel="$(make -s -C "${KERNEL_BUILD_DIR}" kernelrelease)"
  [[ -n "${krel}" ]] || fatal "Could not resolve the kernel release from ${KERNEL_BUILD_DIR}."
  printf '%s\n' "${krel}"
}

install_kernel_modules() {
  section "Installing kernel modules into rootfs"
  # INSTALL_MOD_STRIP=1: the distro-grade config builds thousands of modules and
  # DEBUG_INFO_BTF leaves heavy debug info (~600 MB unstripped); strip on install
  # to keep the rootfs small. vmlinux BTF stays in the Image (dae/CO-RE works).
  run_sudo make -C "${KERNEL_SRC_DIR}" O="${KERNEL_BUILD_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"${JOBS}" \
    INSTALL_MOD_PATH="${MOUNTPOINT_ROOT}" INSTALL_MOD_STRIP=1 modules_install
}
