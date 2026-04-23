#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# extract-mt3600be-patches.sh
#
# 从 ChuranNeko/openwrt-snapshot-gl-mt3600be 源码树提取
# GL-MT3600BE（MT7987A + MT7990）设备适配增量，输出成结构化 patch 集。
#
# Usage:
#   ./extract-mt3600be-patches.sh --source /path/to/churanneko --output ./patches
#   ./extract-mt3600be-patches.sh --source-url https://github.com/ChuranNeko/openwrt-snapshot-gl-mt3600be.git \
#                                 --output ./patches --with-soc
#
# Author: scaffolded with AI assistance / crafted 2026

set -euo pipefail

# ---------- 全局常量 ----------
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_KEY="gl-mt3600be"
DEVICE_BOARD_NAME="glinet,gl-mt3600be"
DEVICE_DEFINE_KEY="glinet_gl-mt3600be"

# 设备专属文件（直接拷贝，整文件为设备服务）
DEVICE_FILES=(
  "configs/mt3600be.seed"
  "target/linux/mediatek/dts/mt7987a-glinet-gl-mt3600be.dts"
  "target/linux/mediatek/filogic/base-files/etc/uci-defaults/99-gl-mt3600be-defaults"
)

# 混合文件（多设备共享，需提取 case/define block）
# 格式: "源文件路径|提取模式|输出文件名"
# 提取模式: case  - 提取 `glinet,gl-mt3600be)` 到 `;;` 的 shell case 块
#           define - 提取 `define Device/glinet_gl-mt3600be` 到 `endef` 的 make 块
MIXED_FILES=(
  "target/linux/mediatek/filogic/base-files/etc/board.d/01_leds|case|01_leds.case"
  "target/linux/mediatek/filogic/base-files/etc/board.d/02_network|case|02_network.case"
  "target/linux/mediatek/filogic/base-files/etc/init.d/bootcount|case|init_bootcount.case"
  "target/linux/mediatek/filogic/base-files/etc/init.d/turn_on_usb_power|case|init_turn_on_usb_power.case"
  "target/linux/mediatek/image/filogic.mk|define|image_filogic.mk.define"
)

# SoC 支撑文件（可选，--with-soc 才提取）
# mt7987.dtsi 基本必须，其他 patch 视宿主树而定
SOC_DTSI=(
  "target/linux/mediatek/dts/mt7987.dtsi"
)
SOC_PATCH_GLOBS=(
  "package/boot/arm-trusted-firmware-mediatek/patches/*mt7987*.patch"
  "package/boot/uboot-mediatek/patches/*mt7987*.patch"
  "package/boot/uboot-mediatek/patches/*mt7988*.patch"
  "target/linux/generic/pending-6.12/*mt7988*.patch"
)

# ---------- 颜色输出 ----------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi

log()   { printf "%s[%s]%s %s\n" "$C_BLU" "$(date +%H:%M:%S)" "$C_RST" "$*"; }
ok()    { printf "%s ✓%s %s\n"  "$C_GRN" "$C_RST" "$*"; }
warn()  { printf "%s⚠%s  %s\n"  "$C_YEL" "$C_RST" "$*" >&2; }
err()   { printf "%s✗%s  %s\n"  "$C_RED" "$C_RST" "$*" >&2; }
die()   { err "$@"; exit 1; }

# ---------- 参数解析 ----------
usage() {
  cat <<EOF
$SCRIPT_NAME - Extract GL-MT3600BE adaptation patches from ChuranNeko's fork.

Usage:
  $SCRIPT_NAME [options]

Options:
  --source <DIR>          Path to a local clone of ChuranNeko repo.
  --source-url <URL>      Clone ChuranNeko repo from URL (alternative to --source).
                          Default: https://github.com/ChuranNeko/openwrt-snapshot-gl-mt3600be.git
  --output <DIR>          Output directory for the patch set. Default: ./patches
  --with-soc              Also extract MT7987 SoC support (dtsi + ATF/U-Boot/kernel patches).
                          Skip this if your host ImmortalWrt tree already supports MT7987.
  --clean                 Clean output dir before extraction.
  -h, --help              Show this help.

Examples:
  # 从已有本地 clone 提取，只要设备适配
  $SCRIPT_NAME --source ~/work/churanneko --output ./mt3600be-patches

  # 临时 clone 并提取全套（含 SoC 支撑）
  $SCRIPT_NAME --output ./mt3600be-patches --with-soc

EOF
  exit 0
}

