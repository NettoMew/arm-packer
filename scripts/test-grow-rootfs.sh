#!/usr/bin/env bash
# First-boot growth (resources/systemd/grow-rootfs) for real, with the data
# partition PROFILE=incus asks for: the script runs chrooted into a loop disk
# whose first partition is the root (mountinfo is relative to the chroot, so it
# sees that partition as /), on MBR and on GPT, and a ZFS pool is then created on
# the partition it made, the way incus-init does. A disk too small for the
# partition must get none. Every case checks that the area between the partition
# table and the root, where U-Boot boards keep their bootloader, is unchanged.
#
# Needs root, util-linux, e2fsprogs and, for the pool, OpenZFS on the host; the
# tools inside the chroot come from IMAGE, a systemd image of this project with
# an ext4 root on partition 1 (any U-Boot board's Debian or Arch image).
#   sudo bash scripts/test-grow-rootfs.sh out/orangepi-zero3-debian-7.2.7.img
set -Eeuo pipefail
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
src="$(realpath "${1:?usage: $0 IMAGE (ext4 root on partition 1)}")"
t="$(mktemp -d "${TMPDIR:-/tmp}/test-grow-rootfs.XXXXXX")"
grow="$(pwd)/resources/systemd/grow-rootfs"
cleanup() {
  set +e
  umount -q "${t}/root" "${t}/src" 2>/dev/null
  for f in "${t}"/*.img; do losetup -j "${f}" | cut -d: -f1 | xargs -r -n1 losetup -d; done
  rm -rf "${t}"
}
trap cleanup EXIT
mkdir -p "${t}/root" "${t}/src"
have_zfs=0; command -v zpool >/dev/null && [[ -d /sys/module/zfs ]] && have_zfs=1

attach() {
  local l
  l="$(losetup --find --show -P "$1")"
  for _ in $(seq 20); do [[ -b ${l}p1 ]] && break; partx -u "${l}" 2>/dev/null || true; sleep 0.3; done
  printf '%s\n' "${l}"
}
# Everything between the partition table and the root at 16 MiB: the SPL at
# 8 KiB (sunxi), u-boot-rockchip.bin at sector 64.
area() {
  local skip=1; [[ $2 == gpt ]] && skip=34
  dd if="$1" bs=512 skip="${skip}" count=$((32768 - skip)) status=none | sha256sum
}
sectors() { cat "/sys/class/block/${1#/dev/}/$2"; }

run_case() {
  local name=$1 label=$2 size=$3 disk="${t}/$1.img" loop s before
  printf '\n== %s: %s label, %s disk\n' "${name}" "${label}" "${size}"
  # The root at 16 MiB, as every vendor lays it out, behind a stand-in for the
  # bootloader; its files come from IMAGE.
  truncate -s 4G "${disk}"
  printf 'label: %s\nstart=32768, type=L\n' "${label}" | sfdisk -q "${disk}"
  s=1; [[ ${label} == gpt ]] && s=34
  dd if=/dev/urandom of="${disk}" bs=512 seek="${s}" count=$((32768 - s)) conv=notrunc status=none
  loop="$(attach "${disk}")"; mkfs.ext4 -q -L root "${loop}p1"
  s="$(attach "${src}")"; mount -o ro "${s}p1" "${t}/src"; mount "${loop}p1" "${t}/root"
  cp -a "${t}/src/." "${t}/root/"; umount "${t}/src" "${t}/root"; losetup -d "${s}" "${loop}"
  truncate -s "${size}" "${disk}"
  before="$(area "${disk}" "${label}")"

  loop="$(attach "${disk}")"
  mount "${loop}p1" "${t}/root"
  install -m 0755 "${grow}" "${t}/root/usr/local/sbin/grow-rootfs"
  printf 'ROOT_SIZE=8G\nDATA_PARTITION=incus\nDATA_MIN=8G\n' > "${t}/root/etc/default/grow-rootfs"
  rm -f "${t}/root/var/lib/misc/.rootfs-grown" "${t}/root/var/lib/misc/incus.partition"
  # shellcheck disable=SC2016  # $r is expanded by the inner shell.
  r="${t}/root" unshare -m sh -c 'mount -t proc proc "$r/proc" && mount --bind /sys "$r/sys" &&
    mount --bind /dev "$r/dev" && chroot "$r" /usr/local/sbin/grow-rootfs'
  [[ -f ${t}/root/var/lib/misc/.rootfs-grown ]]
  local root_bytes fs_bytes
  root_bytes=$(( $(sectors "${loop}p1" size) * 512 ))
  fs_bytes=$(( $(dumpe2fs -h "${loop}p1" 2>/dev/null | awk -F: '/^Block count/ { print $2 }') * 4096 ))
  if [[ ${name} == small ]]; then
    [[ ! -e ${loop}p2 && ! -e ${t}/root/var/lib/misc/incus.partition ]]
    (( root_bytes > 11 * 1024 ** 3 && fs_bytes == root_bytes / 4096 * 4096 ))
  else
    (( root_bytes == 8 * 1024 ** 3 && fs_bytes == root_bytes ))
    [[ -b ${loop}p2 ]]
    (( $(sectors "${loop}p2" start) >= $(sectors "${loop}p1" start) + $(sectors "${loop}p1" size) ))
    (( $(sectors "${loop}p2" size) * 512 > 14 * 1024 ** 3 ))
    [[ "$(< "${t}/root/var/lib/misc/incus.partition")" == "/dev/disk/by-partuuid/$(blkid -p -s PART_ENTRY_UUID -o value "${loop}p2")" ]]
    if [[ ${label} == gpt ]]; then
      [[ "$(blkid -p -s PART_ENTRY_TYPE -o value "${loop}p2")" == 6a898cc3-1dd2-11b2-99a6-080020736631 ]]
      [[ "$(blkid -p -s PART_ENTRY_NAME -o value "${loop}p2")" == incus ]]
      sfdisk --verify "${loop}" >/dev/null
    else
      [[ "$(blkid -p -s PART_ENTRY_TYPE -o value "${loop}p2")" == 0xbf ]]
    fi
    if (( have_zfs )); then
      zpool create -f -o cachefile=none -t "test-grow-$$" -o ashift=12 -o autotrim=on \
        -O compression=zstd -O xattr=sa -O acltype=posixacl -O mountpoint=none incus "${loop}p2"
      zpool list -H -o name,size,health "test-grow-$$" | grep -q ONLINE
      zpool destroy "test-grow-$$"
    fi
  fi
  umount "${t}/root"; losetup -d "${loop}"
  [[ "$(area "${disk}" "${label}")" == "${before}" ]]
  printf 'PASS %s: root %d MiB%s, bootloader area unchanged\n' "${name}" $((root_bytes >> 20)) \
    "$([[ ${name} == small ]] && echo ', no data partition' || echo ", incus partition$( (( have_zfs )) && echo ' + ZFS pool')")"
}

run_case mbr dos 24G
run_case gpt gpt 24G
run_case small gpt 12G
(( have_zfs )) || printf 'NOTE: no OpenZFS on this host; the pool step was skipped.\n'
printf 'All grow-rootfs tests passed.\n'
