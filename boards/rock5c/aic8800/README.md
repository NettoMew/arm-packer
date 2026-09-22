# AIC8800 USB 主线适配

`0001-aic8800-usb-mainline-port.patch` 应用于 `config/versions.conf` 固定的
Radxa AIC8800 源码；由板级钩子选择，不修改上游 SWUpdate 或内核源码。

- 保留已有 7.1 的 cfg80211、TDLS 结构和 IRQ API 适配。
- 7.2 的 `remain_on_channel` 回调新增 `rx_addr`，用版本条件保留旧签名。
  固件未实现 ROC 地址过滤，不宣告该能力；非空过滤请求返回 `-EOPNOTSUPP`，
  不能用函数指针强转掩盖 ABI 不匹配。
- 固件调试消息使用 `strscpy_pad`，保留定长字段的零填充并保证字符串终止；
  不恢复内核已删除的 `strncpy`，也不关闭相关编译错误。

2026-09-22 已在完整 Linux 7.2.7 配置下真实构建 `aic_load_fw.ko` 和
`aic8800_fdrv.ko`，并检查镜像中的 vermagic 与固件。此记录不是 Wi-Fi 真机连接验证，
也不覆盖其他可选驱动构建配置或 M28K 的 SDIO 驱动。

参考：[7.2.7 cfg80211 接口](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/include/net/cfg80211.h?h=v7.2.7)、
[上游 strncpy 移除说明](https://kernel.googlesource.com/pub/scm/linux/kernel/git/kees/linux/+/refs/tags/strncpy-removal-v7.2-rc1)。
