#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# build.sh — One-command build entry for GL-MT3600BE on ImmortalWrt mt798x-rebase.
#
# Pipeline: install-deps → clone host → apply patches → feeds → defconfig → compile
#
# Usage:
#   ./build.sh                 # full pipeline (install-deps to compile)
#   ./build.sh --deps-only     # just install build dependencies
#   ./build.sh --apply-only    # clone + apply patches, then stop
#   ./build.sh --menuconfig    # apply, then open menuconfig (no auto-compile)
#   ./build.sh --clean         # wipe ./openwrt/ and exit
#   ./build.sh --jobs N        # override -j count (default: nproc)
#   ./build.sh --resume        # skip clone/apply, jump to make (after fixing errors)
#
# Notes:
#   - First run will likely fail. This is expected because MT7987A support in
#     ImmortalWrt is still experimental. Read build.log, fix patches/, re-run.
#   - Script is idempotent: existing ./openwrt/ is reused unless --clean is given.
#   - Logs go to ./logs/ with timestamps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------- config (env-overridable) ----------
HOST_TREE_URL="${HOST_TREE_URL:-https://github.com/SmartRouterZone/mt798x-rebase.git}"
HOST_TREE_BRANCH="${HOST_TREE_BRANCH:-main}"
HOST_TREE_DEPTH="${HOST_TREE_DEPTH:-1}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/openwrt}"
PATCH_DIR="${PATCH_DIR:-$SCRIPT_DIR/patches}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
CCACHE_SIZE="${CCACHE_SIZE:-20G}"

# ---------- colors ----------
if [[ -t 1 ]]; then
  C_R=$'\033[31m' C_G=$'\033[32m' C_Y=$'\033[33m' C_B=$'\033[34m' C_RST=$'\033[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_RST=""
fi
log()  { printf "%s[%s]%s %s\n" "$C_B" "$(date +%H:%M:%S)" "$C_RST" "$*"; }
ok()   { printf " %s✓%s %s\n" "$C_G" "$C_RST" "$*"; }
warn() { printf " %s⚠%s %s\n" "$C_Y" "$C_RST" "$*" >&2; }
err()  { printf " %s✗%s %s\n" "$C_R" "$C_RST" "$*" >&2; }
die()  { err "$@"; exit 1; }

# ---------- args ----------
MODE="full"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deps-only)   MODE="deps"; shift ;;
    --apply-only)  MODE="apply"; shift ;;
    --menuconfig)  MODE="menuconfig"; shift ;;
    --clean)       MODE="clean"; shift ;;
    --resume)      MODE="resume"; shift ;;
    --jobs)        JOBS="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,22p' "$0"; exit 0 ;;
    *) die "Unknown arg: $1 (use -h for help)" ;;
  esac
done

mkdir -p "$LOG_DIR"

# ---------- step: clean ----------
do_clean() {
  log "CLEAN: removing $WORK_DIR and $LOG_DIR ..."
  rm -rf "$WORK_DIR" "$LOG_DIR"
  ok "clean done."
}

# ---------- step: install deps ----------
install_deps() {
  log "Step 1/5: Installing build dependencies..."
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "Non-Debian/Ubuntu system detected; skipping auto-install."
    warn "Manually install the packages listed in docs/dependencies.md"
    return
  fi
  local SUDO=""
  [[ $EUID -ne 0 ]] && SUDO="sudo"
  $SUDO apt-get update -qq
  $SUDO apt-get install -y --no-install-recommends \
    build-essential clang flex bison g++ gawk \
    gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
    python3 python3-pip python3-ply python3-docutils python3-pyelftools \
    rsync swig unzip zlib1g-dev file wget subversion ccache tmux curl \
    ca-certificates pkg-config libelf-dev zstd qemu-utils quilt \
    2>&1 | tail -5 || warn "Some packages failed; check manually."

  # ccache setup
  if command -v ccache >/dev/null 2>&1; then
    ccache -M "$CCACHE_SIZE" >/dev/null 2>&1 || true
    ok "ccache set to $CCACHE_SIZE"
  fi
  ok "Dependencies installed."
}

# ---------- step: clone host tree ----------
clone_host() {
  log "Step 2/5: Preparing host ImmortalWrt tree..."
  if [[ -d "$WORK_DIR/.git" ]]; then
    ok "  $WORK_DIR already cloned — skipping. (use --clean to reset)"
    return
  fi
  log "  cloning $HOST_TREE_URL (branch=$HOST_TREE_BRANCH, depth=$HOST_TREE_DEPTH) ..."
  git clone --depth="$HOST_TREE_DEPTH" --single-branch \
    -b "$HOST_TREE_BRANCH" "$HOST_TREE_URL" "$WORK_DIR" \
    2>&1 | tail -5
  ok "  cloned."
}

