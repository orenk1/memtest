#!/usr/bin/env bash
# ==============================================================================
# RAM / CPU QUICK INSPECTION SCRIPT (Debian/Ubuntu Live USB) - Colored + Logging
# + Practical RAM Speed Test (mbw)
# ------------------------------------------------------------------------------
# What it does:
#   0) Adds /sbin and /usr/sbin to PATH (common on Live CDs)
#   1) Installs required tools
#   2) Collects memory identity + configured speed (dmidecode/lshw/hwinfo)
#   3) Runs RAM capacity/stability test (stress-ng --vm --verify)
#   4) Runs PRACTICAL RAM SPEED TEST (mbw) using a large buffer (default 8GB)
#   5) Pauses between steps so you can review output
#   6) Logs EVERYTHING to a timestamped logfile
#
# Usage:
#   chmod +x ram_inspect.sh
#   sudo ./ram_inspect.sh
#
# Notes:
#   - XMP/EXPO must be enabled in BIOS BEFORE booting Linux to see DDR5-6000 speeds.
#   - Many DDR5 kits do not expose serial via SMBIOS/SPD; "N/A" is common.
# ==============================================================================

set -Eeuo pipefail

# Ensure admin paths exist in PATH (common issue on Live CDs)
export PATH="/sbin:/usr/sbin:/bin:/usr/bin:$PATH"

# ---------------------------
# Configuration (edit freely)
# ---------------------------
VM_BYTES_PERCENT="90%"       # Step 2 stress allocation percent of RAM
VERIFY_TIMEOUT="5m"          # Step 2 duration
VM_WORKERS="2"               # Step 2 workers (2 is strong and safer than 4 on Live CDs)

MBW_SIZE_MB="8000"           # Step 3 practical speed test buffer size in MB (8000MB ~ 8GB)
MBW_RUNS="3"                 # Repeat count for mbw

LOG_DIR="./ram_inspection_logs"
LOG_BASENAME="ram_inspection_$(date +%Y%m%d_%H%M%S)"
LOG_FILE=""                  # Assigned after LOG_DIR created

# ---------------------------
# Color helpers (safe fallback)
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
# Logging setup
# ---------------------------
setup_logging() {
  mkdir -p "${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/${LOG_BASENAME}.log"

  # Tee all stdout+stderr to logfile while still printing to terminal
  exec > >(tee -i "${LOG_FILE}") 2>&1

  echo "${C_DIM}Log file: ${LOG_FILE}${C_RESET}"
}

# ---------------------------
# Utility functions
# ---------------------------
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "${C_RED}${C_BOLD}ERROR:${C_RESET} Please run as root. Example: sudo $0"
    exit 1
  fi
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

# Find a command path robustly (works if PATH is weird)
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

  # Run command; don't abort entire script if it fails (keep logs!)
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
install_packages() {
  banner "Step 0: Install required packages"
  info "Updating apt package lists..."
  apt-get update -y

  info "Installing packages: stress-ng dmidecode hwinfo lshw util-linux mbw"
  apt-get install -y stress-ng dmidecode hwinfo lshw util-linux mbw

  echo
  ok "Installed tools:"
  echo "  stress-ng: $(stress-ng --version 2>/dev/null | head -n 1 || echo 'unknown')"
  echo "  dmidecode: $(dmidecode --version 2>/dev/null || echo 'unknown')"
  echo "  hwinfo:    $(hwinfo --version 2>/dev/null | head -n 1 || echo 'unknown')"
  echo "  lshw:      $(lshw -version 2>/dev/null || echo 'unknown')"
  echo "  mbw:       $(mbw 2>/dev/null | head -n 1 || echo 'installed')"
}

collect_identity_info() {
  banner "Step 1: Identity / memory configuration (includes configured speed)"
  run_cmd "1.1 CPU info (lscpu)" lscpu || true

  run_cmd "1.2 Memory totals (/proc/meminfo)" bash -lc \
    "grep -E 'MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree' /proc/meminfo" || true

  local dmi
  if dmi="$(find_cmd dmidecode)"; then
    run_cmd "1.3 SMBIOS Memory (dmidecode -t memory)" "${dmi}" -t memory || true

    # Highlight speed lines so they're easy to see
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
  echo "  • Configured speed: 6000 MT/s if XMP/EXPO enabled (dmidecode speed lines)."
  warn "Note: DDR5 serial may be unavailable via software; that is common."
}

run_stress_verify() {
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

  banner "How to interpret"
  echo "  ✅ PASS: completes with no 'fail/error' lines."
  echo "  ❌ FAIL: any verify errors, crashes, or reboots → do not buy."
}

run_practical_speed_test_mbw() {
  banner "Step 3: Practical RAM SPEED test (mbw)"
  echo "This is a REAL timing test: it allocates a large buffer and measures copy/read/write throughput."
  echo
  echo "Config:"
  echo "  - Buffer size: ${MBW_SIZE_MB} MB"
  echo "  - Runs:        ${MBW_RUNS}"
  echo
  echo "Command:"
  echo "  mbw -n ${MBW_RUNS} -t ${MBW_SIZE_MB}"
  echo

  # mbw writes/reads/copies a large region, producing MiB/s output.
  # It's a clean 'practical throughput' number and easy to compare between systems.
  run_cmd "3.1 mbw speed test" mbw -n "${MBW_RUNS}" -t "${MBW_SIZE_MB}" || true

  banner "How to interpret"
  echo "  - Look at the AVG lines (MiB/s). Higher is better."
  echo "  - If XMP/EXPO is OFF (e.g., 4800 MT/s), numbers will be lower."
  echo "  - If the kit is running single-channel, numbers will be much lower."
}

final_summary() {
  banner "Final Summary"
  ok "Log file saved at: ${LOG_FILE}"
  echo
  echo "${C_BOLD}Buy / Don't Buy quick rule:${C_RESET}"
  echo "  ✅ BUY if:"
  echo "     - Total RAM ~64GB"
  echo "     - stress-ng verify test shows ZERO errors"
  echo "     - mbw completes cleanly and throughput looks reasonable"
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
  info "Running on: $(date)"
  info "PATH: ${PATH}"
  pause

  install_packages
  pause

  collect_identity_info
  pause

  run_stress_verify
  pause

  run_practical_speed_test_mbw
  pause

  final_summary
}

main "$@"
