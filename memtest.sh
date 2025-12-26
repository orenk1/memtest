#!/usr/bin/env bash
# ==============================================================================
# RAM / CPU QUICK INSPECTION SCRIPT (Debian/Ubuntu Live USB)
# Colored output + full logging + practical RAM speed test (sysbench)
# ------------------------------------------------------------------------------
# Purpose (for used RAM inspection before buying):
#   1) Identify system + RAM configuration (including BIOS configured MT/s)
#   2) Stress most of the RAM with verification (capacity + stability)
#   3) Run a practical timed RAM throughput test (read/write MiB/s)
#
# Tools used (all via apt):
#   - dmidecode  : SMBIOS memory info (Configured Memory Speed, module sizes)
#   - lshw/hwinfo: secondary hardware summaries
#   - stress-ng  : RAM stress + verification (catches fake capacity / bad ICs)
#   - sysbench   : practical timed memory throughput test
#
# Requirements:
#   - Debian/Ubuntu/Mint live USB (internet access to apt install tools)
#   - Run as root: sudo ./ram_inspect.sh
#
# Usage:
#   chmod +x ram_inspect.sh
#   sudo ./ram_inspect.sh
#
# Notes:
#   - XMP/EXPO must be enabled in BIOS BEFORE booting Linux if you want DDR5-6000 speed.
#   - Some DDR5 kits do NOT expose serial via SMBIOS; "Not Specified"/"N/A" is common.
# ==============================================================================

set -Eeuo pipefail

# Ensure admin tool paths exist on Live CDs (common PATH issue)
export PATH="/sbin:/usr/sbin:/bin:/usr/bin:$PATH"

# ---------------------------
# Configuration (edit freely)
# ---------------------------

# Step 2: Stress test (capacity + stability)
VM_WORKERS="2"          # 2 is strong and usually safe on live environments
VM_BYTES_PERCENT="90%"  # ~90% of RAM (for 64GB, around ~55-60GB)
VERIFY_TIMEOUT="5m"     # 5 minutes catches fake capacity / major instability fast

# Step 3: Practical throughput test (sysbench memory)
SYSBENCH_THREADS="4"      # Throughput scaling; 4 is a good default
SYSBENCH_BLOCK_SIZE="1M"  # 1M blocks are a good DRAM-focused size
SYSBENCH_TOTAL_SIZE="200G" # Total data moved; practical + fast. Increase to 40G if desired.

# Logging
LOG_DIR="./ram_inspection_logs"
LOG_BASENAME="ram_inspection_$(date +%Y%m%d_%H%M%S)"
LOG_FILE=""  # assigned at runtime

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

  # Log everything (stdout+stderr) to file while still printing to terminal
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
  # Resolve command even if PATH is weird
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
  # Run a command with clear start/end markers; keep logging even on failure
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

# ---------------------------
# Steps
# ---------------------------

step0_install_packages() {
  banner "Step 0: Install required packages"
  info "Updating apt package lists..."
  apt-get update -y

  info "Installing: stress-ng dmidecode hwinfo lshw util-linux sysbench"
  apt-get install -y stress-ng dmidecode hwinfo lshw util-linux sysbench

  echo
  ok "Installed versions:"
  echo "  stress-ng: $(stress-ng --version 2>/dev/null | head -n 1 || echo 'unknown')"
  echo "  dmidecode: $(dmidecode --version 2>/dev/null || echo 'unknown')"
  echo "  hwinfo:    $(hwinfo --version 2>/dev/null | head -n 1 || echo 'unknown')"
  echo "  lshw:      $(lshw -version 2>/dev/null || echo 'unknown')"
  echo "  sysbench:  $(sysbench --version 2>/dev/null || echo 'unknown')"
}

step1_identity_and_speed() {
  banner "Step 1: Identity / RAM configuration (includes configured speed)"

  run_cmd "1.1 CPU info (lscpu)" lscpu || true

  run_cmd "1.2 Memory totals (/proc/meminfo)" bash -lc \
    "grep -E 'MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree' /proc/meminfo" || true

  local dmi
  if dmi="$(find_cmd dmidecode)"; then
    run_cmd "1.3 SMBIOS Memory (dmidecode -t memory)" "${dmi}" -t memory || true

    # Highlight speed lines clearly (Configured Memory Speed is the key line)
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
  echo "  • Total RAM is ~64GB (see MemTotal)."
  echo "  • Two DIMMs are present (dmidecode/lshw)."
  echo "  • Configured speed shows 6000 MT/s if XMP/EXPO enabled (dmidecode lines)."
  warn "Note: DDR5 serial may be unavailable via software; that is common."
}

step2_capacity_and_stability() {
  banner "Step 2: Capacity + stability test (stress-ng --verify)"
  echo "Allocates ~${VM_BYTES_PERCENT} of RAM, stresses patterns, and verifies correctness."
  echo "This is the key step to catch fake capacity and unstable RAM."
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
  echo "This is a REAL timed test: it repeatedly reads/writes memory and reports MiB/sec."
  echo
  echo "Config:"
  echo "  Threads:   ${SYSBENCH_THREADS}"
  echo "  BlockSize: ${SYSBENCH_BLOCK_SIZE}"
  echo "  TotalSize: ${SYSBENCH_TOTAL_SIZE}"
  echo
  echo "Tip:"
  echo "  - If XMP/EXPO is OFF, RAM may run at JEDEC (e.g. 4800 MT/s), so throughput will be lower."
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
  echo "  - Look for lines ending with 'MiB/sec' (higher is better)."
  echo "  - Huge drop vs expectation can indicate JEDEC speed or single-channel mode."
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

# ---------------------------
# Main
# ---------------------------
main() {
  require_root
  setup_logging

  banner "RAM Inspection Script - START"
  info "Date: $(date)"
  info "PATH: ${PATH}"
  pause

  step0_install_packages
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
