# mt3600be-immortalwrt

> **一键在云服务器上为 GL-MT3600BE (Beryl 7) 编译 ImmortalWrt 固件。**
>
> 基于 [SmartRouterZone/mt798x-rebase](https://github.com/SmartRouterZone/mt798x-rebase) 宿主树，叠加从 [ChuranNeko/openwrt-snapshot-gl-mt3600be](https://github.com/ChuranNeko/openwrt-snapshot-gl-mt3600be) 提取的 MT3600BE (MT7987A + MT7990) 设备适配。

---

## ⚠️ 先读这个

**这是一个实验性质的移植工作台，不是开箱即用的成品固件。**

- **第一次 `./build.sh` 大概率编不过** —— ChuranNeko 的 DTS 是为 OpenWrt mainline + 开源 mt76 驱动写的，合到 ImmortalWrt mt798x-rebase (MTK 闭源驱动) 上 Wi-Fi 节点绑定会不匹配、package 依赖会不全。
- **这个仓库的定位**是给你一个可复现的起点，编译失败后能快速定位问题、修改 `patches/`、再次尝试。
- **如果只想尽快刷机**，直接用 [ChuranNeko 的 Release](https://github.com/ChuranNeko/openwrt-snapshot-gl-mt3600be/releases) 就好。

---

## 快速开始（云服务器）

**硬件要求**：Ubuntu 22.04/24.04 LTS，x86_64，≥4C8G，≥50GB 磁盘。

```bash
# 1. Clone
git clone https://github.com/kyya/mt3600be-immortalwrt.git
cd mt3600be-immortalwrt

# 2. 一键全自动（装依赖 → clone 宿主树 → 合 patch → 编译）
#    首次全量编译约 1-2 小时
tmux new -s build   # 强烈建议在 tmux 里跑
./build.sh 2>&1 | tee logs/first-run.log
```

成功后，固件在 `openwrt/bin/targets/mediatek/filogic/*mt3600be*sysupgrade.bin`。

---

## 常用子命令

```bash
./build.sh                 # 完整流水线
./build.sh --deps-only     # 只装构建依赖
./build.sh --apply-only    # clone + 合 patch，不编译（方便先看源码）
./build.sh --menuconfig    # 合完 patch 后开 menuconfig
./build.sh --resume        # 改完代码后继续编（跳过 clone + patch）
./build.sh --clean         # 清空 ./openwrt/ 从头来
./build.sh --jobs 4        # 手动指定 -j 数量
```

---

## 目录结构

```
.
├── build.sh                 # 一键构建入口
├── patches/                 # 从 ChuranNeko 提取的 MT3600BE 适配
│   ├── device-specific/     # 设备专属整文件（3 个）
│   ├── snippets/            # 共享文件中的 case/define 片段（5 个）
│   └── soc-support/         # MT7987 SoC 支撑（可选，仅当宿主树缺失时注入）
├── scripts/
│   └── extract-patches.sh   # 从 ChuranNeko 源码树重新提取 patches 的工具
├── .github/workflows/
│   └── build.yml            # GitHub Actions 云端编译（推 tag 触发）
├── docs/
│   ├── dependencies.md      # 各发行版依赖清单
│   ├── troubleshooting.md   # 常见报错 + 修复思路
│   └── porting-notes.md     # 移植中待解决的技术点
└── logs/                    # 构建日志（运行后生成，已 gitignore）
```

---

## 已知的几个大坑（你会遇到的）

编译失败的可能原因，按概率排序：

1. **Wi-Fi 驱动不匹配** —— ChuranNeko 的 DTS 节点写法适配开源 mt76，但宿主树用闭源 `mtwifi-cfg`。需要改 DTS 的 `wifi` 节点 bindings。
2. **缺包** —— `filogic.mk` 里依赖的 `kmod-mt7990-firmware`、`mt7987-2p5g-phy-firmware`、`adguardhome` 等在 ImmortalWrt 里可能叫别的名字。看 `make defconfig` 警告。
3. **Kernel version 冲突** —— ChuranNeko 用 kernel 6.12，mt798x-rebase 可能在 6.6 或 6.12，需要对齐。
4. **U-Boot 分区表不一致** —— 能编出来但刷不进 / 刷进去启动失败。

遇到问题先看 `docs/troubleshooting.md`，再看 `logs/` 下的日志。

---

## 刷机（编译成功之后）

**强烈建议**先用 GL.iNet 原厂 U-Boot 备一条后路：
1. 断电，按住 reset 通电，U-Boot Web UI 在 `192.168.1.1` ，下载原厂固件先备份好。
2. 再刷编译产物：
   ```bash
   FIRMWARE=openwrt/bin/targets/mediatek/filogic/openwrt-mediatek-filogic-glinet_gl-mt3600be-squashfs-sysupgrade.bin
   scp $FIRMWARE root@192.168.8.1:/tmp/
   ssh root@192.168.8.1 'sysupgrade -T /tmp/$(basename $FIRMWARE)'  # 校验
   ssh root@192.168.8.1 'sysupgrade -n /tmp/$(basename $FIRMWARE)'  # -n 不保留配置
   ```

如果刷进去启动不了，长按 reset 进 U-Boot 刷回原厂即可，**不会真变砖**。

---

## 更新 patches 跟上 ChuranNeko 的改动

```bash
./scripts/extract-patches.sh --output ./patches-new --with-soc --clean
diff -ruN patches/ patches-new/    # 看看 ChuranNeko 改了什么
# 确认无误后
rm -rf patches && mv patches-new patches
git commit -am "sync: update patches from ChuranNeko@<commit>"
```

---

## License

This project is licensed under **GPL-2.0-only**, matching the upstream OpenWrt / ImmortalWrt ecosystem. See the [`COPYING`](./COPYING) file for the full license text.

- `patches/` contents are derived from [ChuranNeko/openwrt-snapshot-gl-mt3600be](https://github.com/ChuranNeko/openwrt-snapshot-gl-mt3600be) and retain their original GPL-2.0 license.
- `build.sh`, `scripts/`, and all other original files in this repo are released under GPL-2.0-only.
- Individual upstream patches under `patches/soc-support/` retain their original authors' copyright notices (MediaTek, Daniel Golle, et al.).

SPDX short identifier: `GPL-2.0-only`

---

## Credits

- [@ChuranNeko](https://github.com/ChuranNeko) — MT3600BE 原始适配
- [SmartRouterZone](https://github.com/SmartRouterZone) — MT7987 kernel patches 整合
- [ImmortalWrt](https://immortalwrt.org) / [OpenWrt](https://openwrt.org) — 基础框架
- GL.iNet 社区和 OpenWrt forum [Beryl 7 讨论帖](https://forum.openwrt.org/t/gl-inet-beryl-7-gl-mt3600be/241924)
