#!/usr/bin/env bash
# ==============================================================================
# RAM / CPU QUICK INSPECTION SCRIPT (Fedora Desktop 43 / Fedora Workstation)
# ------------------------------------------------------------------------------
# Focus: Validate used RAM DIMM legitimacy (capacity + stability + bandwidth)
# Testing: ONE DIMM AT A TIME (your motherboard limitation)
#
# Includes:
#   - Slot-level DIMM validation (dmidecode)
#   - stress-ng verify
#   - memtester (time-limited, percentage-based)
#   - STREAM benchmark (preferred over sysbench for real memory bandwidth)
#
# Usage:
#   chmod +x ram_inspect_fedora43.sh
#   sudo ./ram_inspect_fedora43.sh
# ==============================================================================

set -Eeuo pipefail
export PATH="/sbin:/usr/sbin:/bin:/usr/bin:$PATH"

# ---------------------------
# Configuration (tune here)
# ---------------------------

EXPECTED_DIMM_COUNT="1"
EXPECTED_DIMM_SIZE_GB="32"          # you will test 16GB today, 32GB tomorrow -> you can edit per run

# stress-ng verify
VM_WORKERS="2"
VM_BYTES_PERCENT="85%"
VERIFY_TIMEOUT="7m"

# memtester (fast, time-limited, percent-based)
MEMTESTER_PERCENT="85"              # % of MemAvailable to lock
MEMTESTER_PASSES="9999"             # huge; we time-limit with timeout
MEMTESTER_TIME_LIMIT="7m"           # target 5–7 minutes

# STREAM benchmark
STREAM_OMP_THREADS="4"              # OMP threads used by STREAM (set to your CPU cores if desired)
STREAM_TIME_LIMIT="2m"              # STREAM itself is quick; this is a safety cap
STREAM_WORKDIR="./stream_build"     # where we compile/run STREAM if not available as a package
STREAM_MIN_ARRAY_MB="1024"          # ensure arrays are big enough to exceed cache
STREAM_MAX_ARRAY_MB_PERCENT="35"    # cap total STREAM arrays to % of MemAvailable (safety)

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

  # Required CLI tools
  local cli_pkgs=(
    stress-ng
    dmidecode
    hwinfo
    lshw
    util-linux
    memtester
    gcc
    make
    curl
    wget
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

  # STREAM: try to install as a package if it exists; if not, we will compile later.
  banner "Step 0A: STREAM availability check"
  info "Trying: dnf install -y stream (may not exist in Fedora repos)"
  set +e
  dnf install -y stream
  local stream_pkg_rc=$?
  set -e
  if [[ $stream_pkg_rc -eq 0 ]]; then
    ok "Installed STREAM from repos (stream)."
  else
    warn "Package 'stream' not available in your repos. We'll compile STREAM from source automatically later."
  fi

  echo
  ok "Installed versions (best effort):"
  echo "  stress-ng: $(stress-ng --version 2>/dev/null | head -n 1 || echo 'unknown')"
  echo "  dmidecode: $(dmidecode --version 2>/dev/null || echo 'unknown')"
  echo "  memtester: $(memtester 2>/dev/null | head -n 1 || echo 'unknown')"
  echo "  gcc:       $(gcc --version 2>/dev/null | head -n 1 || echo 'unknown')"
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
# Step 1A: Basic system identity
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
  banner "Step 1B: Slot-level DIMM validation (prove 1x DIMM + size)"

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

  local populated_count
  populated_count="$(grep -c '^SLOT_OK=1$' "${tmp_out}" 2>/dev/null || echo "0")"

  echo
  info "Populated slot count detected: ${populated_count}"
  echo

  if [[ "${populated_count}" -ne "${EXPECTED_DIMM_COUNT}" ]]; then
    warn "Expected ${EXPECTED_DIMM_COUNT} populated slot(s), but detected ${populated_count}."
    warn "If you are truly testing a single stick, this may indicate BIOS/board reporting oddities."
  else
    ok "Populated slot count matches expectation (${EXPECTED_DIMM_COUNT})."
  fi

  rm -f "${tmp_out}"

  banner "Reminder"
  echo "  • SMBIOS size reporting is helpful, but the REAL proof is:"
  echo "    - stress-ng verify (Step 2)"
  echo "    - memtester (Step 2B)"
}

