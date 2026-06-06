# Radxa ROCK 5C 与 RK3582 开核

ROCK 5C 已**完整在主线**：U-Boot `rock-5c-rk3588s_defconfig` + Linux `rk3588s-rock-5c.dtb`。
板子可能是满血 **RK3588S2**，也可能是降级分级的 **RK3582**。

RK3582 的「砍核」**完全发生在 U-Boot**：主线 U-Boot 的 `ft_system_setup()`
（`arch/arm/mach-rockchip/rk3588/rk3588.c`，由 `CONFIG_OF_SYSTEM_SETUP=y` 触发）在把设备树
交给内核前，读芯片 OTP efuse，先屏蔽 **OTP 实测的坏核**，再套一层**市场分级策略**：强制再砍
掉一个大核 cluster（cpu6/cpu7）和 Mali-G610 GPU。

**开核（`ROCK5C_UNLOCK=1`，默认）= 一个 U-Boot 补丁**
（`boards/rock5c/uboot/patches/0001-rk3582-unlock-cores-gpu.patch`），把 ft_system_setup() 里
**三段策略** `#if 0` 掉：①「一核坏就连坐砍整簇」（否则同簇的好核也被牵连）、②「再强制砍一个大核
簇」（分级）、③「强制砍 GPU」。**保留 OTP 对单颗坏核的真实标记**，所以真坏的核仍被屏蔽，能用的
好核全部拿回 → 恢复 GPU + 尽可能多的大核。

- ✅ **实测**（本人 RK3582 ROCK 5C）：开核后 **7 核**（4×A55 + 3×A76 @2.4GHz）+ Mali-G610 GPU 正常。
- ℹ️ 为什么是 7 不是 8：这颗片子有**一颗大核（MPIDR 0x400）是真坏的**（强行打开会 `failed to
  come online`），所以最多 7 核。良率好的 RK3582 可达 8 核；都由 OTP 自动决定。
- ⚠️ **OTP 实测坏核仍保留屏蔽**（补丁只去人为分级/连坐，不动 OTP 单核标记）→ 相对安全；不稳就
  `ROCK5C_UNLOCK=0` 回原厂。
- 在真 **RK3588S2** 上补丁为**空操作**（cpu-code≠0x3582，`ft_system_setup` 直接返回）。

> **GPU**：Panthor 编译为**内核模块**（不是内建），否则会在 `/lib/firmware` 挂载前 probe 导致
> `mali_csffw.bin failed -2`。构建时下载该固件（约 280KB）并写 `/etc/modules-load.d/panthor.conf`，
> 开机挂载根文件系统后再加载 panthor → GPU 正常（`/dev/dri/renderD128`）。
