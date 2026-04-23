# Troubleshooting Guide

按"可能遇到的阶段"排序。

---

## Phase 1: `./build.sh` 装依赖失败

**症状**：`apt-get install` 某个包失败。

**修复**：
```bash
sudo apt-get update
sudo apt-get install -f  # 修复依赖
# 然后继续
./build.sh --deps-only
```

如果是非 Ubuntu 系统，参考 [dependencies.md](./dependencies.md) 手工装。

---

## Phase 2: clone 宿主树慢/失败

**症状**：`git clone SmartRouterZone/mt798x-rebase` 超时。

**修复**：国内云服务器建议给 git 挂个 GitHub 加速器 或者换成 ImmortalWrt 官方 fork：

```bash
HOST_TREE_URL=https://github.com/immortalwrt-mt798x/immortalwrt.git ./build.sh
```

---

## Phase 3: 合 patch 警告 "no 'esac' in $target"

**症状**：`build.sh` 的 `apply_snippet_before_esac` 找不到合适插入点。

**原因**：宿主树的 `board.d/01_leds` 文件结构跟 ChuranNeko 不一样（比如用了多层嵌套 case）。

**修复**：手工合并，打开 `openwrt/target/linux/mediatek/filogic/base-files/etc/board.d/01_leds`，把 `patches/snippets/01_leds.case` 内容粘贴到合适的 case 分支里。

---

## Phase 4: `make defconfig` 警告一堆 package 不存在

**典型信息**：
```
WARNING: Makefile 'package/feeds/packages/adguardhome/Makefile' has a dependency on 'luci-app-openclash', which does not exist
```

**原因**：`filogic.mk` 里的 `DEVICE_PACKAGES` 有在 ImmortalWrt 里找不到的包。

**修复**：打开 `openwrt/target/linux/mediatek/image/filogic.mk`，找到 `Device/glinet_gl-mt3600be` block，删掉找不到的包：
- `adguardhome` → ImmortalWrt 里是 `luci-app-adguardhome`
- `luci-app-openclash` → 需要手动加第三方 feed
- `mt7987-2p5g-phy-firmware` / `kmod-mt7990-firmware` → 可能在 ImmortalWrt 里不存在，需要从 ChuranNeko 源码包移植过来

---

## Phase 5: kernel patch apply 失败

**典型信息**：
```
Applying mt7987.dtsi ... patch doesn't apply
```

**原因**：宿主树的 kernel 版本或 DTS 目录结构跟 ChuranNeko 不一样。

**修复路径**：
1. 先不要 `--with-soc`——如果宿主树已有 MT7987 基础支持，让 `build.sh` 自动跳过。
2. 如果必须注入 SoC support，进 `openwrt/target/linux/mediatek/dts/` 对比差异，手动 rebase。

---

## Phase 6: Wi-Fi 节点绑定报错 (最大坑)

**典型信息**（在 `dmesg` 或 kernel build log 里）：
```
mt7987a-glinet-gl-mt3600be.dts:...: wifi@... compatible "mediatek,mt7990" unsupported
```

**原因**：**这就是标题里那个"第一次大概率编不过"的根本原因**。ChuranNeko 用的是开源 mt76 驱动，DTS 里 wifi 节点用的是 `compatible = "mediatek,mt7990"` 等 mt76 的 binding。ImmortalWrt mt798x-rebase 用闭源 `mtwifi-cfg`，它期待的 compatible 和 reg 区域完全不同。

**修复思路**（需要对照 mt798x-rebase 里现有 MT7987 设备的 DTS 来改）：
1. 去 `openwrt/target/linux/mediatek/dts/` 找形如 `mt7987a-bananapi-bpi-r4-lite.dts` 等 reference board，看它的 wifi 节点怎么写
2. 把 `mt7987a-glinet-gl-mt3600be.dts` 里的 wifi 节点替换成 mtwifi-cfg 风格
3. 注意 EEPROM 偏移、MAC 分配、频段 capabilities 都要保留 MT3600BE 特有的值

这步没有捷径，是真正需要硬核移植的地方。

---

## Phase 7: 编出来了但刷不进 / 刷进去不启动

**症状**：`sysupgrade` 报 "Invalid image" 或设备开机后无法访问 192.168.1.1。

**可能原因**：
- U-Boot 分区表和 DTS 里 `partitions` 节点不一致（分区地址、大小）
- UBI 页大小 / 块大小 不匹配（`UBINIZE_OPTS`, `BLOCKSIZE`, `PAGESIZE`）
- squashfs vs ext4 rootfs 格式选错

**回滚**：按住 reset 开机进 GL.iNet 原厂 U-Boot (http://192.168.1.1)，上传原厂固件恢复。

---

## 通用排错技巧

**查看详细编译错误**：
```bash
cd openwrt
make -j1 V=s 2>&1 | tee ../logs/verbose.log
```

**定位是哪个 package 挂了**：
```bash
grep -E "^(make|ERROR|FAILED|\\*\\*\\*)" logs/verbose.log | head -20
```

**只编单个 package**：
```bash
cd openwrt
make package/mt7990-firmware/{clean,compile} V=s
```

**对比两棵树的文件差异**：
```bash
diff -ruN ~/work/churanneko/target/linux/mediatek/ openwrt/target/linux/mediatek/
```
