#!/usr/bin/env bash
# ==============================================================================
# RAM / CPU QUICK INSPECTION SCRIPT (Debian/Ubuntu Live USB) - Colored + Logging
# ------------------------------------------------------------------------------
# What it does:
#   1) Ensures admin paths are in PATH (/sbin, /usr/sbin)
#   2) Installs required packages
#   3) Collects memory identity info
#   4) Runs RAM capacity/stability test (stress-ng verify)
#   5) Runs RAM bandwidth test (stress-ng stream)
#   6) Pauses between steps so you can review output
#   7) Logs EVERYTHING to a timestamped logfile
#
# Usage:
#   chmod +x ram_inspect.sh
#   sudo ./ram_inspect.sh
# ==============================================================================

set -Eeuo pipefail

# Ensure admin paths exist in PATH (common issue on Live CDs)
export PATH="/sbin:/usr/sbin:/bin:/usr/bin:$PATH"

# ---------------------------
# Configuration (edit freely)
# ---------------------------
VM_BYTES_PERCENT="90%"     # Stress allocation percent of RAM (big)
VERIFY_TIMEOUT="5m"        # Main verification stress duration
STREAM_TIMEOUT="2m"        # Bandwidth/stream test duration
VM_WORKERS="4"             # Number of stress-ng vm workers
LOG_DIR="./ram_inspection_logs"
LOG_BASENAME="ram_inspection_$(date +%Y%m%d_%H%M%S)"
LOG_FILE=""                # Will be assigned after LOG_DIR created

# ---------------------------
# Color helpers (safe fallback)
# ---------------------------
if [[ -t 1 ]]; then
  # Terminal supports color (usually)
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
else
  # Non-interactive: disable colors
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

# ---------------------------
# Logging setup
# ---------------------------
setup_logging() {
  mkdir -p "${LOG_DIR}"

  LOG_FILE="${LOG_DIR}/${LOG_BASENAME}.log"

  # Tee all stdout+stderr to logfile while still printing to terminal
  # -i keeps interactive prompts working
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

info()    { echo "${C_BLUE}${C_BOLD}[INFO]${C_RESET} $*"; }
warn()    { echo "${C_YELLOW}${C_BOLD}[WARN]${C_RESET} $*"; }
ok()      { echo "${C_GREEN}${C_BOLD}[ OK ]${C_RESET} $*"; }
failmsg() { echo "${C_RED}${C_BOLD}[FAIL]${C_RESET} $*"; }

# Find a command path robustly (works if PATH is weird)
find_cmd() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    command -v "${cmd}"
    return 0
  fi
  # Common locations for admin tools on Debian/Ubuntu
  for p in "/usr/sbin/${cmd}" "/sbin/${cmd}" "/usr/bin/${cmd}" "/bin/${cmd}"; do
    if [[ -x "${p}" ]]; then
      echo "${p}"
      return 0
    fi
  done
  return 1
}

run_cmd() {
  # Runs a command and prints a clear "start/end" marker
  local title="$1"; shift
  banner "${title}"
  info "Command: $*"
  echo

  # Run command; do not abort entire script if it fails (we want logs)
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

  info "Installing packages: stress-ng dmidecode hwinfo lshw util-linux"
  apt-get install -y stress-ng dmidecode hwinfo lshw util-linux

  echo
  ok "Installed tools:"
  echo "  stress-ng: $(stress-ng --version 2>/dev/null | head -n 1 || echo 'unknown')"
  echo "  dmidecode: $(dmidecode --version 2>/dev/null || echo 'unknown')"
  echo "  hwinfo:    $(hwinfo --version 2>/dev/null | head -n 1 || echo 'unknown')"
  echo "  lshw:      $(lshw -version 2>/dev/null || echo 'unknown')"
}