# ---------- step: apply patches ----------
apply_patches() {
  log "Step 3/5: Applying MT3600BE patches onto host tree..."
  [[ -d "$PATCH_DIR" ]] || die "PATCH_DIR not found: $PATCH_DIR"
  [[ -d "$WORK_DIR" ]] || die "WORK_DIR not found: $WORK_DIR (run --clean then re-run?)"

  # a marker file so we don't re-apply on --resume
  local marker="$WORK_DIR/.mt3600be-patched"
  if [[ -f "$marker" ]]; then
    ok "  patches already applied (marker exists) — skipping."
    return
  fi

  # 3.1 device-specific whole files
  log "  3.1: copying device-specific files..."
  ( cd "$PATCH_DIR/device-specific" && find . -type f ) | while read -r f; do
    rel="${f#./}"
    install -Dm0644 "$PATCH_DIR/device-specific/$rel" "$WORK_DIR/$rel"
    echo "       + $rel"
  done
  # uci-defaults must be executable
  chmod +x "$WORK_DIR"/target/linux/mediatek/filogic/base-files/etc/uci-defaults/99-gl-mt3600be-defaults \
    2>/dev/null || true

  # 3.2 merge snippets into host shared files
  log "  3.2: merging snippets..."
  apply_snippet_before_esac \
    "$PATCH_DIR/snippets/01_leds.case" \
    "$WORK_DIR/target/linux/mediatek/filogic/base-files/etc/board.d/01_leds" \
    "glinet,gl-mt3600be"

  apply_snippet_before_esac \
    "$PATCH_DIR/snippets/02_network.case" \
    "$WORK_DIR/target/linux/mediatek/filogic/base-files/etc/board.d/02_network" \
    "glinet,gl-mt3600be"

  apply_snippet_before_esac \
    "$PATCH_DIR/snippets/init_bootcount.case" \
    "$WORK_DIR/target/linux/mediatek/filogic/base-files/etc/init.d/bootcount" \
    "glinet,gl-mt3600be"

  apply_snippet_before_esac \
    "$PATCH_DIR/snippets/init_turn_on_usb_power.case" \
    "$WORK_DIR/target/linux/mediatek/filogic/base-files/etc/init.d/turn_on_usb_power" \
    "glinet,gl-mt3600be"

  apply_define_block \
    "$PATCH_DIR/snippets/image_filogic.mk.define" \
    "$WORK_DIR/target/linux/mediatek/image/filogic.mk" \
    "glinet_gl-mt3600be"

  # 3.3 optional: SoC support (only if the host tree lacks MT7987 bits)
  if [[ ! -f "$WORK_DIR/target/linux/mediatek/dts/mt7987.dtsi" ]]; then
    log "  3.3: host tree missing MT7987 support — installing soc-support/ ..."
    install -Dm0644 "$PATCH_DIR/soc-support/dts/mt7987.dtsi" \
      "$WORK_DIR/target/linux/mediatek/dts/mt7987.dtsi"

    for p in "$PATCH_DIR"/soc-support/atf-patches/*.patch; do
      [[ -f "$p" ]] || continue
      install -Dm0644 "$p" "$WORK_DIR/package/boot/arm-trusted-firmware-mediatek/patches/$(basename "$p")"
    done
    for p in "$PATCH_DIR"/soc-support/uboot-patches/*.patch; do
      [[ -f "$p" ]] || continue
      install -Dm0644 "$p" "$WORK_DIR/package/boot/uboot-mediatek/patches/$(basename "$p")"
    done
    for p in "$PATCH_DIR"/soc-support/kernel-patches/*.patch; do
      [[ -f "$p" ]] || continue
      install -Dm0644 "$p" "$WORK_DIR/target/linux/generic/pending-6.12/$(basename "$p")"
    done
    ok "  SoC support installed."
  else
    ok "  3.3: host tree already has MT7987 support — skipping soc-support/."
  fi

  touch "$marker"
  ok "All patches applied. Marker: $marker"
}

# ---------- helper: insert case-block into a shell file, before the final esac ----------
apply_snippet_before_esac() {
  local snippet="$1" target="$2" board_key="$3"
  if [[ ! -f "$snippet" ]]; then
    warn "       snippet missing: $snippet — skipped"; return
  fi
  if [[ ! -f "$target" ]]; then
    warn "       target missing: $target — skipped"; return
  fi
  if grep -q "$board_key)" "$target"; then
    echo "       = $target already has $board_key case — skipped"
    return
  fi

  # strategy: find line number of last 'esac' in target, insert snippet *before* it.
  local last_esac
  last_esac=$(awk '/^[[:space:]]*esac[[:space:]]*$/{n=NR} END{print n}' "$target")
  if [[ -z "$last_esac" ]]; then
    warn "       no 'esac' line in $target — snippet NOT inserted; handle manually."
    return
  fi

  local tmp
  tmp=$(mktemp)
  {
    sed -n "1,$((last_esac-1))p" "$target"
    cat "$snippet"
    sed -n "${last_esac},\$p" "$target"
  } > "$tmp"
  mv "$tmp" "$target"
  echo "       + $target (inserted before line $last_esac)"
}

# ---------- helper: append a make 'define' block to a Makefile ----------
apply_define_block() {
  local snippet="$1" target="$2" key="$3"
  if [[ ! -f "$snippet" ]]; then
    warn "       snippet missing: $snippet — skipped"; return
  fi
  if [[ ! -f "$target" ]]; then
    warn "       target missing: $target — skipped"; return
  fi
  if grep -q "^define Device/$key" "$target"; then
    echo "       = $target already has Device/$key — skipped"
    return
  fi
  printf "\n" >> "$target"
  cat "$snippet" >> "$target"
  printf "\n" >> "$target"
  echo "       + $target (appended Device/$key)"
}

# ---------- step: feeds & config ----------
run_feeds_and_config() {
  log "Step 4/5: feeds update/install + defconfig..."
  cd "$WORK_DIR"

  # seed config
  if [[ -f "$PATCH_DIR/device-specific/configs/mt3600be.seed" ]]; then
    cp "$PATCH_DIR/device-specific/configs/mt3600be.seed" .config
    ok "  seeded .config from mt3600be.seed"
  fi

  ./scripts/feeds update -a 2>&1 | tail -3
  ./scripts/feeds install -a 2>&1 | tail -3
  ok "  feeds done."

  make defconfig 2>&1 | tail -3
  ok "  defconfig done."
  cd "$SCRIPT_DIR"
}

# ---------- step: compile ----------
do_compile() {
  log "Step 5/5: Compiling with -j$JOBS (logs → $LOG_DIR/build-*.log)..."
  cd "$WORK_DIR"

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local dl_log="$LOG_DIR/download-$ts.log"
  local build_log="$LOG_DIR/build-$ts.log"

  log "  5.1: pre-downloading source packages..."
  make download -j"$JOBS" 2>&1 | tee "$dl_log" | tail -5 \
    || { err "download phase failed — see $dl_log"; exit 1; }

  log "  5.2: compiling..."
  if make -j"$JOBS" 2>&1 | tee "$build_log" | grep -E "^(make|ERROR|FAILED)" | tail -20; then
    : # grep matched something, but pipeline ok
  fi

  if grep -q "ERROR\|error:" "$build_log" | head -1; then
    err "Build had errors. Re-running verbose single-threaded for diagnostics:"
    warn "  cd $WORK_DIR && make -j1 V=s 2>&1 | tee $LOG_DIR/verbose-$ts.log"
    exit 1
  fi

  # Check output
  local out="$WORK_DIR/bin/targets/mediatek/filogic"
  if ls "$out"/*mt3600be*sysupgrade.bin 2>/dev/null >/dev/null; then
    ok "SUCCESS! Firmware at:"
    ls -lh "$out"/*mt3600be*
    echo
    echo "Next steps:"
    echo "  1) sha256sum   : sha256sum $out/*mt3600be*sysupgrade.bin"
    echo "  2) transfer    : scp $out/*mt3600be*sysupgrade.bin root@<router>:/tmp/"
    echo "  3) verify      : ssh root@<router> 'sysupgrade -T /tmp/<file>.bin'"
    echo "  4) flash       : ssh root@<router> 'sysupgrade -n /tmp/<file>.bin'"
  else
    err "Compilation reported no errors but no firmware produced. Check $build_log."
    exit 1
  fi
  cd "$SCRIPT_DIR"
}

# ---------- main dispatcher ----------
log "=== MT3600BE Build Pipeline (mode=$MODE, jobs=$JOBS) ==="

case "$MODE" in
  clean)
    do_clean
    ;;
  deps)
    install_deps
    ;;
  apply)
    install_deps
    clone_host
    apply_patches
    ok "DONE (apply-only). Inspect: $WORK_DIR"
    ;;
  menuconfig)
    install_deps
    clone_host
    apply_patches
    run_feeds_and_config
    log "Opening menuconfig..."
    cd "$WORK_DIR" && make menuconfig
    ok "menuconfig saved. Run './build.sh --resume' to compile."
    ;;
  resume)
    [[ -d "$WORK_DIR" ]] || die "No existing work dir at $WORK_DIR — run full mode first."
    do_compile
    ;;
  full)
    install_deps
    clone_host
    apply_patches
    run_feeds_and_config
    do_compile
    ;;
esac

log "=== End ==="
