#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# build.sh — One-command build of ImmortalWrt firmware for GL-MT3600BE.
#
# Target: GL.iNet Beryl 7 (GL-MT3600BE) — MT7987A + MT7990, 512MB NAND.
# Host tree: chasey-dev/immortalwrt-mt798x-rebase (branch 25.12) — has
#            native MT3600BE support maintained by Tianling Shen.
#
# Pipeline:
#   preflight → install-deps → clone → verify → feeds → config → make → output
#
# Usage:
#   ./build.sh                 # full pipeline
#   ./build.sh --preflight     # only run environment preflight check
#   ./build.sh --deps-only     # just install build dependencies
#   ./build.sh --config        # stop after feeds + defconfig
#   ./build.sh --menuconfig    # after defconfig, open menuconfig
#   ./build.sh --clean         # remove ./openwrt/ + ./logs/ + make state
#   ./build.sh --clean-all     # --clean + clear ccache too
#   ./build.sh --resume        # skip clone, jump to make (after fixes)
#   ./build.sh --jobs N        # override -j count (default: nproc)
#   ./build.sh --force         # skip preflight hard limits (use at own risk)
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
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preflight)   MODE="preflight"; shift ;;
    --deps-only)   MODE="deps"; shift ;;
    --config)      MODE="config"; shift ;;
    --menuconfig)  MODE="menuconfig"; shift ;;
    --clean)       MODE="clean"; shift ;;
    --clean-all)   MODE="clean-all"; shift ;;
    --resume)      MODE="resume"; shift ;;
    --jobs)        JOBS="$2"; shift 2 ;;
    --force)       FORCE=1; shift ;;
    -h|--help)     sed -n '3,25p' "$0"; exit 0 ;;
    *) die "Unknown arg: $1 (use -h for help)" ;;
  esac
done

# ---------- step: preflight check ----------
# Hard requirements (fail-closed; --force to bypass):
#   CPU cores    ≥ 2
#   RAM          ≥ 4 GB
#   Free disk    ≥ 25 GB at $SCRIPT_DIR (ImmortalWrt docs say 25G minimum)
#   Commands     git make gcc g++ python3 perl
#   Not root     (OpenWrt build refuses root unless FORCE_UNSAFE_CONFIGURE=1)
#   FS           case-sensitive (OpenWrt build requires it)
#
# Soft advisories (warn only):
#   RAM          < 8 GB → suggest adding swap
#   Disk         < 40 GB → tight, could fail at final link
#   Network      github.com unreachable via 443
#
# Env-override defaults:
PREFLIGHT_MIN_CORES="${PREFLIGHT_MIN_CORES:-2}"
PREFLIGHT_MIN_RAM_GB="${PREFLIGHT_MIN_RAM_GB:-4}"
PREFLIGHT_MIN_DISK_GB="${PREFLIGHT_MIN_DISK_GB:-25}"
PREFLIGHT_REC_RAM_GB="${PREFLIGHT_REC_RAM_GB:-8}"
PREFLIGHT_REC_DISK_GB="${PREFLIGHT_REC_DISK_GB:-40}"

