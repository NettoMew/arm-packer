# Incus 主机（`PROFILE=incus`）

一块板子，一台 Incus 主机：系统容器、OCI 应用容器、KVM 虚拟机，命令行或 Web UI 管理，全部跑在 ZFS 上。
它不是另一套系统，而是正交的第四根轴 **profile**（“这台机器用来干什么”）叠在 board × distro × fs 之上：
内核按能力合约编、用户态装 Incus、首次开机离线初始化。

```sh
DISTRO=debian PROFILE=incus make dragon-q8b     # 或 make dragon-q8b DISTRO=debian PROFILE=incus
DISTRO=debian PROFILE=incus make rock5c         # 任一板子都行
```

成品 `<板>-debian-incus-<内核版本>.img.xz`，根分区 4G，首启扩容。只支持 Debian（Zabbly 只出 Debian/Ubuntu 包，
ZFS 用户态与 initramfs 也只有 Debian 插件有）；其余发行版在 dry-run 阶段就会被拒绝。

## 组成

```
首次开机   arm-packer-incus-init：ZFS 存储池、incusbr0（NAT）、镜像/备份卷、:8443 API + Web UI
Incus      Zabbly stable（incus 自带 QEMU/edk2/virtiofsd/lxcfs）、incus-ui-canonical、skopeo/umoci（OCI）
Debian     13 trixie，systemd + ifupdown；AppArmor 约束每个实例；生产 sysctl/limits；root 子 ID 1000000:1000000000
存储       ZFS（OpenZFS 2.3.9 随内核编），ARC 上限 = 内存 1/4
内核       主线 + 板级补丁 + 两份能力合约：kconfig/incus.contract、kconfig/dae.contract
```

Zabbly 源的签名密钥随仓库放在 `resources/incus/zabbly.asc`，构建前先核对指纹
（`config/versions.conf` 的 `INCUS_ZABBLY_FINGERPRINT`，与 Zabbly README 公布的一致），不符就停。
频道默认 stable，可 `INCUS_CHANNEL=lts-7.0` 等覆盖。

## 存储：只用 ZFS

Incus 的存储池永远是 ZFS，不提供 `dir` 之类的退路——快照、克隆、配额、`send/recv` 迁移是这台机器的本分。

| 根文件系统 | 首次开机 | Incus 池 |
|---|---|---|
| ZFS（Dragon Q8B 默认） | 根池撑满整盘 | 根池里的数据集 `rpool/incus` |
| ext4（U-Boot 板：U-Boot 从根分区读内核，根只能是 ext4） | 根分区只扩到 8G，余下整块建成分区（GPT 名 `incus`，类型 ZFS / MBR 类型 `bf`）；在上面以本板新生成的 hostid 建池 | 独立池 `incus` |

- 盘小于 16G（8G 根 + 至少 8G 池）时不建分区，`arm-packer-incus-init` 明确失败并说明原因，不会降级。
  `INCUS_ROOT_SIZE` / `INCUS_POOL_MIN` 可在构建时改。
- 池放在另一块盘（SD 做系统、NVMe 做存储，或系统盘不够 16G）：系统盘的根照常扩满；在那块盘上建名为 `incus` 的池，
  再重跑初始化，它见池已存在就直接接着做完（ROCK 5C 实测，见验证记录）：

  ```sh
  d=/dev/disk/by-id/nvme-...                   # 整块盘，里面的东西会被清掉
  wipefs -a ${d}-part* 2>/dev/null; wipefs -a $d
  . /etc/arm-packer/incus.conf; zgenhostid -f
  zpool create -f $(for p in $POOL_PROPERTIES; do printf -- '-o %s ' $p; done) \
    $(for p in $DATASET_PROPERTIES; do printf -- '-O %s ' $p; done) -O mountpoint=none incus $d
  systemctl reset-failed arm-packer-incus-init; systemctl start arm-packer-incus-init
  ```
- 新分区紧接根分区之后、按 1 MiB 对齐，**绝不会**落进根分区前面的空隙（U-Boot 板的引导程序在那里）；
  `make test-grow IMAGE=...` 在 loop 盘上实测 MBR / GPT / 小盘三种情况并逐字节核对引导区。