# ---------------------------
# Step 1C: More identity tools
# ---------------------------
step1c_identity_and_speed_tools() {
  banner "Step 1C: Identity / speed tools (dmidecode, hwinfo, lshw)"

  local dmi hwi lshw_bin
  if dmi="$(find_cmd dmidecode)"; then
    run_cmd "1C.1 dmidecode highlights" bash -lc \
      "${dmi} -t memory | grep -E 'Size:|Locator:|Manufacturer:|Part Number:|Serial Number:|Rank:|Data Width:|Total Width:|Configured Memory Speed|Speed:' || true" || true
  fi

  if hwi="$(find_cmd hwinfo)"; then
    run_cmd "1C.2 hwinfo --memory" "${hwi}" --memory || true
  fi

  if lshw_bin="$(find_cmd lshw)"; then
    run_cmd "1C.3 lshw -class memory" "${lshw_bin}" -class memory || true
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
  banner "Step 2B: Fast random address-space test (memtester, 85% MemAvailable)"

  local memtester_bin
  memtester_bin="$(find_cmd memtester)" || {
    warn "memtester not found. Skipping Step 2B."
    return 0
  }

  local mem_avail_kb mem_avail_mb mem_to_test_mb
  mem_avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
  mem_avail_mb=$(( mem_avail_kb / 1024 ))
  mem_to_test_mb=$(( mem_avail_mb * MEMTESTER_PERCENT / 100 ))

  # Safety bounds so it doesn't get silly on tiny/huge systems
  if [[ "${mem_to_test_mb}" -lt 6144 ]]; then mem_to_test_mb=6144; fi
  # cap to keep it around your 5–7 minute goal even on large RAM
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
# Step 3: STREAM benchmark (preferred over sysbench)
# ---------------------------

stream_download_stream_c() {
  # Download STREAM.c from the official STREAM repo on GitHub.
  # We do best-effort with curl/wget. If no network, user can manually place STREAM.c.
  local url="https://raw.githubusercontent.com/jeffhammond/STREAM/master/stream.c"
  local out="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${out}"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "${out}" "${url}"
    return 0
  fi

  return 1
}

stream_compute_array_size() {
  # STREAM uses 3 arrays (a,b,c) of doubles by default.
  # bytes_total ≈ 3 * N * 8  (ignoring minor overhead)
  #
  # We choose total bytes = min( MemAvailable * STREAM_MAX_ARRAY_MB_PERCENT%, cap ) but >= STREAM_MIN_ARRAY_MB.
  local mem_avail_kb mem_avail_mb max_total_mb target_total_mb
  mem_avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
  mem_avail_mb=$(( mem_avail_kb / 1024 ))

  max_total_mb=$(( mem_avail_mb * STREAM_MAX_ARRAY_MB_PERCENT / 100 ))

  # Ensure at least STREAM_MIN_ARRAY_MB total footprint for out-of-cache behavior
  target_total_mb="${max_total_mb}"
  if [[ "${target_total_mb}" -lt "${STREAM_MIN_ARRAY_MB}" ]]; then
    target_total_mb="${STREAM_MIN_ARRAY_MB}"
  fi

  # Convert total MB to bytes, then solve for N:
  # total_bytes = target_total_mb * 1024 * 1024
  # N = total_bytes / (3 * 8)
  local total_bytes n
  total_bytes=$(( target_total_mb * 1024 * 1024 ))
  n=$(( total_bytes / 24 ))

  # STREAM requires N >= 1
  if [[ "${n}" -lt 1 ]]; then n=1; fi

  echo "${n}"
}

step3_stream_bandwidth() {
  banner "Step 3: STREAM benchmark (sustained memory bandwidth)"

  # If a "stream" binary exists, try it first (some distros package it).
  # If not, compile from source.
  local stream_bin=""
  if command -v stream >/dev/null 2>&1; then
    stream_bin="$(command -v stream)"
    ok "Found STREAM binary: ${stream_bin}"
  fi

  mkdir -p "${STREAM_WORKDIR}"

  if [[ -z "${stream_bin}" ]]; then
    info "No packaged STREAM binary detected. Compiling STREAM from source..."

    local cfile="${STREAM_WORKDIR}/stream.c"
    if [[ ! -f "${cfile}" ]]; then
      info "Downloading STREAM source to: ${cfile}"
      if ! stream_download_stream_c "${cfile}"; then
        fail "Could not download STREAM.c (no curl/wget or no network)."
        echo "Workaround:"
        echo "  1) Download stream.c manually from the STREAM repo"
        echo "  2) Place it here: ${cfile}"
        echo "  3) Re-run the script"
        return 0
      fi
    else
      info "Using existing source: ${cfile}"
    fi

    local n
    n="$(stream_compute_array_size)"

    info "Computed STREAM_ARRAY_SIZE (N): ${n}"
    info "OMP threads: ${STREAM_OMP_THREADS}"
    echo

    # Build:
    # -O3: optimize
    # -fopenmp: enable OpenMP (STREAM uses it)
    # -DSTREAM_ARRAY_SIZE: force arrays big enough for out-of-cache bandwidth
    # -mcmodel=large is sometimes needed for huge arrays; we keep arrays modest, so usually not needed
    local outbin="${STREAM_WORKDIR}/stream"
    run_cmd "3.1 Compile STREAM" gcc -O3 -fopenmp \
      -DSTREAM_ARRAY_SIZE="${n}" \
      -o "${outbin}" "${cfile}" || true

    if [[ -x "${outbin}" ]]; then
      stream_bin="${outbin}"
      ok "STREAM compiled: ${stream_bin}"
    else
      fail "STREAM compile failed. Check compiler output above."
      return 0
    fi
  fi

  banner "Running STREAM"
  echo "This reports sustainable memory bandwidth for Copy/Scale/Add/Triad kernels."
  echo "OpenMP threads: ${STREAM_OMP_THREADS}"
  echo "Time limit:     ${STREAM_TIME_LIMIT}"
  echo

  # Run STREAM with a safety timeout.
  # Note: STREAM prints results; we keep output as-is for your log comparisons between DIMMs.
  run_cmd "3.2 Run STREAM" bash -lc \
    "export OMP_NUM_THREADS='${STREAM_OMP_THREADS}'; timeout '${STREAM_TIME_LIMIT}' '${stream_bin}'" || true

  banner "Interpretation (what to look at)"
  echo "  • Focus on the 'Triad' bandwidth (MB/s) as a common reference."
  echo "  • Compare results between DIMMs: they should be close (±10–15%)."
  echo "  • If XMP/EXPO is enabled, bandwidth should generally be higher."
}

final_summary() {
  banner "Final Summary"
  ok "Log file saved at: ${LOG_FILE}"
  echo
  echo "${C_BOLD}Buy / Don't Buy quick rule:${C_RESET}"
  echo "  ✅ BUY if:"
  echo "     - stress-ng verify shows ZERO errors"
  echo "     - memtester shows ZERO errors"
  echo "     - STREAM bandwidth looks consistent across DIMMs"
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
  echo "  - Expected DIMM size (SMBIOS hint): ${EXPECTED_DIMM_SIZE_GB} GB"
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

  step3_stream_bandwidth
  pause

  final_summary
}

main "$@"