preflight_check() {
  log "Step 0/5: Preflight environment check..."
  local failed=0 warned=0

  # System / kernel / arch
  local os_name arch kernel
  if [[ -f /etc/os-release ]]; then
    os_name=$(. /etc/os-release; echo "$PRETTY_NAME")
  else
    os_name="$(uname -s)"
  fi
  arch="$(uname -m)"
  kernel="$(uname -r)"
  printf "   %-14s %s  (%s, kernel %s)\n" "System:" "$os_name" "$arch" "$kernel"

  # CPU
  local cores cpu_model
  cores=$(nproc 2>/dev/null || echo 0)
  cpu_model=$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ *//' || echo "unknown")
  if [[ $cores -ge $PREFLIGHT_MIN_CORES ]]; then
    printf "   %-14s %s cores — %s\n" "CPU:" "$cores" "$cpu_model"
  else
    printf "   %-14s %s cores  ✗ (min: %s)\n" "CPU:" "$cores" "$PREFLIGHT_MIN_CORES"
    failed=$((failed+1))
  fi

  # RAM
  local ram_kb ram_gb swap_kb swap_gb
  ram_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  swap_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  ram_gb=$((ram_kb / 1024 / 1024))
  swap_gb=$((swap_kb / 1024 / 1024))
  if [[ $ram_gb -lt $PREFLIGHT_MIN_RAM_GB ]]; then
    printf "   %-14s %s GB  ✗ (min: %s GB)\n" "RAM:" "$ram_gb" "$PREFLIGHT_MIN_RAM_GB"
    failed=$((failed+1))
  elif [[ $ram_gb -lt $PREFLIGHT_REC_RAM_GB ]]; then
    printf "   %-14s %s GB  ⚠  (< %s GB recommended; consider adding swap)\n" \
      "RAM:" "$ram_gb" "$PREFLIGHT_REC_RAM_GB"
    warned=$((warned+1))
  else
    printf "   %-14s %s GB  ✓\n" "RAM:" "$ram_gb"
  fi
  printf "   %-14s %s GB\n" "Swap:" "$swap_gb"

  # Disk (free space at $SCRIPT_DIR)
  local disk_avail_kb disk_avail_gb
  disk_avail_kb=$(df -P "$SCRIPT_DIR" | awk 'NR==2{print $4}')
  disk_avail_gb=$((disk_avail_kb / 1024 / 1024))
  if [[ $disk_avail_gb -lt $PREFLIGHT_MIN_DISK_GB ]]; then
    printf "   %-14s %s GB free at %s  ✗ (min: %s GB)\n" \
      "Disk:" "$disk_avail_gb" "$SCRIPT_DIR" "$PREFLIGHT_MIN_DISK_GB"
    failed=$((failed+1))
  elif [[ $disk_avail_gb -lt $PREFLIGHT_REC_DISK_GB ]]; then
    printf "   %-14s %s GB free  ⚠  (< %s GB recommended)\n" \
      "Disk:" "$disk_avail_gb" "$PREFLIGHT_REC_DISK_GB"
    warned=$((warned+1))
  else
    printf "   %-14s %s GB free  ✓\n" "Disk:" "$disk_avail_gb"
  fi

  # Required commands
  local missing=()
  for cmd in git make gcc g++ python3 perl awk find; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    printf "   %-14s all present  ✓\n" "Commands:"
  else
    printf "   %-14s missing: %s  ✗\n" "Commands:" "${missing[*]}"
    warn "   → run './build.sh --deps-only' to install them"
    failed=$((failed+1))
  fi

  # Non-root user check
  if [[ $EUID -eq 0 ]]; then
    printf "   %-14s root (UID 0)  ✗  OpenWrt build refuses root\n" "User:"
    warn "   → create a non-root user, or export FORCE_UNSAFE_CONFIGURE=1"
    failed=$((failed+1))
  else
    printf "   %-14s %s (UID %s)  ✓\n" "User:" "$(whoami)" "$EUID"
  fi

  # Filesystem case-sensitivity at SCRIPT_DIR
  local probe="$SCRIPT_DIR/.preflight-case-probe"
  if touch "${probe}_A" 2>/dev/null && touch "${probe}_a" 2>/dev/null; then
    if [[ -f "${probe}_A" && -f "${probe}_a" ]] && \
       [[ "$(ls "${probe}_A" 2>/dev/null)" != "$(ls "${probe}_a" 2>/dev/null)" ]]; then
      printf "   %-14s case-sensitive  ✓\n" "Filesystem:"
    else
      printf "   %-14s NOT case-sensitive  ✗  OpenWrt build will fail\n" "Filesystem:"
      failed=$((failed+1))
    fi
    rm -f "${probe}_A" "${probe}_a"
  else
    printf "   %-14s unknown (probe failed)  ⚠\n" "Filesystem:"
    warned=$((warned+1))
  fi

  # Network reachability (soft)
  if command -v curl >/dev/null 2>&1; then
    local rtt
    rtt=$(curl -sS -o /dev/null -w "%{time_total}" --max-time 5 \
      https://github.com 2>/dev/null || echo "timeout")
    if [[ "$rtt" == "timeout" ]]; then
      printf "   %-14s github.com unreachable  ⚠\n" "Network:"
      warned=$((warned+1))
    else
      printf "   %-14s github.com OK (%ss)\n" "Network:" "$rtt"
    fi
  else
    printf "   %-14s curl not found — skipping\n" "Network:"
  fi

  echo
  # Verdict
  if [[ $failed -gt 0 ]]; then
    err "Preflight FAILED: $failed hard requirement(s) not met, $warned warning(s)."
    if [[ $FORCE -eq 1 ]]; then
      warn "--force given, continuing anyway. You are on your own from here."
    else
      echo "  To override and proceed anyway: ./build.sh --force"
      echo "  To fix dependencies:             ./build.sh --deps-only"
      exit 1
    fi
  elif [[ $warned -gt 0 ]]; then
    ok "Preflight: all hard requirements met ($warned advisory warning(s))."
  else
    ok "Preflight: all checks passed."
  fi
}

# ---------- step: clean ----------
# Two levels:
#   do_clean       — remove ./openwrt/ and ./logs/ (repo-local artifacts)
#   do_clean_all   — above + ~/.ccache (ccache is shared across projects,
#                    but we ARE the one who set it up via `ccache -M 20G`)
do_clean() {
  log "CLEAN: removing repo-local build artifacts..."
  if [[ -d "$WORK_DIR" ]]; then
    local sz; sz=$(du -sh "$WORK_DIR" 2>/dev/null | awk '{print $1}')
    rm -rf "$WORK_DIR"
    ok "  removed $WORK_DIR ($sz)"
  else
    ok "  $WORK_DIR doesn't exist — nothing to do"
  fi
  if [[ -d "$LOG_DIR" ]]; then
    local sz; sz=$(du -sh "$LOG_DIR" 2>/dev/null | awk '{print $1}')
    rm -rf "$LOG_DIR"
    ok "  removed $LOG_DIR ($sz)"
  fi
  ok "clean done (apt packages and ccache NOT touched)."
}

do_clean_all() {
  do_clean
  log "CLEAN-ALL: also clearing ccache..."
  if command -v ccache >/dev/null 2>&1; then
    local sz; sz=$(ccache -s 2>/dev/null | awk '/Cache size/{print $3, $4; exit}')
    ccache -C >/dev/null 2>&1 || true
    ok "  ccache cleared (was $sz)"
  else
    ok "  ccache not installed — nothing to clear"
  fi
  ok "clean-all done."
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

# ---------- monitor helper: print periodic progress for a long-running phase ----------
# $1 = label (e.g. "download")
# $2 = directory to measure
# $3 = stamp file (created when main process finishes) — monitor stops when it appears
# $4 = interval in seconds (default 5)
start_monitor() {
  local label="$1" watch_dir="$2" done_stamp="$3" interval="${4:-5}"
  (
    local prev_files=0 prev_bytes=0 iter=0
    local start_ts=$(date +%s)
    while [[ ! -f "$done_stamp" ]]; do
      local files=0 bytes=0
      if [[ -d "$watch_dir" ]]; then
        files=$(find "$watch_dir" -maxdepth 2 -type f 2>/dev/null | wc -l)
        bytes=$(du -sb "$watch_dir" 2>/dev/null | awk '{print $1}')
        bytes=${bytes:-0}
      fi
      local d_files=$((files - prev_files))
      local d_bytes=$((bytes - prev_bytes))
      local elapsed=$(( $(date +%s) - start_ts ))

      # Human-readable sizes
      local hr_total hr_delta
      hr_total=$(numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B")
      if [[ $d_bytes -ge 0 ]]; then
        hr_delta=$(numfmt --to=iec --suffix=B "$d_bytes" 2>/dev/null || echo "${d_bytes}B")
        hr_delta="+$hr_delta"
      else
        hr_delta="$(numfmt --to=iec --suffix=B $((-d_bytes)) 2>/dev/null)"
        hr_delta="-$hr_delta"
      fi

      # Skip first iteration (delta meaningless)
      if [[ $iter -gt 0 ]]; then
        printf "%s[%s]%s  📊 %-9s %3d files / %-8s  (Δ +%d files, %s in %ds)  elapsed %dm%02ds\n" \
          "$C_B" "$(date +%H:%M:%S)" "$C_RST" \
          "$label" "$files" "$hr_total" "$d_files" "$hr_delta" "$interval" \
          $((elapsed / 60)) $((elapsed % 60))
      fi

      prev_files=$files
      prev_bytes=$bytes
      iter=$((iter+1))
      sleep "$interval"
    done
  ) &
  echo $!  # return monitor PID
}

stop_monitor() {
  local pid="$1"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

# ---------- step: compile ----------
do_compile() {
  log "Step 5/5: Compiling with -j$JOBS ..."
  cd "$WORK_DIR"

  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local dl_log="$LOG_DIR/download-$ts.log"
  local build_log="$LOG_DIR/build-$ts.log"
  local dl_done_stamp="$LOG_DIR/.dl-done-$ts"
  local build_done_stamp="$LOG_DIR/.build-done-$ts"

  # ----- 5.1: download with live monitor -----
  log "  5.1: downloading source packages"
  log "       live log → $dl_log"
  log "       monitor  → every 5s, watching openwrt/dl/"
  echo

  # Remove stale stamp if re-running
  rm -f "$dl_done_stamp"

  # Start background monitor
  local dl_mon_pid
  dl_mon_pid=$(start_monitor "download" "$WORK_DIR/dl" "$dl_done_stamp" 5)

  # Make sure we clean up the monitor if user Ctrl+C's
  trap "stop_monitor $dl_mon_pid; exit 130" INT TERM

  # The actual download
  local dl_rc=0
  if ! make download -j"$JOBS" > "$dl_log" 2>&1; then
    dl_rc=$?
  fi
  touch "$dl_done_stamp"
  stop_monitor "$dl_mon_pid"
  trap - INT TERM
  echo

  if [[ $dl_rc -ne 0 ]]; then
    err "download phase failed (rc=$dl_rc) — last 20 lines of $dl_log:"
    tail -20 "$dl_log" >&2
    exit 1
  fi

  local final_files final_size
  final_files=$(find "$WORK_DIR/dl" -maxdepth 2 -type f 2>/dev/null | wc -l)
  final_size=$(du -sh "$WORK_DIR/dl" 2>/dev/null | awk '{print $1}')
  ok "  download done: $final_files files, $final_size total."

  # ----- 5.2: compile with live monitor -----
  log "  5.2: compiling"
  log "       live log → $build_log"
  log "       monitor  → every 10s, watching openwrt/staging_dir/ and build_dir/"
  echo

  rm -f "$build_done_stamp"
  local build_mon_pid
  build_mon_pid=$(start_monitor "compile " "$WORK_DIR/staging_dir" "$build_done_stamp" 10)

  trap "stop_monitor $build_mon_pid; exit 130" INT TERM

  local build_rc=0
  if ! make -j"$JOBS" > "$build_log" 2>&1; then
    build_rc=$?
  fi
  touch "$build_done_stamp"
  stop_monitor "$build_mon_pid"
  trap - INT TERM
  echo

  if [[ $build_rc -ne 0 ]]; then
    err "Build FAILED (rc=$build_rc). Re-running single-threaded verbose for diagnostics:"
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
  preflight)   preflight_check ;;
  clean)       do_clean ;;
  clean-all)   do_clean_all ;;
  deps)        install_deps ;;
  config)
    preflight_check
    install_deps
    clone_host
    verify_device_support
    run_feeds_and_config
    ok "DONE (config mode). Run './build.sh --resume' to compile."
    ;;
  menuconfig)
    preflight_check
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
    preflight_check
    install_deps
    clone_host
    verify_device_support
    run_feeds_and_config
    do_compile
    ;;
esac

log "=== End ==="