- 镜像缓存与导出的备份也在池里（`storage.images_volume=default/images`、`storage.backups_volume=default/backups`），
  8G 的根只放系统。
- ARC 默认会占内存的 5/8 甚至“全部减 1G”，每次开机由 `arm-packer-zfs-arc-limit` 设为内存 1/4；
  在 `/etc/modprobe.d/*.conf` 或内核命令行里自己设了 `zfs_arc_max` 就以你的为准。

## 首次开机

`arm-packer-incus-init.service` 只跑一次（标记 `/var/lib/incus/.arm-packer-initialized`），完全离线；失败不留标记，
下次开机重试。看结果：

```sh
systemctl status arm-packer-incus-init
incus storage list; incus network list; incus profile show default
```

默认 profile：根盘在 `default` 池，`eth0` 接 `incusbr0`（IPv4/IPv6 NAT）。

`incusbr0` 的网段由本板的 `machine-id` 推出（`10.x.y.1/24` 与 `fd42:…::1/64`）：每块板不同、重跑不变、完全不碰网络，
只避开本机已有地址/路由占用的网段。Incus 自己的 `auto` 会对候选网段 ping 并发起 TCP 连接、有回应就当“已占用”，
上游若是对所有连接都应答的透明代理，100 个候选全被判占用、初始化失败（QEMU 测试里实际踩到）。想换网段：
`incus network set incusbr0 ipv4.address=<cidr>`。

## 使用

**Web UI**：浏览器开 `https://<板子IP>:8443`。只服务受信任的客户端：按页面提示生成浏览器证书，或在板子上

```sh
incus config trust add my-laptop        # 打印一次性 token，粘进 UI
```

**容器 / 虚拟机 / OCI**：

```sh
incus launch images:debian/13 c1                 # 系统容器
incus launch images:debian/13 v1 --vm            # KVM 虚拟机（Q8B 跑在 EL2 实测；其余板子内核同样启用 KVM）
incus remote add docker https://docker.io --protocol=oci
incus launch docker:nginx web                    # OCI 应用容器
```

`images:` 是 Incus 预置的官方镜像服务器（images.linuxcontainers.org），国内实测可直接用。TUNA / BFSU 也有
`lxc-images` 镜像，但 2026-10-04 实测它们的 simplestreams 索引是空的（全零字节），Incus 会报
`Failed decoding stream JSON`；恢复后可这样加：

```sh
incus remote add tuna https://mirrors.tuna.tsinghua.edu.cn/lxc-images/ --protocol=simplestreams --public
```

## 让实例直接上局域网：自己建 br0

镜像默认不改宿主网络。想让实例从路由器拿局域网地址，在宿主上把一个有线口桥起来（以 eth0 为例，ROCK 5C 实测）：

```sh
apt install bridge-utils          # /etc/default/bridge-utils 保持 BRIDGE_HOTPLUG=no
```

**不要开 `BRIDGE_HOTPLUG=yes`**：它让 udev 在网卡出现时自己 `ifup br0`，而 udev 环境里的 dhcpcd 做不了 chroot
（`ps_dropprivs: chroot: Operation not permitted`），拿不到地址；networking.service 随后又把 br0 当成已经起好而跳过，
开机后 br0 只有 169.254 的地址。手动 `ifup` 时一切正常，只有重启才暴露。

`/etc/network/interfaces` 里把 `allow-hotplug eth0` / `iface eth0 inet dhcp` 换成：

```
iface eth0 inet manual

auto br0
iface br0 inet dhcp
	bridge_ports eth0
	bridge_hw eth0
	bridge_stp off
	bridge_fd 0
```

`bridge_hw eth0` 让网桥沿用 eth0 的 MAC，路由器上的 DHCP 保留地址不变（否则 systemd 会给网桥另生成一个 MAC）。
网卡出现得晚的板子（如 Dragon Q8B 的 TC956x，PCIe 后面、模块驱动）再加一行 `bridge_waitport 30 eth0`，让 br0 等它。
远程改网络时先留好退路：把切换写成脱离 SSH 的脚本，切完等确认、超时就恢复原配置。没有串口的板子可以再加一个开机检查：
br0 一段时间拿不到 IPv4 就重新 `ifup` 一次，仍不行**只记日志、不改配置**。开机时分不清是 br0 配坏了，还是路由器起得比板子慢、
网线没插好；自动改回旧配置会把 br0 连同所有实例的网络一起拿掉，而且重启也回不来。dhcpcd 会在后台继续请求，
IPv6 link-local（`fe80::…%接口`）在 br0 没拿到 IPv4 时也能连，旧配置留一份备份，需要时手动恢复。

