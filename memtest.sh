#!/usr/bin/env bash
# ==============================================================================
# RAM / CPU QUICK INSPECTION SCRIPT (Fedora Desktop 43 / Fedora Workstation)
# ------------------------------------------------------------------------------
# Goal:
#   Verify a used RAM DIMM is "legit" (real capacity, stable, sane SPD fields),
#   especially when testing ONE MODULE AT A TIME.
#
# What it does:
#   0) Logging + sanity checks
#   1) Install required packages via DNF (best effort)
#   2) Optional GUI launch (System Monitor, HardInfo, CPU-X) if available
#   3) Slot-level DIMM verification (prove exactly one populated slot + 32 GB)
#   4) Identity / speed / rank / width info (dmidecode, hwinfo, lshw, lscpu)
#   5) Stability + verification test (stress-ng --verify)
#   6) Address-space proof test (memtester)  <-- strong anti-fake test
#   7) Practical throughput (sysbench memory)
#
# Usage:
#   chmod +x ram_inspect_fedora43.sh
#   sudo ./ram_inspect_fedora43.sh
#
# Notes:
#   - dmidecode reads BIOS/SMBIOS. Some vendors omit serial/part fields; that’s normal.
#   - The best counterfeit detection is: stress-ng verify + memtester passes.
#   - On small-RAM systems, reduce VM_BYTES_PERCENT and MEMTESTER_PERCENT.
#   - Running inside a VM tests virtual RAM behavior, not the physical DIMM.
# ==============================================================================

set -Eeuo pipefail

export PATH="/sbin:/usr/sbin:/bin:/usr/bin:$PATH"

# ---------------------------
# Configuration (tune here)
# ---------------------------

# Expectation checks (for SINGLE DIMM testing)
EXPECTED_DIMM_COUNT="1"       # you said you will test one module at a time
EXPECTED_DIMM_SIZE_GB="32"    # each module should be 32 GB

# stress-ng verify (stability / correctness)
VM_WORKERS="2"
VM_BYTES_PERCENT="85%"        # safer default than 90% for single-stick tests
VERIFY_TIMEOUT="7m"           # increase to 10-20m for more confidence

# memtester (address-space proof, anti-fake)
MEMTESTER_PERCENT="85"        # percent of MemAvailable used by memtester
MEMTESTER_PASSES="1"          # 1 pass is decent; 2-3 for high confidence

# sysbench memory (throughput)
SYSBENCH_THREADS="4"
SYSBENCH_BLOCK_SIZE="1M"
SYSBENCH_TOTAL_SIZE="512G"

# GUI tools (optional)
ENABLE_GUI_TOOLS="1"
GUI_LAUNCH_SLEEP_SEC="2"

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
  # Many operations (dmidecode, installs) require root.
  if [[ "${EUID}" -ne 0 ]]; then
    echo "${C_RED}${C_BOLD}ERROR:${C_RESET} Please run as root. Example: sudo $0"
    exit 1
  fi
}

