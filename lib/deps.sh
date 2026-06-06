#!/usr/bin/env bash
# lib/deps.sh — host dependency check/install (apt/pacman/dnf/zypper).

install_dependencies() {
  section "Checking and installing host dependencies"
  local missing=()
  local commands=(
    git make gcc pkg-config aarch64-linux-gnu-gcc aarch64-linux-gnu-objcopy
    bc bison flex swig dtc python3 openssl depmod parted sfdisk losetup lsblk partprobe udevadm mkfs.ext4
    tar xz aria2c blkid rsync cpio perl awk sed grep findmnt mount umount dd kpartx mkfs.vfat
    qemu-aarch64-static
  )
  for cmd in "${commands[@]}"; do
    have "${cmd}" || missing+=("${cmd}")
  done

  if (( ${#missing[@]} == 0 )); then
    log "All required command-line tools are already present."
    return 0
  fi

  warn "Missing commands: ${missing[*]}"
  [[ "${INSTALL_DEPS}" == "1" ]] || fatal "Missing dependencies and INSTALL_DEPS=0."
  require_root_capability

  if have apt-get; then
    run_sudo apt-get update
    # shellcheck disable=SC2086 # APT_ASSUME_YES may intentionally contain multiple flags.
    run_sudo apt-get install ${APT_ASSUME_YES} \
      build-essential pkg-config gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
      git bc bison flex swig device-tree-compiler python-is-python3 python3 \
      python3-setuptools python3-dev python3-pyelftools python3-yaml libssl-dev uuid-dev \
      libgnutls28-dev libncurses-dev kmod dwarves qemu-user-static binfmt-support \
      kpartx dosfstools e2fsprogs parted util-linux udev aria2 xz-utils tar rsync cpio perl
  elif have pacman; then
    # shellcheck disable=SC2086 # PACMAN_ASSUME_YES intentionally contains multiple flags.
    run_sudo pacman -Sy ${PACMAN_ASSUME_YES} \
      base-devel git pkgconf bc bison flex swig dtc python python-setuptools \
      python-pyelftools python-yaml openssl gnutls aarch64-linux-gnu-gcc \
      aarch64-linux-gnu-binutils parted util-linux systemd kmod multipath-tools dosfstools \
      e2fsprogs aria2 tar xz rsync cpio perl ncurses pahole qemu-user-static qemu-user-static-binfmt
  elif have dnf; then
    run_sudo dnf install -y \
      @development-tools pkgconf-pkg-config gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
      git bc bison flex swig dtc python3 python3-devel python3-setuptools python3-pyelftools \
      python3-pyyaml openssl-devel gnutls-devel libuuid-devel ncurses-devel kmod dwarves \
      qemu-user-static binfmt-support kpartx dosfstools e2fsprogs parted util-linux aria2 xz tar rsync cpio perl
  elif have zypper; then
    run_sudo zypper --non-interactive install \
      -t pattern devel_basis git pkg-config bc bison flex swig dtc python3 python3-devel \
      cross-aarch64-gcc cross-aarch64-binutils libopenssl-devel libgnutls-devel libuuid-devel \
      ncurses-devel kmod dwarves qemu-linux-user kpartx dosfstools e2fsprogs parted util-linux aria2 \
      xz tar rsync cpio perl
  else
    fatal "Unsupported host package manager. Install missing commands manually: ${missing[*]}"
  fi

  missing=()
  for cmd in "${commands[@]}"; do
    have "${cmd}" || missing+=("${cmd}")
  done
  (( ${#missing[@]} == 0 )) || fatal "Still missing after install: ${missing[*]}"
  log "Dependency check passed after installation."
}