SOURCE_DIR=""
SOURCE_URL="https://github.com/ChuranNeko/openwrt-snapshot-gl-mt3600be.git"
OUTPUT_DIR="./patches"
WITH_SOC=0
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)     SOURCE_DIR="$2"; shift 2 ;;
    --source-url) SOURCE_URL="$2"; shift 2 ;;
    --output)     OUTPUT_DIR="$2"; shift 2 ;;
    --with-soc)   WITH_SOC=1; shift ;;
    --clean)      CLEAN=1; shift ;;
    -h|--help)    usage ;;
    *) die "Unknown option: $1 (use -h for help)" ;;
  esac
done

# ---------- 准备源码树 ----------
prepare_source() {
  if [[ -n "$SOURCE_DIR" ]]; then
    [[ -d "$SOURCE_DIR" ]] || die "Source dir not found: $SOURCE_DIR"
    [[ -f "$SOURCE_DIR/target/linux/mediatek/dts/mt7987a-glinet-gl-mt3600be.dts" ]] \
      || die "Source does not look like ChuranNeko repo (missing MT3600BE DTS): $SOURCE_DIR"
    log "Using local source: $SOURCE_DIR"
  else
    local tmp="${OUTPUT_DIR}/.churanneko-clone"
    log "No --source given, shallow cloning to: $tmp"
    rm -rf "$tmp"
    mkdir -p "$(dirname "$tmp")"
    git clone --depth=1 --single-branch "$SOURCE_URL" "$tmp" >/dev/null 2>&1 \
      || die "Clone failed: $SOURCE_URL"
    SOURCE_DIR="$tmp"
    ok "Cloned to $SOURCE_DIR"
  fi
}

# ---------- 提取器：从混合文件里切 case/define 块 ----------

# 从 shell 文件中提取 `glinet,gl-mt3600be)` 到紧跟的 `;;` 之间的 case 块
# 使用 awk，保留完整缩进
extract_case_block() {
  local src="$1"
  local dst="$2"
  local board="$DEVICE_BOARD_NAME"

  [[ -f "$src" ]] || { warn "  missing: $src"; return 1; }

  # awk 状态机：遇到包含 board) 的行开始收集，遇到第一个 ;; 停止（含那一行）
  awk -v board="$board" '
    BEGIN { collecting = 0 }
    {
      if (!collecting && index($0, board ")") > 0) {
        collecting = 1
      }
      if (collecting) {
        print
        # 检测行中是否有单独的 ;; （shell case 块结束标记）
        if ($0 ~ /^[[:space:]]*;;[[:space:]]*$/) {
          exit
        }
      }
    }
  ' "$src" > "$dst"

  if [[ ! -s "$dst" ]]; then
    warn "  no case block found in $src"
    rm -f "$dst"
    return 1
  fi
  return 0
}

# 从 make 文件中提取 `define Device/glinet_gl-mt3600be` 到 `endef` 的块
extract_define_block() {
  local src="$1"
  local dst="$2"
  local key="$DEVICE_DEFINE_KEY"

  [[ -f "$src" ]] || { warn "  missing: $src"; return 1; }

  awk -v key="$key" '
    BEGIN { collecting = 0 }
    {
      if (!collecting && $0 ~ "^define Device/" key "[[:space:]]*$") {
        collecting = 1
      }
      if (collecting) {
        print
        if ($0 ~ /^endef[[:space:]]*$/) {
          exit
        }
      }
    }
  ' "$src" > "$dst"

  if [[ ! -s "$dst" ]]; then
    warn "  no define block found in $src"
    rm -f "$dst"
    return 1
  fi
  return 0
}

# ---------- 输出目录结构 ----------
init_output() {
  if [[ $CLEAN -eq 1 ]]; then
    log "Cleaning $OUTPUT_DIR ..."
    rm -rf "$OUTPUT_DIR"
  fi
  mkdir -p "$OUTPUT_DIR"/{device-specific,snippets,soc-support/{dts,atf-patches,uboot-patches,kernel-patches},_reports}
}

# ---------- Phase 1: 设备专属整文件 ----------
extract_device_files() {
  log "Phase 1: Copying device-specific files..."
  local count=0
  for rel in "${DEVICE_FILES[@]}"; do
    local src="$SOURCE_DIR/$rel"
    local dst="$OUTPUT_DIR/device-specific/$rel"
    if [[ -f "$src" ]]; then
      mkdir -p "$(dirname "$dst")"
      cp -p "$src" "$dst"
      ok "  $rel"
      count=$((count+1))
    else
      warn "  missing: $rel"
    fi
  done
  log "  → copied $count device-specific file(s)"
}