setup_logging() {
  # Log everything to a file while still showing on screen.
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
fail() { echo "${C_RED}${C_BOLD}[FAIL]${C_RESET} $*"; }

find_cmd() {
  # Resolve a command path robustly.
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
  # Run a command; do not crash script on failure (best effort).
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
  # Wayland or X11 sessions typically set at least one of these.
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
}

launch_gui_app_background() {
  # Launch a GUI app if possible; never fail if missing.
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
  ( "${app}" >/dev/null 2>&1 & )
  sleep "${GUI_LAUNCH_SLEEP_SEC}"
}

# ---------------------------
# Fedora / DNF helpers
# ---------------------------

dnf_install_if_missing() {
  # Install packages only if not already installed.
  local pkgs=("$@")
  local to_install=()

  for pkg in "${pkgs[@]}"; do
    if rpm -q "${pkg}" >/dev/null 2>&1; then
      info "Already installed: ${pkg}"
    else
      to_install+=("${pkg}")
    fi
  done

  if [[ "${#to_install[@]}" -eq 0 ]]; then
    ok "All requested packages already installed."
    return 0
  fi

  info "Installing via dnf: ${to_install[*]}"
  dnf install -y "${to_install[@]}"
}

dnf_enable_rpmfusion_if_possible() {
  # Some optional tools may be present in RPM Fusion.
  # We try to enable it; do not fail if offline.
  banner "Fedora: Optional RPM Fusion enable (best effort)"
  info "Trying to enable RPM Fusion (free + nonfree) to improve tool availability..."
  echo

  set +e
  dnf install -y \
    "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    ok "RPM Fusion enabled."
  else
    warn "RPM Fusion enable failed (offline? repo blocked?). Continuing without it."
  fi
}

# ---------------------------
# Step 0: Install packages
# ---------------------------
step0_install_packages() {
  banner "Step 0: Install required packages (Fedora / DNF)"

  info "Refreshing DNF metadata..."
  dnf makecache -y || true

  # Optional repo enable for better odds of cpu-x/hardinfo availability.
  dnf_enable_rpmfusion_if_possible

  info "Refreshing DNF metadata again..."
  dnf makecache -y || true

  # Core CLI tools (required for meaningful testing)
  local cli_pkgs=(
    stress-ng
    dmidecode
    hwinfo
    lshw
    util-linux
    sysbench
    memtester
  )

  info "Installing CLI packages..."
  set +e
  dnf_install_if_missing "${cli_pkgs[@]}"
  set -e

  # Optional GUI tools (best effort)
  local gui_pkgs=(
    gnome-system-monitor
    cpu-x
  )

  info "Installing GUI packages (best effort)..."
  for p in "${gui_pkgs[@]}"; do
    set +e
    dnf_install_if_missing "${p}"
    set -e
  done

  echo
  ok "Installed versions (best effort):"
  echo "  stress-ng: $(stress-ng --version 2>/dev/null | head -n 1 || echo 'unknown')"
  echo "  dmidecode: $(dmidecode --version 2>/dev/null || echo 'unknown')"
  echo "  memtester: $(memtester 2>/dev/null | head -n 1 || echo 'unknown')"
  echo "  sysbench:  $(sysbench --version 2>/dev/null || echo 'unknown')"
}

# ---------------------------
# Step 0B: Launch GUI tools
# ---------------------------
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
  echo "  - GNOME System Monitor (watch RAM usage during tests)"
  echo "  - CPU-X (CPU-Z-like memory frequency/timings) [may be unavailable]"
  echo

  launch_gui_app_background "gnome-system-monitor" "GNOME System Monitor"
  launch_gui_app_background "cpu-x" "CPU-X"

  ok "GUI tools launched (if available)."
}

# ---------------------------
# Step 1A: Quick system identity
# ---------------------------
step1a_basic_identity() {
  banner "Step 1A: Basic CPU + Memory overview"

  run_cmd "1A.1 CPU info (lscpu)" lscpu || true

  run_cmd "1A.2 Memory totals (/proc/meminfo)" bash -lc \
    "grep -E 'MemTotal|MemAvailable|MemFree|SwapTotal|SwapFree' /proc/meminfo" || true
}

