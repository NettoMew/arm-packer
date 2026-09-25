# Dragon Q8B kernel series

`patches/` is a `git format-patch` series that applies cleanly, in order, on top
of Linux **v7.2.7**. It is Armbian's tested `sc8280xp-edge` series (written for
v7.2.3) carried forward to v7.2.7:

- **Source:** [armbian/build `1443dbae`](https://github.com/armbian/build/tree/1443dbaed3f65d6d3ce0fa343047fbf4a09dbfd4/patch/kernel/archive/sc8280xp-edge),
  the last commit touching the series (2026-09-12). Authors and commit messages
  are kept as Armbian carries them.
- **Dropped, already in v7.2.7:** Armbian 0042 (dpu `dev_pm_opp_set_rate(0)`),
  0044 (dsi, same), 0045 (dp, same), 0063 (adc-tm5 `IIO_VAL_INT` check).
- **Dropped, superseded in v7.2.7:** Armbian 0053 (glink endpoint teardown
  deadlock). Upstream fixed the same deadlock differently in "rpmsg: glink: fix
  deadlock in endpoint destroy during driver detach".
- **Refreshed:**
  - Armbian 0021 (here 0021, stmmac `dma_device`): a stable TSO fix moved the
    context of the `stmmac_tso_xmit()` hunks. All four DMA calls there (`dma_map_single`,
    `skb_frag_dma_map`, two `dma_mapping_error`) are converted, and no DMA call on
    `priv->device` is left in `stmmac_main.c`.
  - Armbian 0048 (here 0045, DP EDID on every probe): stable added a
    `drm_edid_connector_update()` call to `msm_dp_panel_get_modes()`. The patch
    removes that function outright, now including the new line. The bridge
    connector's `edid_read` path updates the connector itself, and nothing else
    references the function.

- **Added here:**
  - 0060 zero-initialises the IRQ domain info that the TC956x eMAC driver
    (Armbian 0028) builds on the stack. Without it, a kernel built with
    `CONFIG_INIT_STACK_NONE` hands `__irq_domain_create()` a garbage
    `direct_max`, both eMACs fail to probe with `-EINVAL`, and the board has
    no wired network. Kernels that zero the stack automatically hide the bug.
  - 0061 lets the PAS remoteproc driver attach to a DSP the boot firmware
    already started (qebspil, at EL2), found through its SMP2P
    state. It is Radxa's
    [`7bf1919dfc5e`](https://github.com/radxa/kernel/commit/7bf1919dfc5e873808f48231156aa12b64d926cc)
    from their 7.0 tree, author kept. v7.2.7's `qcom_pas_attach()` already
    checks the fatal, stop and ready states itself, so only the probe-time
    detection and the load and shutdown guards are carried. A DSP that is not
    running has published no SMP2P entry (`-ENODEV`); that now counts as "not
    preloaded" without a warning.
  - 0062 gives the board DTS a `/chosen/stdout-path`, so a bare `earlycon`
    finds the header UART.
  - 0063 builds `sc8280xp-radxa-dragon-q8b-el2.dtb`, the DTB the image
    boots: the board DTB plus `/chosen/radxa,enable-kvm`, which tells the
    firmware to start the OS at EL2, `qcom,broken-reset` on the ADSP and CDSP
    for qebspil, and the EL2 virtual timer interrupt (PPI 12) VHE wants. Iris
    is disabled there: it cannot load its firmware at EL2 (as on X1, whose
    EL2 overlay does the same).
  - 0064 and 0065 are Stephan Gerhold's `qcom,shm-bridge-vmid` binding and
    the tzmem "self owner" SHM bridge, from radxa/kernel
    [`fe0fca8ddbca`](https://github.com/radxa/kernel/commit/fe0fca8ddbca28ee77ce0a3ea63eb9a2a4029539) and
    [`88531b99bb52`](https://github.com/radxa/kernel/commit/88531b99bb52195cd3e4af1ed5aefccb3e9c27e5).
    At EL2 the firmware sets `qcom,shm-bridge-vmid` to "self owner" in the
    SCM node; without these, QTEE calls fail there with `-EINVAL`.
  - 0066 to 0069 silence log errors that are not errors: fw_devlink reporting
    sync_state()-only links it refuses by design (PMIC GLINK connectors),
    sysmon asking about the CDSP's shutdown-ack interrupt, which does not
    exist, q6apm treating the DSP's silence before its audio framework is up
    as a failed command, and the ACPI core warning when drivers such as
    iwlwifi and btintel ask for a `_DSM` on a device tree system (fixed in
    the core, so every such driver benefits).
  - 0070 is mainline's "drm/msm: mark the fbdev framebuffer as system
    memory" (`ea9dadeac79c`), backported. It stops the fbdev console's
    "framebuffer is not in virtual address space" warnings.

To refresh the series for another kernel, apply it with `git am` on a worktree
of the new tag, resolve, and export again with
`git format-patch --zero-commit --no-signature`.

| Here | Armbian `sc8280xp-edge` file |
|---|---|
| 0001 | `0001-arm64-dts-sc8280xp-fix-dwc3-reg-size.patch` |
| 0002 | `0002-arm64-dts-sc8280xp-fix-gpi-dma0-channels.patch` |
| 0003 | `0003-arm64-dts-sc8280xp-add-qup-pinctrl-states.patch` |
| 0004 | `0004-arm64-dts-sc8280xp-add-iris-video-codec.patch` |
| 0005 | `0005-arm64-dts-sc8280xp-add-radxa-dragon-q8b.patch` |
| 0006 | `0006-soc-qcom-pmic_glink-suppress-battery-via-dt.patch` |
| 0007 | `0007-pci-of-skip-config-reads-to-disabled-bridges.patch` |
| 0008 | `0008-pci-qcom-enable-sc8280xp-qps615-switch.patch` |
| 0009 | `0009-drm-bridge-simple-add-chrontel-ch7218a.patch` |
| 0010 | `0010-drm-bridge-simple-keep-powered-during-hpd.patch` |
| 0011 | `0011-phy-qcom-edp-fix-dp-mode-ldo-config.patch` |
| 0012 | `0012-drm-msm-dp-demote-link-training-failures.patch` |
| 0013 | `0013-drm-msm-dp-do-not-deliver-unhandled-pll-unlocked-irq.patch` |
| 0014 | `0014-media-iris-add-sc8280xp-gen2-platform-data.patch` |
| 0015 | `0015-drm-msm-dp-audio-prepare-port-off.patch` |
| 0016 | `0016-dt-bindings-net-qca-qca808x-Add-regulator-properties.patch` |
| 0017 | `0017-net-phy-qcom-qca808x-Add-regulator-management.patch` |
| 0018 | `0018-net-pcs-pcs-xpcs-regmap-support-XPCS-memory-mapped-M.patch` |
| 0019 | `0019-net-pcs-xpcs-re-order-xpcs_pre_config-to-update-afte.patch` |
| 0020 | `0020-net-pcs-pcs-xpcs-select-operating-mode-for-10G-baseR.patch` |
| 0021 | `0021-net-stmmac-dma-create-a-separate-dma_device-pointer.patch` |
| 0022 | `0022-net-stmmac-dwxgmac2-Add-multi-MSI-interrupt-mode.patch` |
| 0023 | `0023-net-stmmac-dwxgmac2-Add-XGMAC-3.01a-support.patch` |
| 0024 | `0024-net-stmmac-dwxgmac2-export-symbols-for-XGMAC-3.01a-D.patch` |
| 0025 | `0025-dt-bindings-net-toshiba-tc9654-dwmac-add-TC9564-Ethe.patch` |
| 0026 | `0026-misc-tc956x_pci-add-TC956x-QPS615-support.patch` |
| 0027 | `0027-gpio-tc956x-add-TC956x-QPS615-support.patch` |
| 0028 | `0028-net-stmmac-tc956x-add-TC956x-QPS615-support.patch` |
| 0029 | `0029-net-stmmac-tc956x-mac-from-firmware.patch` |
| 0030 | `0030-net-stmmac-tc956x-shutdown-callback.patch` |
| 0031 | `0031-net-phy-qca808x-dt-led-preset-modes.patch` |
| 0032 | `0032-soundwire-qcom-only-reject-over-declared-port-counts.patch` |
| 0033 | `0033-arm64-dts-qcom-sc8280xp-Add-missing-qcom-non-secure-.patch` |
| 0034 | `0034-drm-msm-dpu-Clear-stale-DSC-resources-during-modeset.patch` |
| 0035 | `0035-drm-msm-dp-Keep-branch-sink-count-in-sync.patch` |
| 0036 | `0036-drm-msm-dp-Handle-IRQ-HPD-as-a-sink-request.patch` |
| 0037 | `0037-drm-msm-dp-Skip-push_idle-in-atomic_disable-if-displ.patch` |
| 0038 | `0038-arm64-dts-qcom-sc8280xp-Add-interconnects-to-UFS.patch` |
| 0039 | `0039-drm-msm-dp-avoid-redundant-HPD-bridge-notifications.patch` |
| 0040 | `0040-media-qcom-iris-align-HEVC-decoder-internal-buffer-s.patch` |
| 0041 | `0041-media-qcom-iris-allocate-partial-decode-buffer-only-.patch` |
| 0042 | `0043-phy-qcom-qmp-combo-Avoid-orientation-changes-while-D.patch` |
| 0043 | `0046-drm-msm-dp-mark-link-bad-when-active-sink-replugged.patch` |
| 0044 | `0047-drm-msm-dp-handle-the-HPD-replug-interrupt.patch` |
| 0045 | `0048-drm-msm-dp-read-the-EDID-on-every-connector-probe.patch` |
| 0046 | `0049-drm-msm-dp-restore-the-audio-jack-after-replug.patch` |
| 0047 | `0050-pci-pwrctrl-tc9563-make-error-teardown-safe.patch` |
| 0048 | `0051-of-property-create-pci-root-port-supplier-links.patch` |
| 0049 | `0052-usb-typec-ucsi-glink-set-initial-orientation.patch` |
| 0050 | `0054-arm64-dts-sc8280xp-mark-fastrpc-dma-coherent.patch` |
| 0051 | `0055-arm64-dts-sc8280xp-q8b-power-cycle-sd-cards.patch` |
| 0052 | `0056-arm64-dts-sc8280xp-q8b-restore-qps615-axi-rate.patch` |
| 0053 | `0057-drm-msm-dp-serialize-hpd-plugged-state.patch` |
| 0054 | `0058-phy-qcom-qmp-combo-apply-deferred-orientation.patch` |
| 0055 | `0059-drm-bridge-simple-preserve-ordered-hpd-events.patch` |
| 0056 | `0060-phy-qcom-qmp-combo-serialize-pending-orientation.patch` |
| 0057 | `0061-drm-bridge-simple-discard-disabled-hpd-events.patch` |
| 0058 | `0062-arm64-dts-qcom-sc8280xp-add-complete-thermal-zones.patch` |
| 0059 | `0064-net-stmmac-tc956x-select-MAC-speed-before-PMA-init.patch` |
| 0060 | (not in Armbian; added here) |
| 0061 | (not in Armbian; radxa/kernel `7bf1919dfc5e`) |
| 0062 | (not in Armbian; added here) |
| 0063 | (not in Armbian; added here) |
| 0064 | (not in Armbian; radxa/kernel `fe0fca8ddbca`) |
| 0065 | (not in Armbian; radxa/kernel `88531b99bb52`) |
| 0066–0069 | (not in Armbian; added here) |
| 0070 | (not in Armbian; mainline `ea9dadeac79c`) |