# ---------- Phase 2: 混合文件 snippet ----------
extract_snippets() {
  log "Phase 2: Extracting snippets from shared files..."
  local count=0
  for entry in "${MIXED_FILES[@]}"; do
    IFS='|' read -r rel mode out_name <<< "$entry"
    local src="$SOURCE_DIR/$rel"
    local dst="$OUTPUT_DIR/snippets/$out_name"

    case "$mode" in
      case)
        if extract_case_block "$src" "$dst"; then
          ok "  $rel → snippets/$out_name"
          count=$((count+1))
        fi
        ;;
      define)
        if extract_define_block "$src" "$dst"; then
          ok "  $rel → snippets/$out_name"
          count=$((count+1))
        fi
        ;;
      *)
        err "  unknown extract mode: $mode for $rel"
        ;;
    esac
  done
  log "  → extracted $count snippet(s)"
}

# ---------- Phase 3: SoC 支撑（可选） ----------
extract_soc_support() {
  if [[ $WITH_SOC -eq 0 ]]; then
    log "Phase 3: SKIPPED (--with-soc not given)"
    return
  fi
  log "Phase 3: Extracting MT7987 SoC support..."

  # SoC DTSI
  for rel in "${SOC_DTSI[@]}"; do
    local src="$SOURCE_DIR/$rel"
    local dst="$OUTPUT_DIR/soc-support/dts/$(basename "$rel")"
    if [[ -f "$src" ]]; then
      cp -p "$src" "$dst"
      ok "  dts: $(basename "$rel")"
    else
      warn "  missing SoC file: $rel"
    fi
  done

  # ATF / U-Boot / Kernel patches
  local total=0
  shopt -s nocaseglob nullglob   # 大小写不敏感 + 无匹配时返回空
  for glob in "${SOC_PATCH_GLOBS[@]}"; do
    # 按 patch 类型分桶
    local bucket
    case "$glob" in
      *arm-trusted-firmware*) bucket="atf-patches" ;;
      *uboot*)                bucket="uboot-patches" ;;
      *)                      bucket="kernel-patches" ;;
    esac

    # shellcheck disable=SC2086
    for f in $SOURCE_DIR/$glob; do
      [[ -f "$f" ]] || continue
      cp -p "$f" "$OUTPUT_DIR/soc-support/$bucket/"
      total=$((total+1))
    done
  done
  shopt -u nocaseglob nullglob
  ok "  copied $total SoC patch(es) into atf-/uboot-/kernel-patches/"
}

# ---------- Phase 4: 生成报告 + 清单 ----------
generate_inventory() {
  log "Phase 4: Generating inventory and report..."
  local inv="$OUTPUT_DIR/_reports/INVENTORY.md"
  local git_rev
  if git -C "$SOURCE_DIR" rev-parse HEAD >/dev/null 2>&1; then
    git_rev="$(git -C "$SOURCE_DIR" rev-parse --short HEAD)"
  else
    git_rev="unknown"
  fi

  {
    echo "# MT3600BE Patch Set Inventory"
    echo
    echo "- **Extracted at**: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "- **Source repo**: ${SOURCE_URL:-(local)}"
    echo "- **Source commit**: \`$git_rev\`"
    echo "- **SoC support included**: $([[ $WITH_SOC -eq 1 ]] && echo yes || echo no)"
    echo
    echo "## Files & Checksums"
    echo
    echo "| Path | SHA-256 | Size (bytes) |"
    echo "|------|---------|--------------|"
    (cd "$OUTPUT_DIR" && find . -type f ! -path "./_reports/*" ! -path "./.churanneko-clone/*" \
      | sort | while read -r f; do
        local sha size
        sha="$(sha256sum "$f" | awk '{print $1}')"
        size="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")"
        printf "| \`%s\` | \`%s\` | %s |\n" "${f#./}" "$sha" "$size"
      done)
  } > "$inv"

  ok "  inventory → $inv"
}