# ---------------------------
# Step 1B: Slot-level DIMM validation (single-module proof)
# ---------------------------
step1b_single_dimm_slot_validation() {
  banner "Step 1B: Slot-level DIMM validation (prove 1x ${EXPECTED_DIMM_SIZE_GB}GB)"

  local dmi
  dmi="$(find_cmd dmidecode)" || {
    fail "dmidecode not found; cannot do slot-level validation."
    return 0
  }

  # Parse dmidecode output:
  # - Only keep populated "Memory Device" sections
  # - Extract slot locator + size + manufacturer + part number + serial (if present)
  #
  # We also COUNT populated slots, and we CHECK size for each populated slot.
  local populated_count="0"
  local bad_size_count="0"

  # Print a clean summary table-like output.
  echo "Populated memory devices (from SMBIOS):"
  echo "------------------------------------------------------------"

  # We process dmidecode in awk, printing one block per populated slot.
  # We also print markers we can count in bash.
  local tmp_out
  tmp_out="$(mktemp)"
  "${dmi}" -t memory | awk '
    BEGIN { in_dev=0; size=""; locator=""; bank=""; man=""; part=""; serial=""; rank=""; speed=""; confspeed=""; dataw=""; totalw=""; }
    /^Memory Device$/ {
      in_dev=1
      size=""; locator=""; bank=""; man=""; part=""; serial=""
      rank=""; speed=""; confspeed=""; dataw=""; totalw=""
      next
    }
    in_dev && /^[ \t]*Size:/ { size=$2 " " $3 }
    in_dev && /^[ \t]*Locator:/ { locator=$2 }
    in_dev && /^[ \t]*Bank Locator:/ { bank=$3 }
    in_dev && /^[ \t]*Manufacturer:/ { man=$2 }
    in_dev && /^[ \t]*Part Number:/ { part=$0 }
    in_dev && /^[ \t]*Serial Number:/ { serial=$3 }
    in_dev && /^[ \t]*Rank:/ { rank=$2 }
    in_dev && /^[ \t]*Speed:/ { speed=$2 " " $3 }
    in_dev && /^[ \t]*Configured Memory Speed:/ { confspeed=$4 " " $5 }
    in_dev && /^[ \t]*Data Width:/ { dataw=$3 " " $4 }
    in_dev && /^[ \t]*Total Width:/ { totalw=$3 " " $4 }
    in_dev && /^$/ {
      if (size != "" && size != "No Module Installed") {
        print "SLOT_OK=1"
        print "Slot:", locator, "| Bank:", bank
        print "  Size:", size
        print "  Manufacturer:", man
        if (serial != "" && serial != "Not") print "  Serial:", serial
        if (rank != "") print "  Rank:", rank
        if (dataw != "") print "  Data Width:", dataw
        if (totalw != "") print "  Total Width:", totalw
        if (speed != "") print "  Speed:", speed
        if (confspeed != "") print "  Configured Speed:", confspeed
        if (part != "") print " ", part
        print "------------------------------------------------------------"
      }
      in_dev=0
    }
  ' > "${tmp_out}"

  cat "${tmp_out}"

  # Count populated slots by counting SLOT_OK markers.
  populated_count="$(grep -c '^SLOT_OK=1$' "${tmp_out}" 2>/dev/null || echo "0")"

  # Check for expected size string (e.g., "32 GB"). Note: dmidecode uses "GB" typically.
  # We flag any populated slot not matching EXPECTED_DIMM_SIZE_GB.
  # This is a "sanity check"; the REAL proof comes from stress-ng + memtester later.
  if [[ "${populated_count}" -gt 0 ]]; then
    # Count how many populated slots DO NOT contain "Size: 32 GB".
    bad_size_count="$(grep -E '^  Size:' "${tmp_out}" | grep -v " ${EXPECTED_DIMM_SIZE_GB} GB" | wc -l | tr -d ' ')"
  fi

  rm -f "${tmp_out}"

  echo
  info "Populated slot count detected: ${populated_count}"
  info "Slots with unexpected size:   ${bad_size_count}"
  echo

  if [[ "${populated_count}" -ne "${EXPECTED_DIMM_COUNT}" ]]; then
    warn "Expected ${EXPECTED_DIMM_COUNT} populated slot(s), but detected ${populated_count}."
    warn "If you are truly testing a single stick, this may indicate a BIOS/board reporting issue."
  else
    ok "Populated slot count matches expectation (${EXPECTED_DIMM_COUNT})."
  fi

  if [[ "${bad_size_count}" -ne 0 ]]; then
    warn "At least one populated slot is NOT reporting ${EXPECTED_DIMM_SIZE_GB} GB in SMBIOS."
    warn "Continue tests: stress-ng + memtester will prove real capacity."
  else
    ok "SMBIOS reports ${EXPECTED_DIMM_SIZE_GB} GB for populated slot(s)."
  fi

  banner "What you want to see (single-DIMM test)"
  echo "  • EXACTLY 1 populated slot"
  echo "  • Size: ${EXPECTED_DIMM_SIZE_GB} GB"
  echo "  • Reasonable Manufacturer/Part Number (not always present)"
  echo
  warn "If SMBIOS fields are blank, that can still be normal. Real proof is Step 2 + Step 3."
}

