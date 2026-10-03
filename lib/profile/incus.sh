#!/usr/bin/env bash
# lib/profile/incus.sh — an Incus host: system containers, OCI application
# containers and virtual machines, run from the CLI or the web UI, on ZFS.
#
# Kernel: two capability contracts, merged as requests and checked against the
# final .config (lib/kernel.sh). kconfig/incus.contract covers what Incus uses:
# every cgroup v2 controller and namespace, AppArmor in the LSM order, KVM with
# vhost and vsock, bridges, OVN and Ceph, nftables. kconfig/dae.contract is the
# eBPF baseline with BTF, on which dae, or any CO-RE program, loads on the host
# or in a container. OpenZFS is built with the kernel (lib/zfs.sh).
#
# Storage is ZFS and nothing else. A ZFS root (Dragon Q8B) gives Incus a dataset
# beside the root, rpool/incus. A root that has to stay ext4, because U-Boot
# reads the kernel from it, stops at INCUS_ROOT_SIZE on first boot and the rest
# of the disk becomes a partition holding a pool of its own, "incus"
# (resources/systemd/grow-rootfs); a disk without room for it is refused at
# first boot rather than served by a lesser driver.
#
# Userspace: Incus from Zabbly's repository, whose packages carry their own QEMU,
# edk2, virtiofsd and lxcfs; the web UI; skopeo and umoci for OCI images; root's
# subordinate id range; the production sysctl and limits of the Incus
# documentation, and the ZFS ARC held to a quarter of RAM. The repository key
# ships in resources/incus/zabbly.asc and must match the fingerprint pinned in
# config/versions.conf before it enters the image.
#
# First boot (resources/incus/rootfs): a oneshot initialises Incus without any
# network: the ZFS pool, the NAT bridge incusbr0, image and backup volumes in the
# pool, and the API and web UI on port 8443, which serve only clients that have
# been granted trust.
#
# Defines the profile_* contract, like lib/profile/base.sh.
#
# shellcheck disable=SC2034  # PROFILE_* vars are read by scripts/build.sh.

# shellcheck source=lib/zfs.sh
source "${LIB_DIR}/zfs.sh"

PROFILE_IMAGE_TAG=incus
# Incus with its bundled QEMU and firmware, the UI, the OCI tools and OpenZFS
# add about 650 MB to the Debian base; first boot grows it.
PROFILE_IMAGE_SIZE=4G

INCUS_CHANNEL="${INCUS_CHANNEL:-${DEFAULT_INCUS_CHANNEL}}"
INCUS_PACKAGES="${INCUS_PACKAGES:-incus incus-ui-canonical skopeo umoci}"
INCUS_RESOURCES="${RESOURCES_DIR}/incus"
# The ids Incus maps unprivileged containers onto (its documented default range).
INCUS_IDMAP='root:1000000:1000000000'
# On a root that is not ZFS: the root's share of the disk, and the least the
# pool's partition may have.
INCUS_ROOT_SIZE="${INCUS_ROOT_SIZE:-8G}"
INCUS_POOL_MIN="${INCUS_POOL_MIN:-8G}"

profile_env_summary() {
  log "profile: incus (Zabbly ${INCUS_CHANNEL}: ${INCUS_PACKAGES}; ZFS pool, OpenZFS ${OPENZFS_VERSION}; kernel contracts incus + dae)"
}

profile_check_config() {
  declare -F distro_add_package_source distro_install_zfs >/dev/null \
    || fatal "PROFILE=incus installs Incus from Zabbly's apt repository and keeps it on ZFS, which DISTRO=${DISTRO} cannot add (no distro_add_package_source / distro_install_zfs); use DISTRO=debian."
  [[ "${ROOTFS_TYPE}" == zfs || "${AUTO_RESIZE}" == 1 ]] \
    || fatal "PROFILE=incus on a ${ROOTFS_TYPE} root takes its ZFS pool from the disk beyond the root on first boot; AUTO_RESIZE=0 would leave it none."
}

# The repository key must be the one Zabbly publishes, before apt ever trusts it.
profile_check_host() {
  local fpr
  have gpg || fatal "PROFILE=incus checks the Zabbly key with gpg (Debian/Ubuntu: apt install gpg)."
  fpr="$(gpg --show-keys --with-colons "${INCUS_RESOURCES}/zabbly.asc" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
  [[ "${fpr}" == "${INCUS_ZABBLY_FINGERPRINT}" ]] \
    || fatal "resources/incus/zabbly.asc has fingerprint '${fpr:-none}', expected ${INCUS_ZABBLY_FINGERPRINT}."
  log "Zabbly key ${fpr} verified."
}

profile_kernel_contracts() { printf 'incus dae\n'; }

profile_build_modules() { zfs_build_modules; }

profile_install() {
  zfs_install
  section "Installing Incus (Zabbly ${INCUS_CHANNEL}) and its first-boot setup"
  distro_add_package_source "zabbly-incus-${INCUS_CHANNEL}" "${INCUS_RESOURCES}/zabbly.asc" \
    "${INCUS_ZABBLY_URL}/${INCUS_CHANNEL}" main
  distro_install_pkgs "${INCUS_PACKAGES}" || fatal "Could not install ${INCUS_PACKAGES}."

  local f
  for f in subuid subgid; do
    run_sudo grep -q '^root:' "${MOUNTPOINT_ROOT}/etc/${f}" 2>/dev/null \
      || printf '%s\n' "${INCUS_IDMAP}" | run_sudo tee -a "${MOUNTPOINT_ROOT}/etc/${f}" >/dev/null
  done

  # sysctl, limits, the ARC cap and the first-boot initialisation. The overlay
  # takes its modes from the umask, never from the checkout.
  run_sudo cp -rT --no-preserve=mode,ownership "${INCUS_RESOURCES}/rootfs" "${MOUNTPOINT_ROOT}"
  run_sudo chmod 0755 "${MOUNTPOINT_ROOT}/usr/libexec/arm-packer/incus-init" \
    "${MOUNTPOINT_ROOT}/usr/libexec/arm-packer/zfs-arc-limit"
  run_sudo install -d "${MOUNTPOINT_ROOT}/etc/arm-packer"
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/arm-packer/incus.conf" >/dev/null <<EOF
# arm-packer, PROFILE=incus: read by /usr/libexec/arm-packer/incus-init when it
# creates the pool of a root that is not ZFS (a ZFS root's dataset inherits).
POOL_PROPERTIES="${ZFS_POOL_PROPERTIES}"
DATASET_PROPERTIES="${ZFS_DATASET_PROPERTIES}"
INCUS_MIN_DISK="$(numfmt --to=iec $(( $(numfmt --from=iec "${INCUS_ROOT_SIZE}") + $(numfmt --from=iec "${INCUS_POOL_MIN}") )))"
EOF
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/default/grow-rootfs" >/dev/null <<EOF
# arm-packer, PROFILE=incus: a root that is not ZFS stops at ROOT_SIZE on first
# boot; the rest of the disk becomes the partition of the Incus ZFS pool.
ROOT_SIZE=${INCUS_ROOT_SIZE}
DATA_PARTITION=incus
DATA_MIN=${INCUS_POOL_MIN}
EOF
  distro_enable_services "arm-packer-zfs-arc-limit arm-packer-incus-init"
  # shellcheck disable=SC2016  # ${Version} is dpkg-query's field, not a shell variable.
  log "Incus $(run_sudo chroot "${MOUNTPOINT_ROOT}" dpkg-query -W -f='${Version}' incus) installed; first boot creates the ZFS pool, incusbr0 and the :8443 listener."
}