然后让实例接到 br0。所有实例都上局域网：改 default profile，NAT 留作可选的 `nat` profile：

```sh
incus profile device remove default eth0
incus profile device add default eth0 nic nictype=bridged parent=br0 name=eth0
incus profile create nat
incus profile device add nat eth0 nic network=incusbr0 name=eth0     # incus launch … -p default -p nat
```

只想让部分实例上局域网，就反过来：default 不动，另建一个 `nictype=bridged parent=br0` 的 `lan` profile。

Wi-Fi 口不能当桥接口（802.11 客户端模式的限制）。Dragon Q8B 的 2.5G 口另见 [dragon-q8b.md](dragon-q8b.md)：
容器 `phys` 直通安全且原生速度；KVM 直通要开机就交给 vfio。

## 以后自己加的组件

内核都已备好（写在合约里，任何片段改动都破不了），装用户态即可：

| 组件 | 安装 |
|---|---|
| OVN 多机组网 | `apt install ovn-host ovn-central openvswitch-switch` |
| Ceph RBD / CephFS 存储 | `apt install ceph-common` |
| 集群 | Incus 自带：`incus cluster enable <名字>` |
| incus-extra（`lxd-to-incus`、`incus-migrate` 等） | `apt install incus-extra`（Zabbly 源已配好） |
| btrfs / lvm 存储驱动 | `apt install btrfs-progs` / `apt install lvm2 thin-provisioning-tools` |

## 内核：能力合约

profile 声明它依赖的内核能力，写成 `kconfig/<名>.contract`。合约既是请求也是门禁（`lib/kernel.sh`）：

1. **请求**：紧跟 distro 基线合并、在所有板级/特性片段之前（板子仍可把合约要的模块编成内建）。
   `=m` 的意思是“至少是模块”，所以合并时绝不会把前面已内建的符号降成模块。
2. **门禁**：`olddefconfig` 定型后逐条核对最终 `.config`——`=y` 必须内建、`=m` 模块或内建、
   `# … is not set` 必须关、带引号的值逐字相等；无法解析的行也算违约，笔误不会悄悄漏检。
   任一不符即停，并列出“要的值 / 实际的值”。`SKIP_BUILD=1` 复用旧内核时同样核对（那份内核可能是 base 编的）。
3. **BTF 不变式**（与 profile 无关，每次构建都查）：`.config` 有 `DEBUG_INFO_BTF=y`，vmlinux 就必须真有非空 `.BTF` 段
   （开了 `DEBUG_INFO_BTF_MODULES` 还查模块）。pahole 缺失或太旧时 kbuild 会静默丢掉 BTF，这里把它变成构建失败。

| 合约 | 内容 |
|---|---|
| `incus.contract` | cgroup v2 全部控制器（含 misc）与 namespace、seccomp、AIO、CRIU；AppArmor 及其在 `CONFIG_LSM` 中的位置；overlay/squashfs(xz,zstd)/btrfs/dm-thin/loop/nbd/iso9660、Ceph；KVM、vhost-net/vsock、tun/tap/macvtap、userfaultfd、hugetlb/THP、VFIO；bridge(VLAN 过滤)/veth/macvlan/ipvlan/vxlan/geneve/OVS(+ct)、nftables(inet/bridge/NAT/fib)、HTB/ingress/u32/police |
| `dae.contract` | vyos-rockchip 实测通过的 dae 合约（BPF/JIT、cgroup BPF、tc clsact 的 ingress/egress 与 `cls_bpf`、策略路由、kprobe、完整 DWARF → BTF，覆盖 dae 官方要求的全部选项），另加 `NETKIT`：6.7+ 内核上 dae v2 把自己的网络空间接在 netkit 设备对上，缺它就退回 veth“兼容模式” |