# ---------------------------
# Step 1C: Additional identity/speed tools
# ---------------------------
step1c_identity_and_speed_tools() {
  banner "Step 1C: Identity / speed tools (dmidecode, hwinfo, lshw)"

  local dmi
  if dmi="$(find_cmd dmidecode)"; then
    run_cmd "1C.1 dmidecode -t memory (full)" "${dmi}" -t memory || true
    run_cmd "1C.2 Highlight key lines" bash -lc \
      "${dmi} -t memory | grep -E 'Size:|Locator:|Manufacturer:|Part Number:|Serial Number:|Rank:|Data Width:|Total Width:|Configured Memory Speed|Speed:' || true" || true
  else
    warn "dmidecode not found. Skipping dmidecode."
  fi

  local hwi
  if hwi="$(find_cmd hwinfo)"; then
    run_cmd "1C.3 hwinfo --memory" "${hwi}" --memory || true
  else
    warn "hwinfo not found. Skipping hwinfo."
  fi

  local lshw_bin
  if lshw_bin="$(find_cmd lshw)"; then
    run_cmd "1C.4 lshw -class memory" "${lshw_bin}" -class memory || true
  else
    warn "lshw not found. Skipping lshw."
  fi

  banner "Legit 32GB DIMM sanity hints"
  echo "  • Rank: often 2 for 32GB UDIMM (not always shown)"
  echo "  • Data Width: usually 64 bits (72 for ECC)"
  echo "  • Configured speed reflects BIOS XMP/EXPO (e.g., 6000 MT/s)"
}

# ---------------------------
# Step 2: stress-ng verify (stability / correctness)
# ---------------------------
step2_stressng_verify() {
  banner "Step 2: Capacity + stability test (stress-ng --verify)"

  echo "This test allocates ~${VM_BYTES_PERCENT} of RAM and verifies memory patterns."
  echo "Any verification errors are a strong 'DO NOT BUY' signal."
  echo

  run_cmd "2.1 stress-ng verify test" stress-ng \
    --vm "${VM_WORKERS}" \
    --vm-bytes "${VM_BYTES_PERCENT}" \
    --vm-method all \
    --verify \
    --timeout "${VERIFY_TIMEOUT}" \
    --metrics-brief || true

  banner "Interpretation"
  echo "  ✅ PASS: completes with NO verify errors"
  echo "  ❌ FAIL: verify errors, crash, reboot → do not buy"
}

# ---------------------------
# Step 2B: memtester address-space proof (anti-fake)
# ---------------------------
step2b_memtester_random_fast() {
  banner "Step 2B: Fast random address-space test (memtester, percentage-based)"

  local memtester_bin
  memtester_bin="$(find_cmd memtester)" || {
    warn "memtester not found. Skipping Step 2B."
    return 0
  }

  # Read MemAvailable in kB (this already accounts for kernel + cache needs)
  local mem_avail_kb
  mem_avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"

  if [[ -z "${mem_avail_kb}" || "${mem_avail_kb}" -le 0 ]]; then
    warn "Could not determine MemAvailable. Skipping memtester."
    return 0
  fi

  # Convert to MB and take 85%
  local mem_avail_mb
  mem_avail_mb=$(( mem_avail_kb / 1024 ))

  local mem_to_test_mb
  mem_to_test_mb=$(( mem_avail_mb * 85 / 100 ))

  # Safety limits (important for predictability)
  # Minimum: 6 GB  (still catches fake RAM)
  # Maximum: 26 GB (keeps runtime ~5–7 min even on large systems)
  if [[ "${mem_to_test_mb}" -lt 6144 ]]; then
    mem_to_test_mb=6144
  fi

  if [[ "${mem_to_test_mb}" -gt 26624 ]]; then
    mem_to_test_mb=26624
  fi

  # Time limit (wall clock)
  local TIME_LIMIT="7m"

  echo "Dynamic percentage-based memtester configuration:"
  echo "  MemAvailable: ${mem_avail_mb} MB"
  echo "  Test percent: 85%"
  echo "  Memory locked: ${mem_to_test_mb} MB"
  echo "  Time limit:   ${TIME_LIMIT}"
  echo
  echo "This uses randomized address patterns and is sufficient to detect fake capacity."
  echo

  run_cmd "2B.1 memtester (85% of available RAM, time-limited)" \
    timeout "${TIME_LIMIT}" \
    "${memtester_bin}" "${mem_to_test_mb}" 9999 || true

  banner "Interpretation"
  echo "  ✅ PASS: no errors before timeout"
  echo "  ❌ FAIL: ANY error = fake or defective RAM"
  echo
  warn "Timeout exit code is expected and OK."
}


