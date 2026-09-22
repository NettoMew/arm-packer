# Widora MangoPi M28K board support (RK3528)

Assets injected by `scripts/build.sh` when `BOARD=m28k`. The M28K is not yet
in mainline U-Boot or mainline Linux, so its device trees / defconfig (and the
RK3528 USB backport patches) are kept here and applied during the build.

The default kernel tag is defined in [`config/versions.conf`](../../config/versions.conf).
Linux **7.2.7** provides native RK3528 USB PHY and DT nodes replacing the `121-*` / `131-02-*` USB
backport series, so the hook skips that series when both are present. Older
trees without native support still use the backports. The `200-*` SDIO power
sequence fix remains applied; the AIC8800 patch filenames retain their original
7.1 porting baseline, not the selected kernel version.

## Build

```sh
# Full build (fetches mainline U-Boot and pinned Linux, then injects M28K sources):
make m28k

# Reuse already-cloned source trees for iteration, NOT for a kernel upgrade:
make m28k SKIP_FETCH=1
```

Default output: `out/widora-mangopi-m28k-screen-alpine-<kernelversion>.img.xz`.
See [build instructions](../../docs/build.md) for upgrading an existing workspace
and flashing the compressed image. Serial console: 1500000 8N1 on ttyS0;
default login: `root` / `120102`.

## Layout

```
uboot/dts/      rk3528-mangopi-m28.dtsi, rk3528-mangopi-m28k.dts  -> u-boot dts/upstream/src/arm64/rockchip/
uboot/dtsi/     rk3528-mangopi-m28k-u-boot.dtsi                    -> u-boot arch/arm/dts/
uboot/configs/  mangopi-m28k-rk3528_defconfig                      -> u-boot configs/
linux/dts/      rk3528-mangopi-m28.dtsi, rk3528-mangopi-m28k.dts  -> linux arch/arm64/boot/dts/rockchip/
linux/patches/  RK3528 USB backport (inno-usb2 phy + USB DTS nodes)
```

## Peripherals

Working on mainline: serial console, eMMC, micro-SD, eth0 (gmac1 RGMII PHY),
eth1 (RTL8168 PCIe NIC via combphy), **USB 2.0 host (backported)**, 3x LEDs,
user button, PWM, SARADC, I2C, and **onboard AIC8800 Wi-Fi 6 + Bluetooth (SDIO)**.

### Wi-Fi / Bluetooth (AIC8800, SDIO)

The out-of-tree `radxa-pkg/aic8800` driver is fetched, patched to mainline
(`aic8800/0001-aic8800-sdio-mainline-7.1-port.patch`), and built together with
Bluetooth-over-SDIO into `aic8800_fdrv` (`CONFIG_SDIO_BT=y`). The build installs
the modules (`aic8800_bsp`, `aic8800_fdrv`) + firmware (`/lib/firmware/aic8800/sdio`),
auto-loads them on boot, installs `wpa_supplicant`/`bluez` (online apk), and
enables the `wpa_supplicant` + `bluetooth` services.

**Out of the box, minus your credentials.** Edit
`/etc/wpa_supplicant/wpa_supplicant.conf` (uncomment the `network={...}` block or
run `wpa_passphrase "SSID" "password" >> /etc/wpa_supplicant/wpa_supplicant.conf`),
then `reboot` or `rc-service wpa_supplicant restart`. `wlan0` is preconfigured for
DHCP. Bluetooth: `bluetoothctl`.

The online apk step needs network at build time; if it is unavailable the build
still ships the driver + firmware and warns you to `apk add wpa_supplicant bluez`
after first boot.

## Source

Device trees, defconfig and patches are derived from ImmortalWrt
(`/home/adam/Documents/immortalwrt`, commit `fe89a355ad` "rockchip: add Widora
MangoPi M28K support") and its `target/linux/rockchip/patches-6.18` USB series.
