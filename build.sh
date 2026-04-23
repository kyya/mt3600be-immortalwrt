#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# build.sh — One-command build of ImmortalWrt firmware for GL-MT3600BE.
#
# Target: GL.iNet Beryl 7 (GL-MT3600BE) — MT7987A + MT7990, 512MB NAND.
# Host tree: chasey-dev/immortalwrt-mt798x-rebase (branch 25.12) — has
#            native MT3600BE support maintained by Tianling Shen.
#
# Pipeline:
#   install-deps → clone → verify → feeds → config → make → output
#
# Usage:
#   ./build.sh                 # full pipeline
#   ./build.sh --deps-only     # just install build dependencies
#   ./build.sh --config        # stop after feeds + defconfig
#   ./build.sh --menuconfig    # after defconfig, open menuconfig
#   ./build.sh --clean         # wipe ./openwrt/ and exit
#   ./build.sh --resume        # skip clone, jump to make (after fixes)
#   ./build.sh --jobs N        # override -j count (default: nproc)
#   ./build.sh -h              # show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------- config (env-overridable) ----------
HOST_TREE_URL="${HOST_TREE_URL:-https://github.com/chasey-dev/immortalwrt-mt798x-rebase.git}"
HOST_TREE_BRANCH="${HOST_TREE_BRANCH:-25.12}"
HOST_TREE_DEPTH="${HOST_TREE_DEPTH:-1}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/openwrt}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
CCACHE_SIZE="${CCACHE_SIZE:-20G}"

# Device target (don't change unless you know what you're doing)
DEVICE_TARGET="mediatek"
DEVICE_SUBTARGET="filogic"
DEVICE_PROFILE="glinet_gl-mt3600be"

# ---------- logs dir must exist BEFORE tee can write to it ----------
# Creating it here (before any exit or arg parsing) so that
# `./build.sh 2>&1 | tee logs/first-run.log` works from a fresh clone.
mkdir -p "$LOG_DIR"

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
    --config)      MODE="config"; shift ;;
    --menuconfig)  MODE="menuconfig"; shift ;;
    --clean)       MODE="clean"; shift ;;
    --resume)      MODE="resume"; shift ;;
    --jobs)        JOBS="$2"; shift 2 ;;
    -h|--help)     sed -n '3,22p' "$0"; exit 0 ;;
    *) die "Unknown arg: $1 (use -h for help)" ;;
  esac
done

# ---------- step: clean ----------
do_clean() {
  log "CLEAN: removing $WORK_DIR ..."
  rm -rf "$WORK_DIR"
  ok "cleaned (logs kept)."
}

# ---------- step: install deps ----------
install_deps() {
  log "Step 1/5: Installing build dependencies..."
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "Non-Debian/Ubuntu system detected; skipping auto-install."
    warn "See docs/dependencies.md for other distros."
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
    2>&1 | tail -3 || warn "Some packages failed; you may need to fix manually."

  # ccache bootstrap
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
    -b "$HOST_TREE_BRANCH" "$HOST_TREE_URL" "$WORK_DIR" 2>&1 | tail -5
  ok "  cloned."
}

# ---------- verify: MT3600BE device support really exists ----------
verify_device_support() {
  log "Step 3/5: Verifying MT3600BE device support in host tree..."
  local dts="$WORK_DIR/target/linux/mediatek/dts/mt7987a-glinet-gl-mt3600be.dts"
  local mk="$WORK_DIR/target/linux/mediatek/image/filogic.mk"

  [[ -f "$dts" ]] || die "MT3600BE DTS not found: $dts
Either the host tree doesn't support this device, or the branch is wrong.
Current branch: $HOST_TREE_BRANCH. Try passing HOST_TREE_BRANCH=<newer>"

  grep -q "^define Device/$DEVICE_PROFILE" "$mk" \
    || die "MT3600BE device block missing in $mk"

  ok "  DTS present: $(basename "$dts")"
  ok "  Device block present in filogic.mk"
}

