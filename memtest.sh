#!/usr/bin/env bash
# ==============================================================================
# RAM / CPU QUICK INSPECTION SCRIPT (Debian/Ubuntu Live USB)
# Colored output + full logging + CLI tests + optional GUI launch (HardInfo, CPU-X)
# ------------------------------------------------------------------------------
# What it does:
#   0) Fix PATH to include /sbin and /usr/sbin
#   1) Install required packages
#   2) Launch GUI tools (optional) so you can visually inspect RAM info
#   3) Collect identity/speed via CLI
#   4) Stress test RAM capacity+stability (stress-ng --verify)
#   5) Practical throughput test (sysbench memory)
#   6) Pause between steps; log everything
#
# Usage:
#   chmod +x ram_inspect.sh
#   sudo ./ram_inspect.sh
#
# Notes:
#   - GUI launch will work only if you are in a graphical session (DISPLAY set).
#   - CPU-X may need extra permissions; we run it with sudo.
#   - XMP/EXPO must be enabled in BIOS for DDR5-6000 speed.
# ==============================================================================

set -Eeuo pipefail

export PATH="/sbin:/usr/sbin:/bin:/usr/bin:$PATH"

# ---------------------------
# Configuration
# ---------------------------

# Step 2: stress-ng verify
VM_WORKERS="2"
VM_BYTES_PERCENT="90%"
VERIFY_TIMEOUT="5m"

# Step 3: sysbench memory
SYSBENCH_THREADS="4"
SYSBENCH_BLOCK_SIZE="1M"
SYSBENCH_TOTAL_SIZE="512G"   # large so it runs longer (~tens of seconds to minutes)

# GUI tools (optional)
ENABLE_GUI_TOOLS="1"         # set to "0" to disable GUI launch
GUI_LAUNCH_SLEEP_SEC="2"     # small delay between GUI launches

# Logging
LOG_DIR="./ram_inspection_logs"
LOG_BASENAME="ram_inspection_$(date +%Y%m%d_%H%M%S)"
LOG_FILE=""

# ---------------------------
# Colors (safe fallback)
# ---------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_CYAN=""
fi

# ---------------------------
# Helpers
# ---------------------------
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "${C_RED}${C_BOLD}ERROR:${C_RESET} Please run as root. Example: sudo $0"
    exit 1
  fi
}

setup_logging() {
  mkdir -p "${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/${LOG_BASENAME}.log"
  exec > >(tee -i "${LOG_FILE}") 2>&1
  echo "${C_DIM}Log file: ${LOG_FILE}${C_RESET}"
}

pause() {
  echo
  read -r -p "Press ENTER to continue..." _
}

banner() {
  local title="$1"
  echo
  echo "${C_CYAN}${C_BOLD}==============================================================================${C_RESET}"
  echo "${C_CYAN}${C_BOLD}  ${title}${C_RESET}"
  echo "${C_CYAN}${C_BOLD}==============================================================================${C_RESET}"
}

info() { echo "${C_BLUE}${C_BOLD}[INFO]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}${C_BOLD}[WARN]${C_RESET} $*"; }
ok()   { echo "${C_GREEN}${C_BOLD}[ OK ]${C_RESET} $*"; }

find_cmd() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    command -v "${cmd}"
    return 0
  fi
  for p in "/usr/sbin/${cmd}" "/sbin/${cmd}" "/usr/bin/${cmd}" "/bin/${cmd}"; do
    if [[ -x "${p}" ]]; then
      echo "${p}"
      return 0
    fi
  done
  return 1
}

run_cmd() {
  local title="$1"; shift
  banner "${title}"
  info "Command: $*"
  echo

  set +e
  "$@"
  local rc=$?
  set -e

  echo
  if [[ $rc -eq 0 ]]; then
    ok "Finished: ${title} (exit code ${rc})"
  else
    warn "Finished: ${title} (exit code ${rc}) - check output above"
  fi
  return $rc
}

