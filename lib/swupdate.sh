#!/usr/bin/env bash
# Optional offline updater foundation. Package installation is distro-owned.
# Does not advertise a kernel transaction/rollback implementation that isn't here.

swupdate_preflight() {
  [[ "${ENABLE_SWUPDATE}" == 0 || "${ENABLE_SWUPDATE}" == 1 ]] || fatal "ENABLE_SWUPDATE must be 0 or 1."
  [[ "${ENABLE_SWUPDATE}" == 1 ]] || return 0
  declare -F distro_install_swupdate >/dev/null || fatal "SWUpdate packaging is not implemented for DISTRO=${DISTRO}."
  [[ -d "${SWUPDATE_PACKAGE_DIR}" ]] || fatal "Set SWUPDATE_PACKAGE_DIR to the built upstream updater packages."
  [[ -f "${SWUPDATE_PUBLIC_KEY}" ]] || fatal "Set SWUPDATE_PUBLIC_KEY to your SWU verification public key (never the private key)."
  grep -q 'PRIVATE KEY' "${SWUPDATE_PUBLIC_KEY}" && fatal "SWUPDATE_PUBLIC_KEY must not contain a private key."
  openssl pkey -pubin -in "${SWUPDATE_PUBLIC_KEY}" -noout >/dev/null || fatal "Invalid SWU public key."
  openssl rsa -pubin -in "${SWUPDATE_PUBLIC_KEY}" -noout >/dev/null 2>&1 || fatal "This updater profile requires an RSA public key."
  [[ "${BOARD}" =~ ^[a-z0-9-]+$ && "${DISTRO}" =~ ^[a-z0-9-]+$ ]] || fatal "Invalid update target identity."
}

install_swupdate() {
  [[ "${ENABLE_SWUPDATE}" == 1 ]] || return 0
  section "Installing signed offline SWUpdate (no daemon or bootloader writes)"
  distro_install_swupdate
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/arm-packer"
  run_sudo install -m 644 "${SWUPDATE_PUBLIC_KEY}" "${MOUNTPOINT_ROOT}/etc/arm-packer/update-public.pem"
  printf '%s %s-%s-v1\n' "${BOARD}" "${BOARD}" "${DISTRO}" |
    run_sudo tee "${MOUNTPOINT_ROOT}/etc/arm-packer/hwrevision" >/dev/null
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/arm-packer/swupdate.cfg" >/dev/null <<'EOF'
globals = {
    bootloader = "none";
    public-key-file = "/etc/arm-packer/update-public.pem";
};
EOF
  # Native aarch64 and configured qemu/binfmt builders both exercise the target
  # binary. A missing library must fail the image build, not the first update.
  run_sudo chroot "${MOUNTPOINT_ROOT}" /usr/sbin/swupdate -h >/dev/null
  log "SWUpdate installed. Kernel bundle activation/automatic rollback is not enabled."
}