generate_readme() {
  local readme="$OUTPUT_DIR/README.md"
  cat > "$readme" <<'EOF'
# GL-MT3600BE (MT7987A + MT7990) Port Kit

This patch set isolates the **device-specific adaptations** made by
[ChuranNeko/openwrt-snapshot-gl-mt3600be](https://github.com/ChuranNeko/openwrt-snapshot-gl-mt3600be)
so they can be applied onto another OpenWrt-family tree — for example an
ImmortalWrt MT798x fork.

## Directory layout

```
patches/
├── README.md               ← this file
├── device-specific/        ← whole files owned by MT3600BE (copy as-is)
│   ├── configs/mt3600be.seed
│   ├── target/linux/mediatek/dts/mt7987a-glinet-gl-mt3600be.dts
│   └── target/linux/mediatek/filogic/base-files/etc/uci-defaults/
│           99-gl-mt3600be-defaults
├── snippets/               ← case/define blocks to be merged into host files
│   ├── 01_leds.case               → board.d/01_leds
│   ├── 02_network.case            → board.d/02_network
│   ├── init_bootcount.case        → init.d/bootcount
│   ├── init_turn_on_usb_power.case→ init.d/turn_on_usb_power
│   └── image_filogic.mk.define    → image/filogic.mk
├── soc-support/            ← only present if --with-soc was used
│   ├── dts/mt7987.dtsi
│   ├── atf-patches/        ← Arm Trusted Firmware patches (mt7987)
│   ├── uboot-patches/      ← U-Boot patches (mt7987 + mt7988)
│   └── kernel-patches/     ← kernel pending patches
└── _reports/
    └── INVENTORY.md        ← file checksums + provenance
```

## Applying onto an ImmortalWrt tree

You have two options:

1. Use the companion script `apply-to-immortalwrt.sh` (recommended).
2. Manually merge — see cheat-sheet below.

### Manual cheat-sheet

```bash
HOST=/path/to/your/immortalwrt-fork
PATCH=./patches

# 1) copy whole files
cp -v $PATCH/device-specific/configs/mt3600be.seed \
      $HOST/configs/
cp -v $PATCH/device-specific/target/linux/mediatek/dts/mt7987a-glinet-gl-mt3600be.dts \
      $HOST/target/linux/mediatek/dts/
install -Dm0755 \
  $PATCH/device-specific/target/linux/mediatek/filogic/base-files/etc/uci-defaults/99-gl-mt3600be-defaults \
  $HOST/target/linux/mediatek/filogic/base-files/etc/uci-defaults/99-gl-mt3600be-defaults

# 2) merge snippets — OPEN host files in an editor and paste each snippet
#    right before the closing `esac` / next unrelated case entry.
#    Do NOT append to the end of the file blindly; case order matters
#    in some base-files scripts.

# 3) (optional) SoC support — ONLY if your host tree lacks MT7987 support
cp -v $PATCH/soc-support/dts/mt7987.dtsi \
      $HOST/target/linux/mediatek/dts/
cp -v $PATCH/soc-support/atf-patches/*.patch \
      $HOST/package/boot/arm-trusted-firmware-mediatek/patches/
# ... etc
```

## Known caveats

- The DTS file wires the Wi-Fi 7 radio as **MT7990** (not MT7992 as in Tenda BE12 Pro).
  If your host tree only has `kmod-mt7992-firmware`, you must add `kmod-mt7990-firmware`
  or bring the firmware package from the source tree.
- ChuranNeko's build uses **kernel 6.12** and the **mt76 open-source driver** stack.
  If your target host uses the MediaTek closed-source `mtwifi-cfg` stack instead,
  the DTS `wifi` node may need to be re-written to match that driver's bindings.
- The `filogic.mk` define block includes Chinese locale / OpenClash / AdGuardHome
  packages. For ImmortalWrt you can remove those since ImmortalWrt has its own
  default profile.
- U-Boot env partition offsets are derived from GL.iNet's stock U-Boot — do **not**
  try to flash a replacement U-Boot unless you have a USB-TTL console.

## Re-extracting on a schedule

Re-run the extractor whenever ChuranNeko pushes new commits:

```bash
./extract-mt3600be-patches.sh --output ./patches --clean --with-soc
diff -ruN ./patches-previous/ ./patches/   # review what changed
```
EOF
  ok "  readme → $readme"
}

# ---------- Main ----------
main() {
  log "=== MT3600BE patch extractor ==="
  init_output
  prepare_source
  extract_device_files
  extract_snippets
  extract_soc_support
  generate_inventory
  generate_readme

  echo
  ok "DONE. Output: $OUTPUT_DIR"
  echo
  echo "Next steps:"
  echo "  1) Review   : cat $OUTPUT_DIR/README.md"
  echo "  2) Inspect  : cat $OUTPUT_DIR/_reports/INVENTORY.md"
  echo "  3) Apply    : ./apply-to-immortalwrt.sh --host /path/to/immortalwrt --patches $OUTPUT_DIR"
}

main "$@"
