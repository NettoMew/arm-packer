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
2. the profile's capability contracts, `<name>.contract` (see below), as requests.
3. `essentials.fragment` — rootfs + networking boot essentials (all boards).
4. vendor + SoC fragments from `vendor_default_fragments`:
   `rockchip.fragment` [`+ rk3588.fragment`] | `allwinner-h618.fragment` | `qcom-sc8280xp.fragment`.
5. distro fragments from `distro_default_fragments` (e.g. `systemd.fragment`).
6. board fragments from `BOARD_KERNEL_FRAGMENTS` (e.g. `boards/m28k/kernel.fragment`).
7. `leds-input.fragment` — generic LEDs + GPIO keys + evdev (all boards).
8. `docker.fragment` — only if `DOCKER_KERNEL=1`.
9. `modern.fragment` — only if `MODERN_KERNEL=1`.

The distro base goes **first** so that fragments 3–9 re-force the boot-critical
built-ins (ext4/mmc/phy/…) after the broad distro merge — same invariant the old
`build.sh` had when its `ensure_kernel_config_option` calls ran after the distro
merge.

## Capability contracts (`*.contract`)

A profile (`lib/profile/<name>.sh`, `profile_kernel_contracts`) names the
contracts its kernel must meet: `incus.contract` (what Incus uses, containers
and VMs) and `dae.contract` (the eBPF/BTF baseline dae needs, taken from
vyos-rockchip, where it was proven on hardware). The base profile has none, so
its `.config` is exactly what the fragments make it.

A contract is a request and a gate:

- **Request.** It is merged right after the distro base, before anything board
  specific, so a board may still build in what a contract asks as a module.
  `=m` means "at least a module": the line is left out of the request when the
  defconfig or an earlier fragment already builds the symbol in, so a contract
  never lowers a built-in (`kernel_contract_request`).
- **Gate.** After `olddefconfig`, every line is checked against the final
  `.config` (`kernel_validate_contracts`): `=y` built in, `=m` module or built
  in, `# … is not set` off, a quoted value matched exactly, and any other line
  that is not a comment is a breach, so a typo cannot drop out of the check. A
  later fragment overriding a contract, or a Kconfig dependency that cannot be
  met, fails the build with "wants … / has …" instead of shipping a kernel the
  profile cannot use. `SKIP_BUILD=1` checks the reused kernel the same way.

Independently of profiles, a `.config` with `CONFIG_DEBUG_INFO_BTF=y` must
produce a vmlinux with a non-empty `.BTF` section (and modules with one, if
`DEBUG_INFO_BTF_MODULES=y`): kbuild drops BTF silently when pahole is missing or
too old (`kernel_validate_btf`).

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
  on `ensure_kernel_config_option` gave. What must not degrade belongs in a
  contract, where it is checked.
- Keep `dae.contract` in step with vyos-rockchip's `73-dae.config`.

These fragments were mechanically derived from the original
`ensure_kernel_config_option` lines (`--enable`→`=y`, `--module`→`=m`,
`--disable`→`# CONFIG_x is not set`).