# ---------- step: feeds + config ----------
run_feeds_and_config() {
  log "Step 4/5: feeds update/install + config..."
  cd "$WORK_DIR"

  ./scripts/feeds update -a 2>&1 | tail -3
  ./scripts/feeds install -a 2>&1 | tail -3
  ok "  feeds done."

  # Minimal config seed: target + subtarget + device. defconfig fills the rest.
  {
    echo "CONFIG_TARGET_${DEVICE_TARGET}=y"
    echo "CONFIG_TARGET_${DEVICE_TARGET}_${DEVICE_SUBTARGET}=y"
    echo "CONFIG_TARGET_${DEVICE_TARGET}_${DEVICE_SUBTARGET}_DEVICE_${DEVICE_PROFILE}=y"
  } > .config

  # Append user preinstall list (if exists)
  local seed="$SCRIPT_DIR/config.seed"
  if [[ -f "$seed" ]]; then
    # Strip comments and blank lines, keep CONFIG_ directives only
    local seed_count
    seed_count=$(grep -cE '^(CONFIG_|# CONFIG_.* is not set$)' "$seed" || echo 0)
    grep -E '^(CONFIG_|# CONFIG_.* is not set$)' "$seed" >> .config
    ok "  appended $seed_count preinstall directives from config.seed"
  else
    warn "  no config.seed found — firmware will use ImmortalWrt defaults only"
  fi

  make defconfig 2>&1 | tail -3

  # Sanity-check: did our preinstall survive defconfig?
  if [[ -f "$seed" ]]; then
    local kept dropped
    kept=$(grep -cE '^CONFIG_PACKAGE_[^=]+=y$' .config || echo 0)
    dropped=$(grep -c '^CONFIG_PACKAGE_' "$seed" 2>/dev/null || echo 0)
    dropped=$((dropped - kept))
    if [[ $dropped -gt 0 ]]; then
      warn "  NOTE: defconfig dropped ~$dropped preinstall entries"
      warn "  (likely missing dependencies or renamed packages)"
      warn "  Run './build.sh --menuconfig' to investigate."
    fi
  fi
  ok "  defconfig done → .config has $(wc -l < .config) lines."
  cd "$SCRIPT_DIR"
}

# ---------- step: compile ----------
do_compile() {
  log "Step 5/5: Compiling with -j$JOBS ..."
  cd "$WORK_DIR"

  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local dl_log="$LOG_DIR/download-$ts.log"
  local build_log="$LOG_DIR/build-$ts.log"

  log "  5.1: pre-downloading source packages → $dl_log"
  if ! make download -j"$JOBS" > "$dl_log" 2>&1; then
    err "download phase failed — see $dl_log"
    tail -20 "$dl_log" >&2
    exit 1
  fi
  ok "  downloads complete."

  log "  5.2: compiling → $build_log"
  if ! make -j"$JOBS" > "$build_log" 2>&1; then
    err "Build FAILED. Re-running single-threaded verbose for diagnostics:"
    local verbose_log="$LOG_DIR/verbose-$ts.log"
    warn "  verbose log: $verbose_log"
    make -j1 V=s > "$verbose_log" 2>&1 || true
    echo
    echo "Last 50 lines of verbose log:"
    tail -50 "$verbose_log" >&2
    exit 1
  fi

  # find output
  local out="$WORK_DIR/bin/targets/$DEVICE_TARGET/$DEVICE_SUBTARGET"
  local bins
  bins=$(ls "$out"/*mt3600be*sysupgrade.bin 2>/dev/null || true)

  if [[ -z "$bins" ]]; then
    err "Compilation reported no errors but no firmware was produced. Check $build_log."
    exit 1
  fi

  ok "SUCCESS! Firmware built:"
  ls -lh "$out"/*mt3600be*
  echo
  echo "SHA-256 checksums:"
  (cd "$out" && sha256sum *mt3600be* 2>/dev/null || true)
  echo
  echo "Next steps:"
  echo "  scp <file>  root@192.168.8.1:/tmp/"
  echo "  ssh root@192.168.8.1 'sysupgrade -T /tmp/<file>.bin'   # verify"
  echo "  ssh root@192.168.8.1 'sysupgrade -n /tmp/<file>.bin'   # flash (no config preserve)"

  cd "$SCRIPT_DIR"
}

# ---------- main dispatcher ----------
log "=== MT3600BE Build Pipeline (mode=$MODE, jobs=$JOBS) ==="

case "$MODE" in
  clean)       do_clean ;;
  deps)        install_deps ;;
  config)
    install_deps
    clone_host
    verify_device_support
    run_feeds_and_config
    ok "DONE (config mode). Run './build.sh --resume' to compile."
    ;;
  menuconfig)
    install_deps
    clone_host
    verify_device_support
    run_feeds_and_config
    log "Opening menuconfig (save & exit when done)..."
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
    verify_device_support
    run_feeds_and_config
    do_compile
    ;;
esac

log "=== End ==="
