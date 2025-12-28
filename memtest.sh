#!/usr/bin/env bash
# ==============================================================================
# RAM / CPU QUICK INSPECTION SCRIPT (Fedora Desktop 43 / Fedora Workstation)
# ------------------------------------------------------------------------------
# Purpose:
#   Verify a used RAM DIMM is legit (real capacity, stable, sane SPD, meaningful
#   sustained memory throughput). Designed for testing ONE DIMM at a time.
#
# Key tests:
#   - Slot-level DIMM validation (dmidecode): BIOS/SMBIOS reported size/fields
#   - stress-ng --verify: correctness under heavy RAM load (very strong detector)
#   - memtester (time-limited, percent-based): additional address/pattern coverage
#   - fio (ioengine=memory): reports real READ/WRITE bandwidth in MiB/s (prebuilt)
#
# Usage:
#   chmod +x ram_inspect_fedora43.sh
#   sudo ./ram_inspect_fedora43.sh
#
# Notes:
#   - If SMBIOS fields are blank, that's often normal. Real proof is Step 2 + 2B.
#   - One DIMM => single-channel bandwidth. Compare sticks under same settings.
# ==============================================================================

set -Eeuo pipefail
export PATH="/sbin:/usr/sbin:/bin:/usr/bin:$PATH"

# ---------------------------
# Configuration (tune here)
# ---------------------------

# Change per run if you want SMBIOS "hint" checking:
# - For a 16GB stick: EXPECTED_DIMM_SIZE_GB="16"
# - For a 32GB stick: EXPECTED_DIMM_SIZE_GB="32"
EXPECTED_DIMM_COUNT="1"
EXPECTED_DIMM_SIZE_GB="32"

# stress-ng verify (stability / correctness)
VM_WORKERS="2"
VM_BYTES_PERCENT="85%"
VERIFY_TIMEOUT="7m"

# memtester (fast, time-limited, percent-based)
MEMTESTER_PERCENT="85"          # % of MemAvailable to lock
MEMTESTER_PASSES="9999"         # huge; we stop via timeout
MEMTESTER_TIME_LIMIT="7m"       # target 5–7 minutes

# fio RAM bandwidth test (ioengine=memory) - produces MiB/s output
FIO_RUNTIME_SEC="90"            # 60–120 sec is good
FIO_BS="1M"                     # block size
FIO_NUMJOBS="2"                 # worker jobs
FIO_ARRAY_PERCENT="50"          # % of MemAvailable to allocate for fio buffer
FIO_MIN_SIZE_GB="4"             # minimum buffer size (GiB)
FIO_MAX_SIZE_GB="12"            # maximum buffer size (GiB) -> keeps runtime + pressure sane

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
fail() { echo "${C_RED}${C_BOLD}[FAIL]${C_RESET} $*"; }

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
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
}

launch_gui_app_background() {
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

  dnf_enable_rpmfusion_if_possible

  info "Refreshing DNF metadata again..."
  dnf makecache -y || true

  # Core CLI tools
  local cli_pkgs=(
    stress-ng
    dmidecode
    hwinfo
    lshw
    util-linux
    memtester
    fio
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
  echo "  fio:       $(fio --version 2>/dev/null || echo 'unknown')"
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

  echo "Launching GUI tools:"
  echo "  - GNOME System Monitor"
  echo "  - CPU-X (if available)"
  echo

  launch_gui_app_background "gnome-system-monitor" "GNOME System Monitor"
  launch_gui_app_background "cpu-x" "CPU-X"

  ok "GUI tools launched (if available)."
}

# ---------------------------
# Step 1A: Basic identity
# ---------------------------
step1a_basic_identity() {
  banner "Step 1A: Basic CPU + Memory overview"
  run_cmd "1A.1 CPU info (lscpu)" lscpu || true
  run_cmd "1A.2 Memory totals (/proc/meminfo)" bash -lc \
    "grep -E 'MemTotal|MemAvailable|MemFree|SwapTotal|SwapFree' /proc/meminfo" || true
}

# ---------------------------
# Step 1B: Slot-level DIMM validation
# ---------------------------
step1b_single_dimm_slot_validation() {
  banner "Step 1B: Slot-level DIMM validation (prove 1 DIMM + size hint)"

  local dmi
  dmi="$(find_cmd dmidecode)" || {
    fail "dmidecode not found; cannot do slot-level validation."
    return 0
  }

  local tmp_out
  tmp_out="$(mktemp)"

  "${dmi}" -t memory | awk '
    BEGIN { in_dev=0; size=""; locator=""; bank=""; man=""; part=""; serial=""; rank=""; confspeed=""; dataw=""; totalw=""; }
    /^Memory Device$/ {
      in_dev=1
      size=""; locator=""; bank=""; man=""; part=""; serial=""
      rank=""; confspeed=""; dataw=""; totalw=""
      next
    }
    in_dev && /^[ \t]*Size:/ { size=$2 " " $3 }
    in_dev && /^[ \t]*Locator:/ { locator=$2 }
    in_dev && /^[ \t]*Bank Locator:/ { bank=$3 }
    in_dev && /^[ \t]*Manufacturer:/ { man=$2 }
    in_dev && /^[ \t]*Part Number:/ { part=$0 }
    in_dev && /^[ \t]*Serial Number:/ { serial=$3 }
    in_dev && /^[ \t]*Rank:/ { rank=$2 }
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
        if (confspeed != "") print "  Configured Speed:", confspeed
        if (part != "") print " ", part
        print "------------------------------------------------------------"
      }
      in_dev=0
    }
  ' > "${tmp_out}"

  cat "${tmp_out}"

  local populated_count bad_size_count
  populated_count="$(grep -c '^SLOT_OK=1$' "${tmp_out}" 2>/dev/null || echo "0")"
  bad_size_count="0"
  if [[ "${populated_count}" -gt 0 ]]; then
    bad_size_count="$(grep -E '^  Size:' "${tmp_out}" | grep -v " ${EXPECTED_DIMM_SIZE_GB} GB" | wc -l | tr -d ' ')"
  fi

  echo
  info "Populated slot count detected: ${populated_count}"
  info "Slots with unexpected size:   ${bad_size_count}"
  echo

  if [[ "${populated_count}" -ne "${EXPECTED_DIMM_COUNT}" ]]; then
    warn "Expected ${EXPECTED_DIMM_COUNT} populated slot(s), but detected ${populated_count}."
  else
    ok "Populated slot count matches expectation (${EXPECTED_DIMM_COUNT})."
  fi

  if [[ "${bad_size_count}" -ne 0 ]]; then
    warn "SMBIOS size does NOT match ${EXPECTED_DIMM_SIZE_GB} GB for at least one populated slot."
    warn "Continue: Step 2 + Step 2B are the real proof of capacity."
  else
    ok "SMBIOS size matches ${EXPECTED_DIMM_SIZE_GB} GB for populated slot(s)."
  fi

  rm -f "${tmp_out}"
}

