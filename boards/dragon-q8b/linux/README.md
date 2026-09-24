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
