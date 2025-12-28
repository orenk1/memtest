#!/usr/bin/env bash
# ==============================================================================
# RAM / CPU QUICK INSPECTION SCRIPT (Fedora Desktop 43 / Fedora Workstation)
# ------------------------------------------------------------------------------
# Purpose:
#   Verify a used RAM DIMM is legit (real capacity, stable, sane SPD, meaningful
#   sustained bandwidth). Designed for testing ONE DIMM at a time.
#
# Key tests:
#   - Slot-level DIMM validation (dmidecode): proves how BIOS reports the stick
#   - stress-ng --verify: correctness under heavy load (strong counterfeit detector)
#   - memtester (time-limited, percent-based): random-ish patterns + address sanity
#   - STREAM benchmark (classic Copy/Scale/Add/Triad): meaningful RAM bandwidth
#
# IMPORTANT FIX:
#   Fedora may already have a different program named "stream" that requires args.
#   This script NEVER calls "stream". It ALWAYS compiles the classic STREAM
#   benchmark from stream.c and runs it as ./stream_bench to avoid collisions.
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

# You can change this per run:
# - Today you test 16GB: set EXPECTED_DIMM_SIZE_GB="16"
# - Tomorrow you test 32GB: set EXPECTED_DIMM_SIZE_GB="32"
EXPECTED_DIMM_COUNT="1"
EXPECTED_DIMM_SIZE_GB="32"

# stress-ng verify (stability / correctness)
VM_WORKERS="2"
VM_BYTES_PERCENT="85%"         # safer than 90% on desktop systems
VERIFY_TIMEOUT="7m"            # increase to 10–20m for more confidence

# memtester (fast, time-limited, percent-based)
MEMTESTER_PERCENT="85"         # % of MemAvailable to lock
MEMTESTER_PASSES="9999"        # huge; we stop via timeout
MEMTESTER_TIME_LIMIT="7m"      # target 5–7 minutes

# STREAM (classic benchmark)
STREAM_OMP_THREADS="4"         # 1 DIMM => single-channel; threads still help saturate
STREAM_TIME_LIMIT="2m"         # STREAM is usually quick; this is just a guard
STREAM_WORKDIR="./stream_build"
STREAM_MIN_ARRAY_MB="1024"     # arrays must exceed cache (at least ~1GB total footprint)
STREAM_MAX_ARRAY_MB_PERCENT="35"  # cap total STREAM footprint to % of MemAvailable (safety)

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
  # dmidecode + installs require root.
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

  # Don't kill the whole script on one command failure
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
  # CPU-X is sometimes easier to get with RPM Fusion.
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

  # Core CLI tools (required)
  # - curl/wget: used to download stream.c automatically if network is available
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

  # Safety bounds:
  # - Minimum ensures the test is still meaningful.
  # - Maximum keeps runtime in your 5–7 minute range on bigger RAM machines.
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
# STREAM helpers (classic benchmark)
# ---------------------------
stream_download_stream_c() {
  # Download the classic STREAM source file (stream.c).
  # If your machine has no network, you can manually place stream.c in STREAM_WORKDIR.
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
  # Total bytes ~ 3 * N * 8 = 24*N.
  #
  # We choose a total footprint based on MemAvailable:
  #   total_mb = max(STREAM_MIN_ARRAY_MB, MemAvailable * STREAM_MAX_ARRAY_MB_PERCENT%)
  #
  # Then N = total_bytes / 24.
  local mem_avail_kb mem_avail_mb max_total_mb target_total_mb total_bytes n

  mem_avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
  mem_avail_mb=$(( mem_avail_kb / 1024 ))

  max_total_mb=$(( mem_avail_mb * STREAM_MAX_ARRAY_MB_PERCENT / 100 ))
  target_total_mb="${max_total_mb}"

  if [[ "${target_total_mb}" -lt "${STREAM_MIN_ARRAY_MB}" ]]; then
    target_total_mb="${STREAM_MIN_ARRAY_MB}"
  fi

  total_bytes=$(( target_total_mb * 1024 * 1024 ))
  n=$(( total_bytes / 24 ))

  if [[ "${n}" -lt 1 ]]; then n=1; fi
  echo "${n}"
}

# ---------------------------
# Step 3: STREAM benchmark (collision-proof)
# ---------------------------
step3_stream_bandwidth() {
  banner "Step 3: STREAM benchmark (classic Copy/Scale/Add/Triad) - collision-proof"

  mkdir -p "${STREAM_WORKDIR}"
  local cfile="${STREAM_WORKDIR}/stream.c"
  local outbin="${STREAM_WORKDIR}/stream_bench"

  # Ensure we have stream.c
  if [[ ! -f "${cfile}" ]]; then
    info "Downloading classic STREAM source to: ${cfile}"
    if ! stream_download_stream_c "${cfile}"; then
      fail "Could not download STREAM.c (no curl/wget or no network)."
      echo "Workaround (manual):"
      echo "  1) Download stream.c from the STREAM GitHub repo on another machine"
      echo "  2) Copy it to: ${cfile}"
      echo "  3) Re-run the script"
      return 0
    fi
  else
    info "Using existing source: ${cfile}"
  fi

  # Compute a safe array size
  local n
  n="$(stream_compute_array_size)"

  info "Computed STREAM_ARRAY_SIZE (N): ${n}"
  info "OMP_NUM_THREADS: ${STREAM_OMP_THREADS}"
  echo

  # Compile STREAM into a uniquely named local binary to avoid collisions with any "stream" command.
  run_cmd "3.1 Compile STREAM benchmark (stream_bench)" gcc -O3 -fopenmp \
    -DSTREAM_ARRAY_SIZE="${n}" \
    -DNTIMES=10 \
    -o "${outbin}" "${cfile}" || true

  if [[ ! -x "${outbin}" ]]; then
    fail "STREAM compile failed. Check output above."
    return 0
  fi

  banner "Running STREAM benchmark"
  echo "Expected output includes: Copy / Scale / Add / Triad"
  echo "OMP threads: ${STREAM_OMP_THREADS}"
  echo "Time limit:  ${STREAM_TIME_LIMIT}"
  echo

  run_cmd "3.2 Run STREAM benchmark" bash -lc \
    "export OMP_NUM_THREADS='${STREAM_OMP_THREADS}'; timeout '${STREAM_TIME_LIMIT}' '${outbin}'" || true

  banner "Interpretation"
  echo "  • Focus on the 'Triad' bandwidth (MB/s)."
  echo "  • Compare DIMMs under the same BIOS settings; results should be close (±10–15%)."
  echo "  • With only ONE DIMM installed, you should expect single-channel bandwidth."
}

final_summary() {
  banner "Final Summary"
  ok "Log file saved at: ${LOG_FILE}"
  echo
  echo "${C_BOLD}Buy / Don't Buy quick rule:${C_RESET}"
  echo "  ✅ BUY if:"
  echo "     - stress-ng verify shows ZERO errors"
  echo "     - memtester shows ZERO errors"
  echo "     - STREAM output prints Copy/Scale/Add/Triad and looks consistent vs other DIMM"
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
  echo "  - For a 16GB stick today: set EXPECTED_DIMM_SIZE_GB=\"16\" at top and rerun."
  echo
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