# ---------------------------
# Step 1C: Extra identity tools
# ---------------------------
step1c_identity_and_speed_tools() {
  banner "Step 1C: Identity / speed tools (dmidecode highlights, hwinfo, lshw)"

  local dmi hwi lshw_bin
  if dmi="$(find_cmd dmidecode)"; then
    run_cmd "1C.1 dmidecode highlights" bash -lc \
      "${dmi} -t memory | grep -E 'Size:|Locator:|Manufacturer:|Part Number:|Serial Number:|Rank:|Data Width:|Total Width:|Configured Memory Speed|Speed:' || true" || true
  else
    warn "dmidecode not found."
  fi

  if hwi="$(find_cmd hwinfo)"; then
    run_cmd "1C.2 hwinfo --memory" "${hwi}" --memory || true
  else
    warn "hwinfo not found."
  fi

  if lshw_bin="$(find_cmd lshw)"; then
    run_cmd "1C.3 lshw -class memory" "${lshw_bin}" -class memory || true
  else
    warn "lshw not found."
  fi
}

# ---------------------------
# Step 2: stress-ng verify
# ---------------------------
step2_stressng_verify() {
  banner "Step 2: Capacity + stability test (stress-ng --verify)"
  echo "Allocates ~${VM_BYTES_PERCENT} of RAM and verifies patterns."
  echo

  run_cmd "2.1 stress-ng verify test" stress-ng \
    --vm "${VM_WORKERS}" \
    --vm-bytes "${VM_BYTES_PERCENT}" \
    --vm-method all \
    --verify \
    --timeout "${VERIFY_TIMEOUT}" \
    --metrics-brief || true

  banner "Interpretation"
  echo "  ✅ PASS: no verify errors"
  echo "  ❌ FAIL: any verify error / crash / reboot → do not buy"
}

# ---------------------------
# Step 2B: memtester (time-limited, percent-based)
# ---------------------------
step2b_memtester_random_fast() {
  banner "Step 2B: Fast address-space test (memtester, % of MemAvailable, time-limited)"

  local memtester_bin
  memtester_bin="$(find_cmd memtester)" || {
    warn "memtester not found. Skipping Step 2B."
    return 0
  }

  local mem_avail_kb mem_avail_mb mem_to_test_mb
  mem_avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"

  if [[ -z "${mem_avail_kb}" || "${mem_avail_kb}" -le 0 ]]; then
    warn "Could not read MemAvailable. Skipping memtester."
    return 0
  fi

  mem_avail_mb=$(( mem_avail_kb / 1024 ))
  mem_to_test_mb=$(( mem_avail_mb * MEMTESTER_PERCENT / 100 ))

  # Safety bounds
  if [[ "${mem_to_test_mb}" -lt 6144 ]]; then mem_to_test_mb=6144; fi
  if [[ "${mem_to_test_mb}" -gt 26624 ]]; then mem_to_test_mb=26624; fi

  echo "MemAvailable: ${mem_avail_mb} MB"
  echo "Locking:      ${mem_to_test_mb} MB (${MEMTESTER_PERCENT}% of MemAvailable, capped)"
  echo "Time limit:   ${MEMTESTER_TIME_LIMIT}"
  echo

  run_cmd "2B.1 memtester (time-limited)" \
    timeout "${MEMTESTER_TIME_LIMIT}" \
    "${memtester_bin}" "${mem_to_test_mb}" "${MEMTESTER_PASSES}" || true

  banner "Interpretation"
  echo "  ✅ PASS: no errors before timeout"
  echo "  ❌ FAIL: ANY error = fake/defective RAM"
  warn "Timeout exit is expected and OK."
}

