# SWUpdate：ROCK5C 首个测试镜像

## 当前交付边界

采用上游 SWUpdate，不实现私有更新包格式、验签器或解包器。首先验证
**ROCK5C + Alpine + 项目固定内核 + AIC8800 USB 驱动 + SWUpdate** 的可安装镜像。
用户先烧录镜像、确认硬件启动，再进入内核更新试验。

本阶段是**更新基础组件集成**，不是已完成的设备端内核更新器：

- SWUpdate 固定 commit / 源码 SHA-512；版本在 `config/versions.conf`。
- `config/swupdate.fragment` 开启强制 RSA-PSS 签名、SHA-256、硬件版本检查，
  只启用 archive / shellscript 安装处理器。
- 不启用 Web 服务、下载守护进程、raw/MTD 写盘处理器或持久化 U-Boot 环境访问。
- 使用发行版原生 APK 管理运行库；当前只实现 Alpine 包后端，不宣称 Arch/eweOS 已验证。
- 新镜像仅安装公共验证密钥，不安装任何 SWU/APK 私钥。
- 尚无 `kernel install/rollback` 命令，也没有自动启动失败回滚。不要用临时 shell 脚本直接覆盖 `/boot/Image`。

## 1. 构建上游 APK

在**可丢弃的 Alpine aarch64 容器**中执行，不能在已安装的测试板上执行此构建脚本：

```sh
# 例如 ARM64 Linux 的 Docker；项目只读，结果写入独立空目录。
mkdir -p out/swupdate-apks
docker run --rm --platform linux/arm64 \
  -e ARM_PACKER_DISPOSABLE_BUILDER=1 -e JOBS=4 \
  -v "$PWD:/project:ro" -v "$PWD/out/swupdate-apks:/output" \
  alpine:3.24.2 sh /project/scripts/build-swupdate-apks.sh /output
```

脚本使用上游 `abuild` 构建 libubootenv 和 SWUpdate，随后运行真实 SWUpdate 的
临时目录试验：只校验不安装、错误密钥、错误硬件版本、篡改 payload、无签名、
preinstall 失败，以及正常 archive 安装和 hook 顺序。**试验载荷是假文件，不是内核。**
不接触 `/boot`、块设备或已有服务。

输出两个 APK、APK 仓库公钥、`SHA256SUMS`、构建身份、依赖包清单及对应的源码/构建配方。构建 APK 的临时签名密钥
与设备更新信任密钥分开；只有公钥输出。原始源码由 APKBUILD 中的固定 commit 和
SHA-512 定位，不打补丁改写上游安装器。若构建机无法访问 GitHub，可把经过 SHA-512
验证的 `swupdate-<版本>.tar.gz`、`libubootenv-<版本>.tar.gz` 放进容器内目录，
通过 `SWUPDATE_SOURCE_CACHE=/path` 指定；abuild 仍执行固定摘要校验。

## 2. 更新签名密钥

生产私钥应离线保管；测试可在单独受保护目录生成一把专用密钥：

```sh
umask 077
mkdir -p work/swupdate-keys
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -out work/swupdate-keys/test-private.pem
openssl pkey -in work/swupdate-keys/test-private.pem -pubout \
  -out work/swupdate-keys/test-public.pem
```

不要覆盖已投入使用的私钥。上面生成的是测试信任根，不适合直接随公开发行镜像发布。
APK 仓库签名保证包安装真实性；SWU 签名保证更新包真实性，两者不是一套密钥。

## 3. 构建测试镜像

```sh
make rock5c DISTRO=alpine ENABLE_SWUPDATE=1 \
  SWUPDATE_PACKAGE_DIR="$PWD/out/swupdate-apks" \
  SWUPDATE_PUBLIC_KEY="$PWD/work/swupdate-keys/test-public.pem"
```

SWUpdate 显式 opt-in；缺少包/公钥、给入私钥或使用未实现的发行版后端，构建立即失败。
镜像生成期间会执行目标 `swupdate -h`，动态库缺失不能留到首次更新才发现。
普通镜像和仅内核验证不强制引入此功能。

设备身份在 `/etc/arm-packer/hwrevision`，ROCK5C/Alpine 为
`rock5c rock5c-alpine-v1`；`v1` 表示我们定义的更新布局协议，不是声称检测到了硬件修订版。
验证配置在 `/etc/arm-packer/swupdate.cfg`，公钥在同目录。
镜像同时保留 `/usr/share/arm-packer/apk` 签名本地仓库，便于重新安装更新工具，
无需关闭 APK 签名检查或使用 `--force-non-repository`。

## 4. 镜像安装后的验证

先使用备用 SD 卡，不覆盖唯一可启动系统。确认串口、根分区、网口、USB、NVMe、
GPU、Wi-Fi 和重启；记录 `uname -r`、`swupdate -h` 及启动日志。
镜像构建/容器内验签通过不等于真机测试通过。

## 后续内核更新适配（尚未实现）

1. 每个构建使用唯一 `kernelrelease`，隔离同一上游版本不同配置的 modules。
2. 一个签名 SWU 包含 Image、板级 DTB、配套 modules、必要固件及构建身份。
3. 上游 archive handler 安装到新版本目录，不覆盖活动内核/模块；处理固件共存约束。
4. 完整验证、持久化后最后切换 extlinux 入口，保留旧版本及旧启动参数。
5. 旧系统首次接入必须校验布局，不接受任意发行版/任意 U-Boot 都可无条件更新的假设。
6. 启动尝试计数、成功确认和自动回滚另行集成验证，不能把单文件 rename 当作整个事务。

参考：[上游签名机制](https://sbabic.github.io/swupdate/signed_images.html)、
[安装处理器](https://sbabic.github.io/swupdate/handlers.html)、
[单文件 atomic-install 的边界](https://sbabic.github.io/swupdate/sw-description.html#files)。
