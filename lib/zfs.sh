#!/usr/bin/env bash
# lib/zfs.sh — OpenZFS out-of-tree kernel module, built against the just-built
# mainline kernel. Cross-board feature: build.sh sources this only when
# WITH_ZFS=1, and pipeline.sh / rootfs.sh call the zfs_* helpers (also guarded).
#
# Kernel module only (--with-config=kernel): ZFS is CDDL so it can never go in the
# .config — the out-of-tree .ko is the standard route, same model as aic8800.sh.
# Userspace (zpool/zfs CLIs) comes from the distro's ZFS_USERSPACE_PACKAGES; it is
# best-effort (graceful warn on failure), since not every distro ships it in its
# official repos (Arch/ALARM needs archzfs).

ZFS_REPO="${ZFS_REPO:-https://github.com/openzfs/zfs.git}"
ZFS_REF="${ZFS_REF:-zfs-2.3.4}"
ZFS_DIR="${ZFS_DIR:-${SRC_DIR}/zfs}"
# Distro plugins declare ZFS_USERSPACE_PACKAGES (Alpine: zfs / Arch: zfs-utils).

# Clone/refresh the OpenZFS source and autogen the configure script. Idempotent.
zfs_prepare_source() {
  section "Preparing OpenZFS source (${ZFS_REF})"
  if [[ -d "${ZFS_DIR}/.git" ]]; then
    if [[ "${SKIP_FETCH}" == "1" ]]; then
      log "SKIP_FETCH=1: reusing existing OpenZFS clone."
      run git -C "${ZFS_DIR}" checkout -- .
    else
      # FETCH_HEAD works whether ZFS_REF is a tag, branch or commit (so switching
      # e.g. zfs-2.3.4 → master needs no re-clone).
      run git -C "${ZFS_DIR}" fetch --depth 1 origin "${ZFS_REF}"
      run git -C "${ZFS_DIR}" checkout -q -f FETCH_HEAD
    fi
  else
    run git clone --depth 1 --branch "${ZFS_REF}" "${ZFS_REPO}" "${ZFS_DIR}"
  fi
  log "OpenZFS HEAD: $(git -C "${ZFS_DIR}" rev-parse --short HEAD)"
  run sh -c "cd '${ZFS_DIR}' && ./autogen.sh"
}

# Configure (kernel-module-only, cross) + build against KERNEL_BUILD_DIR.
zfs_build_module() {
  section "Building OpenZFS kernel module against the built kernel"
  [[ -f "${KERNEL_BUILD_DIR}/Module.symvers" ]] || \
    fatal "ZFS build needs a built kernel (Module.symvers missing in ${KERNEL_BUILD_DIR}) — kernel modules must build first."
  run sh -c "cd '${ZFS_DIR}' && ./configure \
    --with-config=kernel \
    --with-linux='${KERNEL_SRC_DIR}' \
    --with-linux-obj='${KERNEL_BUILD_DIR}' \
    --host=aarch64-linux-gnu \
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    KERNEL_CC=aarch64-linux-gnu-gcc KERNEL_LD=aarch64-linux-gnu-ld"
  # ARCH/CROSS_COMPILE MUST be on the make line too (not just configure): they flow
  # via MAKEFLAGS into the kernel module sub-make so the kernel Makefile emits arm64
  # CFLAGS. Without them it defaults to the host arch (x86) and feeds -mcmodel=kernel
  # / -mno-sse / -m64 to aarch64-gcc → "unrecognized option" on every object.
  run make -C "${ZFS_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"${JOBS}"
  [[ -f "${ZFS_DIR}/module/zfs.ko" ]] || fatal "zfs.ko not built."
  log "OpenZFS modules built: $(cd "${ZFS_DIR}/module" && echo *.ko)."
}

# Install the built modules into the rootfs module tree, depmod, autoload on boot.
zfs_install() {
  section "Installing OpenZFS modules into rootfs"
  local krel; krel="$(make -s -C "${KERNEL_BUILD_DIR}" kernelrelease)"
  [[ -n "${krel}" ]] || fatal "Could not resolve kernel release for ZFS module install."
  # Install only the kernel modules (the module/ subdir's install == modules_install
  # into $INSTALL_MOD_PATH/lib/modules/$krel/extra). The top-level `make install`
  # would also try to stage headers/udev to absolute paths and fail under DESTDIR.
  run_sudo make -C "${ZFS_DIR}/module" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_PATH="${MOUNTPOINT_ROOT}" install
  run_sudo depmod -b "${MOUNTPOINT_ROOT}" "${krel}"
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/modules-load.d"
  printf 'zfs\n' | run_sudo tee "${MOUNTPOINT_ROOT}/etc/modules-load.d/zfs.conf" >/dev/null
  log "OpenZFS modules installed for kernel ${krel}; autoload via modules-load.d."
}

# Online userspace (zpool/zfs CLIs). Best-effort: warn (don't fail) if the distro
# has no official ZFS package — the module is already in the image either way.
zfs_install_userspace() {
  [[ -n "${ZFS_USERSPACE_PACKAGES}" ]] || { log "ZFS_USERSPACE_PACKAGES empty; module-only image."; return 0; }
  section "Installing OpenZFS userspace online (${ZFS_USERSPACE_PACKAGES})"
  if ! distro_install_pkgs "${ZFS_USERSPACE_PACKAGES}"; then
    warn "Online ZFS userspace install failed (no network, or not in this distro's official repos — Arch needs archzfs). The zfs.ko module is still in the image; install '${ZFS_USERSPACE_PACKAGES}' after boot."
    return 0
  fi
  log "OpenZFS userspace installed."
}