与 base 相比，Q8B 的 incus 内核只多五处：AppArmor（并进入 LSM 顺序）、`CGROUP_MISC`、`USERFAULTFD`、`SQUASHFS_ZSTD`、`NETKIT`；
其余能力 base 内核本来就有，合约把它们锁住。五块板子的 Debian + incus 配置都满足两份合约。

## dae

内核完整支持（`dae.contract`），镜像不装 dae。dae 只读 vmlinux 的 BTF（tc 程序的上下文是 UAPI 的 `__sk_buff`），
所以不要求模块 BTF；netkit 编进内核，dae v2 走它的首选路径而不是 veth 兼容模式。

真机验证的做法（不碰真实上行口，也不打断 SSH）：WAN 是一条通往独立网络空间的 veth，LAN 是 `incusbr0`；
路由写 `dip(223.5.5.5) -> block` 加 `fallback: direct`。dae 运行时容器连 223.5.5.5:443 被拦、连 223.6.6.6:443 直连通过，
dae 退出后 223.5.5.5 恢复——证明流量确实经过 dae 的 eBPF 数据面，且卸载干净。dae v2 用 tcx（基于 link 的 BPF 挂载），
`tc filter show` 看不到它的程序，别拿它当判据；也别用 53 端口测，dae 先把 DNS 拿去自己处理、不走路由规则。

## 验证记录

2026-10-04，Linux 7.2.7（#40）、Incus 7.5.1、OpenZFS 2.3.9、dae v2.1.1。

**离线**（`make test-kernel`、`make test-grow`）：全部板子 × 发行版 × incus 的 dry-run 矩阵与合约语义单测通过；
5 块板子 Debian + incus 的真实 `.config` 都满足两份合约；首启分区在 loop 盘上实测 MBR / GPT / 小盘，引导区逐字节不变。

**构建与审计**（Dragon Q8B，`ssh andy`）：板级审计（分区、ESP、systemd-boot、DTB、固件、模块、initramfs）与 profile
审计（两份合约、vmlinux BTF 10.3 MB、Zabbly 钉死的密钥与源、首启单元与配置、构建期不留 Incus 状态）通过。镜像根数据集
503 MB（zstd 3.55×），其中 `/opt/incus` 164 MB。

**QEMU virt（TCG，UEFI）**：两条存储路径都从 edk2 → systemd-boot → 首启跑到底，并真的起了一个容器——

| | ZFS 根（Q8B 默认） | ext4 根（U-Boot 板的路径） |
|---|---|---|
| 首启扩容 | 根池 23.8G | 根停在 8G，`/dev/vda3` 16G 建成 `incus` 分区 |
| Incus 池 | `rpool/incus` | 独立池 `incus`（本板新 hostid） |
| 容器 | Debian 13 RUNNING，uid 映射 1000000，进程受 `incus-c1` AppArmor 配置约束（enforce），快照与 ZFS 克隆 | 同左 |
| 其余 | 无失败单元、无 ordering cycle、UI 标题 “Incus UI”、ARC = 内存 1/4 | 同左 |

**真机**（Dragon Q8B，NVMe，以新的 ZFS 启动环境 `rpool/ROOT/debian-incus` 安装、全新首启，23 项全过）：

| 项目 | 结果 |
|---|---|
| 首启 | `arm-packer-incus-init` 成功；无失败单元、无 ordering cycle；ARC 上限 1832 MiB（7.3G 的 1/4） |
| 内核 | AppArmor 在 LSM 中（103 个配置加载）；`/sys/kernel/btf/vmlinux` 10.6 MB；`/dev/kvm` |
| 存储 | 池 `rpool/incus`、镜像/备份卷在池里；快照 + ZFS CoW 克隆 |
| Web UI | 本机与局域网两个口（eth1、wlan0）都返回 “Incus UI”；未受信客户端只得到 `untrusted` |
| 系统容器 | Debian 13，14 s 起好；非特权 uid 映射 0→1000000；AppArmor enforce；cgroup 限额（256 MiB / 2 核）生效 |
| KVM 虚拟机 | Debian 13 VM 17 s 起好，`systemd-detect-virt` = kvm |
| OCI | `docker:nginx:alpine` 13 s 起好，宿主取到 “Welcome to nginx!” |
| dae | eBPF 程序与 map 加载；netkit 设备对（performance mode）+ `bpf_redirect_peer()`；被 `block` 的 223.5.5.5:443 在 dae 运行时不通、223.6.6.6:443 直连通过，dae 退出后恢复 |