is_gui_session() {
  # Minimal check: in a live desktop session, DISPLAY is usually set.
  # WAYLAND_DISPLAY may also be set. If neither exists, we assume no GUI.
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
}

launch_gui_app_background() {
  # Launch GUI tool in background if it exists; don't fail script if it doesn't.
  local app="$1"
  local title="$2"

  if ! is_gui_session; then
    warn "No GUI session detected (DISPLAY/WAYLAND_DISPLAY not set). Skipping GUI launch."
    return 0
  fi

  if ! command -v "${app}" >/dev/null 2>&1; then
    warn "GUI app not found: ${app}. Skipping."
    return 0
  fi

  info "Launching GUI: ${title} (${app})"
  # Launch in background so script can continue.
  # Redirect stdout/stderr so the script log doesn't get spammed by GUI noise.
  ( "${app}" >/dev/null 2>&1 & )
  sleep "${GUI_LAUNCH_SLEEP_SEC}"
}

# ---------------------------
# Steps
# ---------------------------
step0_install_packages() {
  banner "Step 0: Install required packages"
  info "Updating apt package lists..."
  apt-get update -y

  info "Installing CLI tools: stress-ng dmidecode hwinfo lshw util-linux sysbench"
  info "Installing GUI tools: hardinfo cpu-x gnome-system-monitor (best effort)"
  apt-get install -y \
    stress-ng dmidecode hwinfo lshw util-linux sysbench \
    hardinfo cpu-x gnome-system-monitor || true

  echo
  ok "Installed versions (best effort):"
  echo "  stress-ng: $(stress-ng --version 2>/dev/null | head -n 1 || echo 'unknown')"
  echo "  dmidecode: $(dmidecode --version 2>/dev/null || echo 'unknown')"
  echo "  sysbench:  $(sysbench --version 2>/dev/null || echo 'unknown')"
}

step0b_launch_gui_tools() {
  banner "Step 0B: Launch GUI tools (optional)"
  if [[ "${ENABLE_GUI_TOOLS}" != "1" ]]; then
    warn "ENABLE_GUI_TOOLS is disabled. Skipping."
    return 0
  fi

  if ! is_gui_session; then
    warn "No GUI session detected. Skipping GUI tools."
    return 0
  fi

  echo "Launching GUI tools to visually inspect RAM info:"
  echo "  - GNOME System Monitor (watch RAM usage during stress tests)"
  echo "  - HardInfo (hardware summary)"
  echo "  - CPU-X (CPU-Z-like memory frequency/timings)"
  echo

  # System monitor first so you can keep it open while tests run
  launch_gui_app_background "gnome-system-monitor" "GNOME System Monitor"
  launch_gui_app_background "hardinfo" "HardInfo"
  # CPU-X sometimes requires privileges to read low-level info; running as root is OK here.
  launch_gui_app_background "cpu-x" "CPU-X"

  ok "GUI tools launched (if available)."
  echo "Tip: Keep System Monitor open during Step 2 to see RAM usage jump high."
}

step1_identity_and_speed() {
  banner "Step 1: Identity / RAM configuration (includes configured speed)"

  run_cmd "1.1 CPU info (lscpu)" lscpu || true

  run_cmd "1.2 Memory totals (/proc/meminfo)" bash -lc \
    "grep -E 'MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree' /proc/meminfo" || true

  local dmi
  if dmi="$(find_cmd dmidecode)"; then
    run_cmd "1.3 SMBIOS Memory (dmidecode -t memory)" "${dmi}" -t memory || true
    run_cmd "1.4 Highlight RAM speed lines" bash -lc \
      "${dmi} -t memory | grep -E 'Configured Memory Speed|Speed:' || true" || true
  else
    warn "dmidecode not found. Skipping dmidecode step."
  fi

  local hwi
  if hwi="$(find_cmd hwinfo)"; then
    run_cmd "1.5 hwinfo memory summary" "${hwi}" --memory || true
  else
    warn "hwinfo not found. Skipping hwinfo step."
  fi

  local lshw_bin
  if lshw_bin="$(find_cmd lshw)"; then
    run_cmd "1.6 lshw memory summary" "${lshw_bin}" -class memory || true
  else
    warn "lshw not found. Skipping lshw step."
  fi

  banner "What you should confirm now"
  echo "  • Total RAM is ~64GB (MemTotal)."
  echo "  • Two DIMMs are present (dmidecode/lshw)."
  echo "  • Configured speed shows 6000 MT/s if XMP/EXPO enabled."
  warn "Note: DDR5 serial/model may not always be exposed to software."
}