# ---------------------------
# Step 3: fio RAM bandwidth test (precompiled, MiB/s output)
# ---------------------------
compute_fio_size_gib() {
  # Compute fio buffer size in GiB based on MemAvailable.
  # fio will allocate this much RAM for the memory engine.
  #
  # We choose: size_gib = MemAvailable * percent / 100
  # Then clamp to [FIO_MIN_SIZE_GB, FIO_MAX_SIZE_GB]
  #
  # Returns a string like "8G".
  local mem_avail_kb mem_avail_gib raw_gib size_gib

  mem_avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
  if [[ -z "${mem_avail_kb}" || "${mem_avail_kb}" -le 0 ]]; then
    echo "${FIO_MIN_SIZE_GB}G"
    return 0
  fi

  # Convert kB -> GiB (integer)
  mem_avail_gib=$(( mem_avail_kb / 1024 / 1024 ))

  # Compute percentage of available GiB (integer)
  raw_gib=$(( mem_avail_gib * FIO_ARRAY_PERCENT / 100 ))

  # Clamp
  size_gib="${raw_gib}"
  if [[ "${size_gib}" -lt "${FIO_MIN_SIZE_GB}" ]]; then size_gib="${FIO_MIN_SIZE_GB}"; fi
  if [[ "${size_gib}" -gt "${FIO_MAX_SIZE_GB}" ]]; then size_gib="${FIO_MAX_SIZE_GB}"; fi

  echo "${size_gib}G"
}

step3_fio_ram_bandwidth() {
  banner "Step 3: RAM throughput test (fio ioengine=memory, MiB/s output)"

  local fio_bin
  fio_bin="$(find_cmd fio)" || {
    warn "fio not found. Skipping Step 3."
    return 0
  }

  local fio_size
  fio_size="$(compute_fio_size_gib)"

  echo "fio configuration:"
  echo "  ioengine:   memory (RAM-only)"
  echo "  size:       ${fio_size} (buffer size)"
  echo "  bs:         ${FIO_BS}"
  echo "  numjobs:    ${FIO_NUMJOBS}"
  echo "  runtime:    ${FIO_RUNTIME_SEC}s"
  echo
  echo "Output to watch:"
  echo "  READ:  bw=XXXXXMiB/s"
  echo "  WRITE: bw=XXXXXMiB/s"
  echo

  # We run two jobs: one read and one write, sequentially, for easy interpretation.
  run_cmd "3.1 fio WRITE bandwidth" "${fio_bin}" \
    --name=ram_write \
    --ioengine=memory \
    --rw=write \
    --size="${fio_size}" \
    --bs="${FIO_BS}" \
    --numjobs="${FIO_NUMJOBS}" \
    --runtime="${FIO_RUNTIME_SEC}" \
    --time_based \
    --group_reporting || true

  run_cmd "3.2 fio READ bandwidth" "${fio_bin}" \
    --name=ram_read \
    --ioengine=memory \
    --rw=read \
    --size="${fio_size}" \
    --bs="${FIO_BS}" \
    --numjobs="${FIO_NUMJOBS}" \
    --runtime="${FIO_RUNTIME_SEC}" \
    --time_based \
    --group_reporting || true

  banner "Interpretation"
  echo "  • Compare the MiB/s numbers between DIMMs under the same BIOS settings."
  echo "  • With ONE DIMM installed, expect single-channel bandwidth (lower than dual-DIMM)."
  echo "  • Big deviations (30%+) between similar DIMMs are suspicious."
}

final_summary() {
  banner "Final Summary"
  ok "Log file saved at: ${LOG_FILE}"
  echo
  echo "${C_BOLD}Buy / Don't Buy quick rule:${C_RESET}"
  echo "  ✅ BUY if:"
  echo "     - stress-ng verify shows ZERO errors"
  echo "     - memtester shows ZERO errors"
  echo "     - fio READ/WRITE MiB/s looks consistent vs your other DIMM"
  echo
  echo "  ❌ DON'T BUY if:"
  echo "     - Any stress-ng verify errors"
  echo "     - Any memtester errors"
  echo "     - System freezes/reboots during tests"
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
  echo "Expectations:"
  echo "  - Testing ONE DIMM at a time (expected populated slots: ${EXPECTED_DIMM_COUNT})"
  echo "  - Expected DIMM size hint (SMBIOS): ${EXPECTED_DIMM_SIZE_GB} GB"
  echo
  echo "Tip:"
  echo "  - For a 16GB stick: set EXPECTED_DIMM_SIZE_GB=\"16\" at top and rerun."
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

  step3_fio_ram_bandwidth
  pause

  final_summary
}

main "$@"