过程中抓到并修掉的问题（都已进代码与测试）：首启数据分区会落进根分区前的空隙（`make test-grow`）；Incus 的 `auto`
网段探测遇到全应答的透明代理会失败（改由 machine-id 推网段）；ARC 单元与首启扩容成环（改为早期单元，测试 grep
`ordering cycle`）；ext4 根装 zfsutils 时没有 `contrib`（改由 `distro_install_zfs` 按需添加）；内核缺 netkit 时 dae 退回
veth 兼容模式（合约加 `NETKIT`）。

真机上原来的系统 `rpool/ROOT/debian` 仍在，systemd-boot 菜单里可选；Incus 系统的 `@image` 快照是出厂状态。

### 内核更新到 7.2.9（2026-10-04）

按 [内核更新流程](kernel-updates.md) 走，范围 dragon-q8b / debian / incus：

1. `kernel-check v7.2.9`：79 个补丁套上（0037 已删：同样的守卫 7.2.8 以 `5e97d117b79c` 进了 stable），两份合约满足，DTB 编过。
2. `kernel-build v7.2.9`：全新工作区完整编译内核与 OpenZFS 2.3.9，vmlinux 带 BTF，报告 commit `5fce1616`。
3. 候选整盘镜像（普通工作区）：板级与 profile 审计、QEMU 首启起容器都通过。
4. 真机：在运行中的 Incus 系统上做 ZFS 启动环境式升级——快照并克隆出 `rpool/ROOT/debian-incus-7.2.9`
   （只多 89 MB 新模块），装入候选镜像的内核与模块，在克隆里用本板 hostid 重做 initramfs，加一条带启动计数的
   启动项。Incus 的数据库随根克隆、存储池 `rpool/incus` 两个系统共用，所以升级后实例、网络、存储原样还在。
   新内核起不来时，三次失败后 systemd-boot 自动退回 7.2.7。
5. 7.2.9 上 23 项全过（dae 同样是 netkit 性能模式）；ADSP/CDSP、风扇、GPU、Iris、2.5G、Wi-Fi、蓝牙、声卡正常，
   内核 err 级日志 0 条；重启回归通过。
6. `kernel-promote --tested`：`config/versions.conf` 改为 v7.2.9。

升级后的启动菜单：`arm-packer-incus*` 两条（7.2.9 优先，7.2.7 留作退路）与最早的 `arm-packer-7.2.7`。
`loader.conf` 用 `default arm-packer-incus*`：同 sort-key 时版本新的排前，带计数的新启动项失败三次就排到最后，
以后再升内核照这个办法加一条即可。

### ROCK 5C（2026-10-04）

`DISTRO=debian PROFILE=incus make rock5c`（Linux 7.2.9、RK3582 开核）：内核满足两份合约、vmlinux 带 BTF，OpenZFS 2.3.9
随 RK3588 内核编出；通用 Debian 审计与 Incus 审计通过（ext4 根约 4G、ZFS 模块与 zfsutils、没有 zfs-initramfs/initramfs、
首启分区配置）。QEMU virt 上用这块板自己的内核起镜像的根、盘比镜像大 20G：根分区停在 8G、`vda2` 建成 `incus` 分区
（GPT 名 `incus`、ZFS 类型）并建池，`arm-packer-incus-init` 成功，Web UI、容器、快照与 ZFS 克隆正常，无失败单元、
无 ordering cycle；**U-Boot 所在的扇区（34 到根分区）首启前后逐字节不变**。

实机（ROCK 5C，RK3582 开 7 核、4G 内存，14.6G SD 做系统盘，NVMe E2M2 64GB 做存储）：SD 不够 16G，首启按设计把根扩满
整张卡、不建分区，`arm-packer-incus-init` 拒绝初始化并写明原因；在 NVMe 上按上面的做法建池 `incus` 后重跑初始化即成功。
重启后池自动导入、`incusbr0` 与 :8443 正常、ARC 上限 971 MiB（内存 1/4），容器（Debian 13）101 s 起好（含下载镜像），
非特权 uid 映射 0→1000000，数据落在 NVMe 的池里；无失败单元。