step2_capacity_and_stability() {
  banner "Step 2: Capacity + stability test (stress-ng --verify)"
  echo "Allocates ~${VM_BYTES_PERCENT} of RAM, stresses patterns, and verifies correctness."
  echo

  run_cmd "2.1 stress-ng verify test" stress-ng \
    --vm "${VM_WORKERS}" \
    --vm-bytes "${VM_BYTES_PERCENT}" \
    --vm-method all \
    --verify \
    --timeout "${VERIFY_TIMEOUT}" \
    --metrics-brief || true

  banner "How to interpret Step 2"
  echo "  ✅ PASS: completes with no 'fail/error' lines."
  echo "  ❌ FAIL: any verify errors, crashes, or reboots → do not buy."
}

step3_practical_speed_sysbench() {
  banner "Step 3: Practical RAM speed test (sysbench memory)"
  echo "This is a timed memory throughput test. It reports MiB/sec."
  echo
  echo "Config:"
  echo "  Threads:   ${SYSBENCH_THREADS}"
  echo "  BlockSize: ${SYSBENCH_BLOCK_SIZE}"
  echo "  TotalSize: ${SYSBENCH_TOTAL_SIZE}"
  echo

  run_cmd "3.1 sysbench memory WRITE throughput" sysbench memory \
    --memory-block-size="${SYSBENCH_BLOCK_SIZE}" \
    --memory-total-size="${SYSBENCH_TOTAL_SIZE}" \
    --memory-oper=write \
    --threads="${SYSBENCH_THREADS}" \
    run || true

  run_cmd "3.2 sysbench memory READ throughput" sysbench memory \
    --memory-block-size="${SYSBENCH_BLOCK_SIZE}" \
    --memory-total-size="${SYSBENCH_TOTAL_SIZE}" \
    --memory-oper=read \
    --threads="${SYSBENCH_THREADS}" \
    run || true

  banner "How to interpret Step 3"
  echo "  - Look for MiB/sec lines (higher is better)."
  echo "  - If XMP/EXPO is OFF, throughput will be lower."
  echo "  - If single-channel, throughput will be much lower."
}

final_summary() {
  banner "Final Summary"
  ok "Log file saved at: ${LOG_FILE}"
  echo
  echo "${C_BOLD}Buy / Don't Buy quick rule:${C_RESET}"
  echo "  ✅ BUY if:"
  echo "     - Total RAM ~64GB"
  echo "     - Step 2 stress-ng verify shows ZERO errors"
  echo "     - Step 3 sysbench completes cleanly with reasonable MiB/sec"
  echo
  echo "  ❌ DON'T BUY if:"
  echo "     - Any stress-ng verification errors"
  echo "     - System crashes/reboots during tests"
  echo
  echo "${C_DIM}View the full log anytime:${C_RESET}"
  echo "  less -R \"${LOG_FILE}\""
}

main() {
  require_root
  setup_logging

  banner "RAM Inspection Script - START"
  info "Date: $(date)"
  info "PATH: ${PATH}"
  pause

  step0_install_packages
  pause

  step0b_launch_gui_tools
  pause

  step1_identity_and_speed
  pause

  step2_capacity_and_stability
  pause

  step3_practical_speed_sysbench
  pause

  final_summary
}

main "$@"