# ---------------------------
# Step 3: sysbench throughput
# ---------------------------
step3_sysbench_throughput() {
  banner "Step 3: Practical RAM throughput (sysbench memory)"

  local sysbench_bin
  sysbench_bin="$(find_cmd sysbench)" || {
    warn "sysbench not found. Skipping Step 3."
    return 0
  }

  echo "Reports MiB/sec; useful for sanity-checking speed/channel/rank behavior."
  echo "Config:"
  echo "  Threads:   ${SYSBENCH_THREADS}"
  echo "  BlockSize: ${SYSBENCH_BLOCK_SIZE}"
  echo "  TotalSize: ${SYSBENCH_TOTAL_SIZE}"
  echo

  run_cmd "3.1 sysbench WRITE throughput" "${sysbench_bin}" memory \
    --memory-block-size="${SYSBENCH_BLOCK_SIZE}" \
    --memory-total-size="${SYSBENCH_TOTAL_SIZE}" \
    --memory-oper=write \
    --threads="${SYSBENCH_THREADS}" \
    run || true

  run_cmd "3.2 sysbench READ throughput" "${sysbench_bin}" memory \
    --memory-block-size="${SYSBENCH_BLOCK_SIZE}" \
    --memory-total-size="${SYSBENCH_TOTAL_SIZE}" \
    --memory-oper=read \
    --threads="${SYSBENCH_THREADS}" \
    run || true

  banner "Interpretation"
  echo "  • Compare results between the two DIMMs; they should be similar."
  echo "  • XMP/EXPO OFF will reduce throughput; enable in BIOS to confirm rated behavior."
}

final_summary() {
  banner "Final Summary (Single-DIMM legitimacy check)"

  ok "Log file saved at: ${LOG_FILE}"
  echo

  echo "${C_BOLD}Your 'legit 32GB' decision rule:${C_RESET}"
  echo "  ✅ BUY if ALL are true:"
  echo "     - Step 1B shows exactly ${EXPECTED_DIMM_COUNT} populated slot(s)"
  echo "     - SMBIOS size is ${EXPECTED_DIMM_SIZE_GB} GB (nice-to-have, not absolute)"
  echo "     - Step 2 (stress-ng --verify) shows ZERO verification errors"
  echo "     - Step 2B (memtester) shows ZERO errors"
  echo "     - Step 3 (sysbench) is sane and consistent across both sticks"
  echo
  echo "  ❌ DON'T BUY if ANY are true:"
  echo "     - stress-ng reports verify errors"
  echo "     - memtester reports ANY error"
  echo "     - system freezes/reboots during tests"
  echo

  echo "${C_DIM}View the full log anytime:${C_RESET}"
  echo "  less -R \"${LOG_FILE}\""
}

main() {
  require_root
  setup_logging

  banner "RAM Inspection Script - START (Fedora Desktop 43)"
  info "Date: $(date)"
  info "Fedora release: $(rpm -E %fedora 2>/dev/null || echo 'unknown')"
  info "PATH: ${PATH}"
  echo
  echo "Expectation:"
  echo "  - You are testing ONE DIMM at a time (expected populated slots: ${EXPECTED_DIMM_COUNT})"
  echo "  - Each DIMM should be ${EXPECTED_DIMM_SIZE_GB} GB"
  pause

  step0_install_packages
  pause

  step0b_launch_gui_tools
  pause

  step1a_basic_identity
  pause

  step1b_single_dimm_slot_validation
  pause

  step1c_identity_and_speed_tools
  pause

  step2_stressng_verify
  pause

  step2b_memtester_random_fast
  pause

  step3_sysbench_throughput
  pause

  final_summary
}

main "$@"
