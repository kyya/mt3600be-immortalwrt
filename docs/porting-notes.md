# Porting Notes

这份文档记录移植过程中**已知但还没解决**的技术点，是未来的 PR/commit 待办清单。

---

## 硬件规格（基于 ChuranNeko 源码和 OpenWrt forum 信息）

| 项 | 值 |
|---|---|
| SoC | MediaTek MT7987A (quad-core ARM Cortex-A53 @ 2.0GHz) |
| Wi-Fi | MediaTek MT7990 (Wi-Fi 7, 2×2 2.4GHz + 2×2 5GHz) |
| 2.5G PHY | 内建（MT7987A 集成）+ 外挂一颗，需要 `mt7987-2p5g-phy-firmware` |
| RAM | 512MB DDR4 |
| Flash | 512MB NAND |
| USB | 1× USB 3.0（带独立 GPIO 供电开关） |

> ⚠️ **未验证项**：MT7987A 和 MT7990 的具体型号目前仅从 ChuranNeko DTS 文件名和 filogic.mk 的包依赖推断，未拆机确认。建议拿到设备后 `cat /proc/cpuinfo` + `dmesg | grep -i wifi` 核实。

---

## 已知差异：ChuranNeko vs ImmortalWrt mt798x-rebase

| 方面 | ChuranNeko | mt798x-rebase |
|---|---|---|
| 基线 | OpenWrt main snapshot | ImmortalWrt + MTK feeds |
| 内核 | 6.12 | 可能 6.6 或 6.12 |
| Wi-Fi 驱动 | mt76 (开源) | mtwifi-cfg (闭源 blob) |
| Userspace tools | OpenWrt stock | ImmortalWrt 定制 (luci-app-argon 等) |
| 包管理 | apk + opkg | opkg 为主 |

---

## 必须解决才能编过的项

### 1. Wi-Fi 节点 binding 重写（最大工作量）

`patches/device-specific/target/linux/mediatek/dts/mt7987a-glinet-gl-mt3600be.dts` 里的 wifi 节点是 mt76 风格，需要改成 mtwifi-cfg 风格。

参考：对比宿主树里 MT7987 的 reference board DTS，比如：
- `target/linux/mediatek/dts/mt7987a-bananapi-bpi-r4-lite.dts`
- `target/linux/mediatek/dts/mt7987a-rfb-*.dtso`

改动重点：
- `compatible` 字符串
- `reg` 地址范围（MTK 驱动要求的 MMIO 映射）
- `mediatek,mtd-eeprom` 偏移量（需要核对 GL-iNet 原厂 factory 分区的 EEPROM 存放位置）

### 2. Firmware 包名对齐

`image/filogic.mk` 里列了这些包，需要验证在 ImmortalWrt 里的真实名字：

| 原包名 | 可能的 ImmortalWrt 名字 | 状态 |
|---|---|---|
| `mt7987-2p5g-phy-firmware` | 同名？需确认 | ❓ |
| `kmod-mt7990-firmware` | 可能需要从源码移植 | ❓ |
| `adguardhome` | `luci-app-adguardhome` | 可改 |
| `luci-app-openclash` | 需要第三方 feed | 可删 |
| `luci-theme-argon` | 可用 | ✅ |

### 3. Kernel patches 对齐

`patches/soc-support/kernel-patches/739-03-net-pcs-pcs-mtk-lynxi-...MT7988.patch` 目前放 `pending-6.12/`，但宿主树如果用 6.6 内核要改放别处，或者换个版本的 patch。

---

## 可延后的项

- **风扇 PWM 曲线**：ChuranNeko 的脚本硬编码了 0/96/160/224/255 的曲线，PWM IO 在 MT3600BE 上的 GPIO 映射要核对。
- **GL-iNet 原厂 LuCI UI 兼容**：原厂那套 UI 跑在 OpenWrt 21.02 上，ImmortalWrt 版本过高会不兼容——不解决也能用 LuCI 管理，只是没有 GL-iNet 特色面板。
- **USB 供电 GPIO 路径**：`init.d/turn_on_usb_power` 里写死了 `/sys/class/gpio/usb_power/value`，如果 ImmortalWrt kernel 用了 libgpiod 新式 API 可能路径变了。

---

## 验证清单（首次刷机后）

编译成功且刷进去后，按这个顺序验证硬件功能：

- [ ] 开机，LED (power/system) 正常
- [ ] `dmesg` 无 kernel panic
- [ ] `cat /proc/cpuinfo` 看到 4 核 ARM
- [ ] `ip link` 能看到 eth0, eth1 两个 2.5G 口
- [ ] 以 LAN 模式接 PC，能 DHCP 到 IP
- [ ] `logread | grep -i wifi` 无错误
- [ ] 2.4G Wi-Fi 能开（`uci set wireless.radio0.disabled=0`）
- [ ] 5G Wi-Fi 能开
- [ ] USB 插 U 盘，`lsusb` + `lsblk` 能识别
- [ ] VPN (WireGuard) 吞吐测试
- [ ] 温度正常（`cat /sys/class/thermal/thermal_zone*/temp`）

---

## 贡献回上游的路径

编译跑通且硬件验证通过后，理想的终极归宿是：

1. 把设备适配提 PR 到 [immortalwrt/immortalwrt](https://github.com/immortalwrt/immortalwrt)
2. 同时提 PR 到 [openwrt/openwrt](https://github.com/openwrt/openwrt) mainline
3. 跟进 [OpenWrt forum 讨论帖](https://forum.openwrt.org/t/gl-inet-beryl-7-gl-mt3600be/241924) 告知进展
4. 一旦进 upstream，这个 fork 就不需要维护了 🎉
