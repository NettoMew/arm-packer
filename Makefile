# 主线 Alpine 固件构建器 —— 入口
#
# 实际构建逻辑在 scripts/build.sh（引擎模块在 lib/，每块板的 config+hooks 在
# boards/<board>/，内核片段在 kconfig/）。这个 Makefile 只是按板子提供好记的目标，
# 把 BOARD=… 和板级开关设好后调用 scripts/build.sh。等价于 `BOARD=… scripts/build.sh`。
#
# 例：
#   make opiz3                         # Orange Pi Zero 3 (Allwinner H618)
#   make m28k-noscreen                 # MangoPi M28K 无屏版
#   make rock5c ROCK5C_UNLOCK=0        # ROCK 5C 原厂分级（不开核）
#   make e20c SKIP_FETCH=1             # 复用已克隆源码树，迭代更快
#   make opiz3 ROOT_PASSWORD=secret    # 任意 build.sh 开关都可命令行透传
#   make opiz3-dry                     # 只解析配置、打印片段/钩子，不构建
#   make dragon-q8b DISTRO=debian PROFILE=incus   # Incus 主机（见 docs/incus.md）

SHELL := /bin/bash
BUILD := scripts/build.sh

# 命令行赋值（make opiz3 SKIP_FETCH=1）和环境变量（SKIP_FETCH=1 make opiz3）GNU make
# 会自动透传进配方进程，build.sh 直接可见——无需 `export`。
#
# 千万别在这里加 `export`（=.EXPORT_ALL_VARIABLES）：它会经 MAKEFLAGS 传染给内核子 make，
# 逼内核把它成千上万个内部变量塞进每条配方的环境；execve 的 argv+env 上限固定 ~6MB
# （min(RLIMIT_STACK/4, _STK_LIM/4*3)，栈≥24MB 后封顶 6MB，再抬栈也没用），于是内核
# scripts/Makefile.modfinal 连一个几 KB 的 *.mod.o 都 spawn 不出 /bin/sh，报
# “Argument list too long”——约 20 分钟编译后才炸，且只在经本 Makefile 调用时复现
# （直接 `make -C kernel` 不会）。已实测：加 export 必炸，去掉即过。

.DEFAULT_GOAL := help

.PHONY: help all \
        e20c \
        m28k m28k-screen m28k-noscreen \
        rock5c rock5c-stock \
        opiz3 \
        dragon-q8b \
        clean kernel-version kernel-check kernel-build kernel-promote test-kernel test-swupdate test-image test-grow

help:
	@echo '主线 Alpine 固件构建器 —— make <目标>'
	@echo
	@echo '  e20c            Radxa E20C            (RK3528)'
	@echo '  m28k            Widora MangoPi M28K   (RK3528，有屏/含 OLED，= m28k-screen)'
	@echo '  m28k-screen     同上，有屏版          (M28K_OLED=1)'
	@echo '  m28k-noscreen   Widora MangoPi M28K   无屏版 (M28K_OLED=0)'
	@echo '  rock5c          Radxa ROCK 5C         (RK3588S2/RK3582，默认开核)'
	@echo '  rock5c-stock    Radxa ROCK 5C         原厂分级 (ROCK5C_UNLOCK=0)'
	@echo '  opiz3           Orange Pi Zero 3      (Allwinner H618)'
	@echo '  dragon-q8b      Radxa Dragon Q8B      (Qualcomm SC8280XP，UEFI + systemd-boot)'
	@echo
	@echo '  all             依次构建全部板子'
	@echo '  clean           删除 out/ 成品镜像'
	@echo '  kernel-version  显示集中配置的默认内核版本'
	@echo '  kernel-check    独立验证补丁/配置/DTB（BOARD=... KERNEL_REF=vX.Y.Z）'
	@echo '  kernel-build    独立编译候选内核及树外驱动（同上）'
	@echo '  kernel-promote  真机测试后更新默认版本（REPORT=... HARDWARE_TESTED=1）'
	@echo '  test-kernel     离线回归测试（不编译真实内核）'
	@echo '  test-swupdate   更新工具配置/密钥预检回归（不安装）'
	@echo '  test-image      XZ 打包与失败保护回归（不写磁盘设备）'
	@echo '  test-grow       首启扩容 + Incus ZFS 分区实测（需 root；IMAGE=某块 U-Boot 板的 ext4 根镜像）'
	@echo
	@echo
	@echo '发行版（DISTRO，默认 alpine；另有 archlinux / debian / eweos）：DISTRO=debian make <板> 产出 *-debian-*.img.xz'
	@echo '用途（PROFILE，默认 base）：DISTRO=debian PROFILE=incus make <板> 产出 Incus 主机 *-debian-incus-*.img.xz（见 docs/incus.md）'
	@echo '透传开关示例： make rock5c ROCK5C_UNLOCK=0 / DISTRO=archlinux make opiz3 / make opiz3 SKIP_FETCH=1'

e20c:
	BOARD=e20c $(BUILD)

m28k m28k-screen:
	BOARD=m28k M28K_OLED=1 $(BUILD)

m28k-noscreen:
	BOARD=m28k M28K_OLED=0 $(BUILD)

rock5c:
	BOARD=rock5c $(BUILD)

rock5c-stock:
	BOARD=rock5c ROCK5C_UNLOCK=0 $(BUILD)

opiz3:
	BOARD=opiz3 $(BUILD)

dragon-q8b:
	BOARD=dragon-q8b $(BUILD)

# 依次构建每个机型（任一失败即停）。
all: e20c m28k-screen m28k-noscreen rock5c opiz3 dragon-q8b

# make <板>-dry：只解析配置、打印片段与钩子，不构建（秒级，无需联网/sudo）。
%-dry:
	BOARD=$* $(BUILD) --dry-run

kernel-version:
	bash scripts/kernel-update.sh show

kernel-check:
	bash scripts/kernel-update.sh check

kernel-build:
	bash scripts/kernel-update.sh build

kernel-promote:
	bash scripts/kernel-update.sh promote

test-kernel:
	bash scripts/test-kernel-config.sh
	bash scripts/test-kernel-update.sh

test-swupdate:
	bash scripts/test-swupdate-config.sh

test-grow:
	sudo bash scripts/test-grow-rootfs.sh $(IMAGE)

test-image:
	bash scripts/test-image-compression.sh

clean:
	rm -f out/*.img out/*.img.xz out/*.img.xz.sha256 out/*.img.zst out/*.img.zst.sha256 out/*.kernel.tar.xz out/*.kernel.tar.xz.sha256
