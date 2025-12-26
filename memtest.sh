#!/usr/bin/env bash
# ==============================================================================
# RAM / CPU QUICK INSPECTION SCRIPT (Debian/Ubuntu Live USB)
# ------------------------------------------------------------------------------
# Goal:
#   Run a fast, repeatable, Linux-only validation of a RAM kit before purchase.
#   This script will:
#     1) Install required tools (on Debian-based live systems)
#     2) Collect identity/SPD info (dmidecode, hwinfo, lshw)
#     3) Run memory stress/verification tests (stress-ng)
#     4) Run bandwidth-oriented memory test (stress-ng stream)
#     5) Pause between steps so you can review results
#
# What this script proves:
#   - Capacity is real (no 2x16 pretending to be 2x32) via high-allocation + verify
#   - Basic stability of memory under load
#   - Rough performance class (bandwidth) to catch "slow/fallback" behavior
#
# Requirements:
#   - Debian/Ubuntu/Mint Live USB with internet access (to apt install tools)
#   - Run as root (sudo)
#
# Usage:
#   1) Save as: ram_inspect.sh
#   2) Make executable: chmod +x ram_inspect.sh
#   3) Run: sudo ./ram_inspect.sh
#
# Notes / Limitations:
#   - XMP/EXPO must be enabled in BIOS BEFORE booting Linux if you want
#     DDR5-6000-class performance numbers. Linux cannot enable XMP itself.
#   - SPD serial numbers may show "Not Specified" / blank for many DDR5 kits.
#     That is normal and not necessarily a red flag.
# ==============================================================================

set -Eeuo pipefail

# ---------------------------
# Configuration (edit freely)
# ---------------------------

# How much RAM to allocate for the "capacity + stability" test.
# 90% is aggressive but usually safe on a live environment.
VM_BYTES_PERCENT="90%"

# How long to run the main verification stress test.
# 5 minutes is typically enough to catch fake capacity and obvious bad ICs quickly.
VERIFY_TIMEOUT="5m"

# How long to run the bandwidth-oriented stream test.
STREAM_TIMEOUT="2m"

# Number of stress-ng "vm" workers:
# 4 is a good default; you can adjust based on CPU core count.
VM_WORKERS="4"

# Directory to save logs (kept in RAM on live systems, but you can copy afterward).
LOG_DIR="./ram_inspection_logs"

# ---------------------------
# Helper functions
# ---------------------------

print_header() {
  local title="$1"
  echo
  echo "=============================================================================="
  echo "  ${title}"
  echo "=============================================================================="
}

pause() {
  echo
  read -r -p "Press ENTER to continue..." _
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root. Example: sudo $0"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_packages() {
  print_header "Step 0: Installing required packages"
  echo "Creating log directory: ${LOG_DIR}"
  mkdir -p "${LOG_DIR}"

  # Many Live CDs include apt but not always updated indexes.
  echo "Updating apt package lists..."
  apt-get update -y | tee "${LOG_DIR}/apt_update.log"

  # Minimal set:
  # - stress-ng: main RAM test tool
  # - dmidecode: reads memory module info from SMBIOS
  # - hwinfo: reads SPD-like info where available
  # - lshw: hardware summary (sometimes shows memory layout)
  # - util-linux: includes nice tools like 'lscpu' (often already present)
  echo "Installing: stress-ng dmidecode hwinfo lshw util-linux..."
  apt-get install -y stress-ng dmidecode hwinfo lshw util-linux | tee "${LOG_DIR}/apt_install.log"

  echo
  echo "Installed versions:"
  stress-ng --version 2>/dev/null || true
  echo "dmidecode: $(dmidecode --version 2>/dev/null || echo "unknown")"
  hwinfo --version 2>/dev/null || true
  lshw -version 2>/dev/null || true
}

