# kconfig/ — composable kernel `.config` fragments

`lib/kernel.sh` builds the kernel `.config` as:

```
make defconfig
scripts/kconfig/merge_config.sh -m -O <build> .config  <ordered fragment list>
make olddefconfig
```

The **fragment list is assembled in this order** (later files win — this is
load-bearing):

1. `distro-arm64.config` — only if `DISTRO_KERNEL=1`. A ~6.8k-line full `=y`/`=m`
   distro base (Arch Linux ARM derived). Contains **only enables**, so it can
   never turn a defconfig built-in off.
2. `essentials.fragment` — rootfs + networking boot essentials (all boards).
3. vendor + SoC fragments from `vendor_default_fragments`:
   `rockchip.fragment` [`+ rk3588.fragment`] | `allwinner-h618.fragment`.
4. board fragments from `BOARD_KERNEL_FRAGMENTS` (e.g. `boards/m28k/kernel.fragment`).
5. `leds-input.fragment` — generic LEDs + GPIO keys + evdev (all boards).
6. `docker.fragment` — only if `DOCKER_KERNEL=1`.
7. `modern.fragment` — only if `MODERN_KERNEL=1`.

The distro base goes **first** so that fragments 2–7 re-force the boot-critical
built-ins (ext4/mmc/phy/…) after the broad distro merge — same invariant the old
`build.sh` had when its `ensure_kernel_config_option` calls ran after the distro
merge.

## Rules when editing

- **No `-r` (strict) merge.** The distro base and the docker/modern fragments
  intentionally set some symbols to different values (e.g. `CONFIG_BRIDGE=y` in
  distro vs `=m` in `docker.fragment`). `-r` would treat those intended overrides
  as errors. Last-file-wins resolves them, matching the old behavior.
- **`CONFIG_DRM_PANTHOR=m` must stay a module** in `rk3588.fragment`. Built-in
  (`=y`) probes before `/lib/firmware` is mounted, so the Mali CSF firmware load
  fails and the GPU never binds. It is loaded after the rootfs is up.
- Unknown / dependency-unsatisfiable symbols are warned about by `merge_config.sh`
  and dropped by `olddefconfig` — the same graceful degradation the old `|| true`
  on `ensure_kernel_config_option` gave.

These fragments were mechanically derived from the original
`ensure_kernel_config_option` lines (`--enable`→`=y`, `--module`→`=m`,
`--disable`→`# CONFIG_x is not set`).