collect_identity_info() {
  banner "Step 1: Identity / hardware info (CPU + RAM layout)"

  run_cmd "1.1 CPU info (lscpu)" lscpu || true

  run_cmd "1.2 Memory totals (/proc/meminfo)" bash -lc \
    "grep -E 'MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree' /proc/meminfo" || true

  # dmidecode may not be in PATH on some live systems, so locate it robustly
  local dmi
  if dmi="$(find_cmd dmidecode)"; then
    run_cmd "1.3 SMBIOS Memory info (${dmi} -t memory)" "${dmi}" -t memory || true
  else
    warn "dmidecode not found (even after PATH fix). Skipping dmidecode step."
  fi

  local hwi
  if hwi="$(find_cmd hwinfo)"; then
    run_cmd "1.4 hwinfo memory summary (${hwi} --memory)" "${hwi}" --memory || true
  else
    warn "hwinfo not found. Skipping hwinfo step."
  fi

  local lshw_bin
  if lshw_bin="$(find_cmd lshw)"; then
    run_cmd "1.5 lshw memory summary (${lshw_bin} -class memory)" "${lshw_bin}" -class memory || true
  else
    warn "lshw not found. Skipping lshw step."
  fi

  banner "What you should confirm now"
  echo "  • Total RAM is ~64GB (look at MemTotal and/or dmidecode output)."
  echo "  • Two DIMMs are present."
  echo "  • If SMBIOS exposes it: each DIMM should show ~32GB."
  echo
  warn "Note: Many DDR5 kits do NOT expose serial numbers via SPD/SMBIOS; 'Not Specified' is common."
}

run_stress_verify() {
  banner "Step 2: Capacity + stability test (stress-ng verify)"
  echo "This allocates ~${VM_BYTES_PERCENT} of RAM and verifies reads/writes."
  echo "Fake capacity or bad ICs usually fail quickly."
  echo

  run_cmd "2.1 stress-ng verify test" stress-ng \
    --vm "${VM_WORKERS}" \
    --vm-bytes "${VM_BYTES_PERCENT}" \
    --vm-method all \
    --verify \
    --timeout "${VERIFY_TIMEOUT}" \
    --metrics-brief || true

  banner "How to interpret"
  echo "  ✅ PASS: completes with no 'fail/error' messages."
  echo "  ❌ FAIL: any errors, calculation failures, crashes, or reboots → do not buy."
}

run_bandwidth_stream() {
  banner "Step 3: Bandwidth / performance smoke test (stress-ng stream)"
  echo "This is a quick throughput-oriented test (not a full benchmark)."
  echo "If XMP/EXPO is OFF, DDR5 may run at JEDEC (e.g., 4800) and look slower."
  echo

  run_cmd "3.1 stress-ng stream test" stress-ng \
    --vm 2 \
    --vm-bytes 90% \
    --timeout "${STREAM_TIMEOUT}" \
    --vm-method all \
    --verify \
    --metrics-brief || true

  banner "How to interpret"
  echo "  ✅ PASS: runs cleanly without errors."
  echo "  ⚠️ If numbers seem low: verify XMP/EXPO is enabled in BIOS before Linux boot."
}

final_summary() {
  banner "Final Summary"
  ok "Log file saved at: ${LOG_FILE}"
  echo
  echo "${C_BOLD}Buy / Don't Buy quick rule:${C_RESET}"
  echo "  ✅ BUY if:"
  echo "     - Total RAM ~64GB"
  echo "     - stress-ng verify test shows no errors"
  echo "     - stream test shows no errors"
  echo
  echo "  ❌ DON'T BUY if:"
  echo "     - Any stress-ng verification errors"
  echo "     - System crashes/reboots during tests"
  echo
  echo "${C_DIM}Tip: If you missed something on-screen, open the log:${C_RESET}"
  echo "  less -R \"${LOG_FILE}\""
}

main() {
  require_root
  setup_logging

  banner "RAM Inspection Script - START"
  info "Running on: $(date)"
  info "PATH: ${PATH}"
  echo
  echo "This will run checks and pause between them."
  pause

  install_packages
  pause

  collect_identity_info
  pause

  run_stress_verify
  pause

  run_bandwidth_stream
  pause

  final_summary
}

main "$@"
