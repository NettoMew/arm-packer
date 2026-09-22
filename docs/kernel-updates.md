# 内核更新流程

**显式选择候选版本 → 检查补丁/配置/设备树 → 编译内核和驱动 → 真机测试 → 更新默认版本。**
普通构建不会查询或追随 `latest`，也不会自动修改默认版本。

本页是**构建端版本验证**。设备端更新采用 SWUpdate 的方向与首个 ROCK5C 测试镜像，
见 [SWUpdate 集成](swupdate.md)；两者不是同一个命令，当前尚未实现内核在线切换。

## 1. 唯一默认版本入口

共享源码的默认仓库与版本在 [`config/versions.conf`](../config/versions.conf)：

- `DEFAULT_KERNEL_REPO` / `DEFAULT_KERNEL_REF`：固定 Linux release 标签。
- U-Boot、rkbin、ATF、AIC8800 的共享源码默认值也放在这里；保留原有值，**不代表整个引导链都已锁定**。
- 板级例外仍由 `boards/<board>/board.conf` 管理，不进入通用更新引擎。
- 优先级：命令行/环境覆盖 → 板级默认 → 集中默认。

查看默认内核：

```sh
make kernel-version
# 无 make 时：bash scripts/kernel-update.sh show
```

普通构建仍接受 `KERNEL_REPO` / `KERNEL_REF` 覆盖。文档里的版本号只是示例；测试从集中配置读取默认值，
以后升级不需要修改测试中的版本常量。

## 2. 显式选择并检查候选版本

下面的 `vX.Y.Z` 必须替换为实际存在的正式发布标签；板子/发行版也按需替换。
独立更新入口只接受 `vX.Y` 或 `vX.Y.Z`，拒绝 `master`、`latest`、RC 和任意分支。
实验分支仍可通过普通 `scripts/build.sh` 使用。

```sh
make kernel-check BOARD=m28k DISTRO=alpine KERNEL_REF=vX.Y.Z

# 等价入口；末尾加 --dry-run 只解析配置，不联网、不创建工作区
BOARD=m28k DISTRO=alpine bash scripts/kernel-update.sh check vX.Y.Z
```

`kernel-check` 会：

1. 在 `work/kernel-validation/<板>-<发行版>-<标签>.<随机后缀>/` 创建**全新独立工作区**。
2. 拉取指定标签，检查 Git commit 与内核 `kernelversion`。
3. 应用板级内核补丁、注入设备树，并准备/打补丁树外驱动源码。
4. 用正常构建的 defconfig + fragments 生成 `.config`，编译选定的 DTB。
5. 成功后写出 `validation.txt` 与 `validation.log`。

**这不是完整内核编译，也不是硬件测试；check 报告不能用于更新默认版本。**
Kconfig 仍沿用正常构建的 `olddefconfig` 处理方式，未知/被依赖禁用的配置可能被丢弃，
需要查看日志和最终 `.config`，尤其是启动驱动与网络功能。

## 3. 完整编译候选内核和驱动

```sh
make kernel-build BOARD=m28k DISTRO=alpine KERNEL_REF=vX.Y.Z
# 或：BOARD=m28k bash scripts/kernel-update.sh build vX.Y.Z
```

同样使用新的独立工作区，但会进一步编译 `Image`、DTB、内核模块及板级树外驱动（如 AIC8800）。
任一步骤失败就停止，**失败不会产生成功报告，也不会改变默认版本**。

- 内核产物：`<工作区>/build/linux-build/`。
- 树外驱动源码/模块：`<工作区>/src/aic8800/`（有该驱动的板子）。
- 成功报告：`<工作区>/validation.txt`；记录标签、commit、板子/发行版、主要内核功能开关、输入与产物摘要。
- 可用 `KERNEL_VALIDATION_ROOT=/path/to/disk` 更改验证根目录；每次仍新建子目录。
- 普通 `WORKSPACE`、`CLEAN_WORKSPACE`、`CLEAN_KERNEL`、`AIC8800_DIR` 不会让验证复用或清理旧工作区。
- `SKIP_FETCH=1` / `SKIP_BUILD=1` 会被拒绝。`kernel-build` 不受 `STOP_AFTER_KCONFIG=1` 的跳过影响。
- 不更新/编译 U-Boot、rkbin、ATF，不准备 rootfs，不挂载、不生成镜像、不刷盘，**不运行 sudo，也不自动安装依赖**。
  需在 Linux 构建机预先安装交叉工具链与构建依赖；依赖缺失会立即报错。

验证目录与失败日志保留供排查，可能占较大磁盘空间。确认不再需要报告/产物后再手动清理。

## 4. 真机验证（人工步骤）

脚本只能证明软件阶段完成，**无法判断你是否真的做了真机测试**。
应对发布范围内的板子/发行版逐个编译、测试；一个报告只代表其中一个组合，不代表全板兼容。

可在另一个工作区，按相同的内核仓库、标签、板子、发行版与功能开关构建候选整盘镜像：

```sh
make m28k KERNEL_REF=vX.Y.Z DISTRO=alpine \
  WORKSPACE="$PWD/work/candidate-image-m28k" \
  OUTPUT_DIR="$PWD/out/candidate" SKIP_FETCH=0 SKIP_BUILD=0 CLEAN_KERNEL=1
```

若验证时覆盖了 `KERNEL_REPO`、Kconfig 或驱动设置，镜像构建也必须使用相同覆盖值。
完整镜像流程仍按正常规则处理 U-Boot 等依赖，不属于“仅内核验证”；需要固定引导链时显式指定其 ref。
不要把报告目录作为整盘镜像工作区使用，否则产物被重编/更改后报告会失效。

在备用介质上测试并保留可启动旧系统：串口启动、根分区、网口、USB、存储、GPU、Wi-Fi/树外模块及重启。
当前没有设备端在线更新或自动回滚功能；刷整盘镜像会覆盖目标介质。

## 5. 测试通过后更新默认值

```sh
bash scripts/kernel-update.sh promote \
  work/kernel-validation/<本次成功构建目录>/validation.txt --tested

# 等价 make 入口
make kernel-promote REPORT=/path/to/validation.txt HARDWARE_TESTED=1
```

`--tested` / `HARDWARE_TESTED=1` 是操作者明确声明已完成真机测试，不是脚本自动出具的证明。
更新前会检查：

- 报告必须来自成功的 `kernel-build`，不能是 dry-run/check。
- 配置、引擎、板级资源/补丁等仓库构建输入没有变动。
- 报告旁的 Image、DTB、`.config` 仍存在且摘要匹配。
- 远端 release 标签仍指向构建时的 commit。

任何检查失败都不改默认值。全部通过后，**仅原子更新 `config/versions.conf` 中内核仓库与标签两行**；
不会写入报告里以外的 shell 代码，不自动提交 Git，不修改 bootloader 默认值。
报告是本地工作流记录，不是签名的供应链证明；它不记录或替代人工的真机测试结论。

```sh
git diff -- config/versions.conf
make kernel-version
make test-kernel
```

默认值变动后旧报告的输入摘要会失效。保留 Git 中的版本配置与测试记录，回退时显式选用先前的发布标签。

## 回归测试

`make test-kernel` 检查全部板子/发行版默认值、覆盖优先级、原构建钩子顺序以及更新流程的失败保护。
更新流程集成测试使用本地 Git 仓库与**模拟编译器产物**，不联网；它不是 Linux 编译或启动验证。