collect_system_info() {
  print_header "Step 1: Collecting system and memory identity info"
  echo "Saving outputs to: ${LOG_DIR}"

  echo
  echo "1.1 CPU info (lscpu)"
  lscpu | tee "${LOG_DIR}/lscpu.txt"

  echo
  echo "1.2 Memory total (from /proc/meminfo)"
  grep -E 'MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree' /proc/meminfo | tee "${LOG_DIR}/meminfo.txt"

  echo
  echo "1.3 SMBIOS Memory info (dmidecode -t memory)"
  echo "Tip: Look for 'Size: 32 GB' per module, total 64 GB, and correct slot population."
  dmidecode -t memory | tee "${LOG_DIR}/dmidecode_memory.txt" || true

  echo
  echo "1.4 hwinfo memory summary (hwinfo --memory)"
  hwinfo --memory | tee "${LOG_DIR}/hwinfo_memory.txt" || true

  echo
  echo "1.5 lshw memory summary (lshw -class memory)"
  lshw -class memory | tee "${LOG_DIR}/lshw_memory.txt" || true

  echo
  echo "Review the saved files in ${LOG_DIR} to confirm:"
  echo "  - Total RAM ~ 64GB"
  echo "  - Two modules installed"
  echo "  - Each module reported ~32GB (if SMBIOS exposes it)"
}

run_capacity_stability_test() {
  print_header "Step 2: RAM capacity + stability test (stress-ng verify)"
  echo "This step allocates ~${VM_BYTES_PERCENT} of RAM and verifies memory writes."
  echo "If the kit is fake capacity or unstable, it usually errors quickly."
  echo
  echo "Command:"
  echo "  stress-ng --vm ${VM_WORKERS} --vm-bytes ${VM_BYTES_PERCENT} --vm-method all --verify --timeout ${VERIFY_TIMEOUT} --metrics-brief"
  echo

  # Run the test and capture output.
  # --vm-method all cycles through multiple access patterns.
  # --verify checks data correctness.
  # --metrics-brief prints summary throughput/stats.
  stress-ng \
    --vm "${VM_WORKERS}" \
    --vm-bytes "${VM_BYTES_PERCENT}" \
    --vm-method all \
    --verify \
    --timeout "${VERIFY_TIMEOUT}" \
    --metrics-brief \
    2>&1 | tee "${LOG_DIR}/stressng_verify.txt"

  echo
  echo "What to look for:"
  echo "  - Any 'fail' or 'error' lines => do NOT buy"
  echo "  - Sudden crashes / reboots => strong red flag"
  echo "  - Clean completion => very strong sign"
}

run_bandwidth_test() {
  print_header "Step 3: RAM bandwidth / performance test (stress-ng stream)"
  echo "This step focuses on sustained memory throughput."
  echo "It does NOT replace deep benchmarking, but it can catch 'slow mode' issues."
  echo
  echo "Command:"
  echo "  stress-ng --vm ${VM_WORKERS} --vm-bytes 8G --vm-method stream --timeout ${STREAM_TIMEOUT} --metrics-brief"
  echo

  # Use a fixed 8G working set to avoid overwhelming the live OS,
  # while still being far beyond CPU cache sizes (so it actually tests RAM).
  stress-ng \
    --vm "${VM_WORKERS}" \
    --vm-bytes 8G \
    --vm-method stream \
    --timeout "${STREAM_TIMEOUT}" \
    --metrics-brief \
    2>&1 | tee "${LOG_DIR}/stressng_stream.txt"

  echo
  echo "What to look for:"
  echo "  - This should run smoothly with no errors."
  echo "  - Compare throughput roughly against similar systems if you want."
  echo
  echo "Important:"
  echo "  - If BIOS XMP/EXPO is OFF, DDR5 will run at JEDEC (often 4800MT/s),"
  echo "    and performance will look lower than expected for DDR5-6000."
}

final_summary() {
  print_header "Step 4: Summary and next actions"
  echo "Logs saved in: ${LOG_DIR}"
  echo
  echo "Quick PASS criteria (for buying used RAM):"
  echo "  1) dmidecode/hwinfo/lshw show ~64GB total and 2 DIMMs populated"
  echo "  2) stress-ng verify test completes with ZERO errors"
  echo "  3) stress-ng stream test completes with ZERO errors"
  echo
  echo "If ANY error appears in stress-ng output => walk away."
  echo
  echo "Tip: If you want stronger confidence (still Linux-only), rerun Step 2"
  echo "with a longer timeout (e.g., 10m) by editing VERIFY_TIMEOUT at the top."
}

main() {
  require_root

  print_header "RAM Inspection Script شروع / Start"
  echo "This script will run a sequence of checks and pause between them."
  echo "If this is a live USB environment, make sure you have internet for apt."
  pause

  install_packages
  pause

  collect_system_info
  pause

  run_capacity_stability_test
  pause

  run_bandwidth_test
  pause

  final_summary
}

main "$@"
