#!/usr/bin/env bash
# Intelligent SMART Test Scheduler for Proxmox (SATA via smartctl, NVMe via nvme-cli)
# - Uses /dev/disk/by-id (stable) instead of /dev/sdX
# - Skips while ZFS scrub/resilver is running
# - Supports concurrency for SHORT tests
# - ROTATES one HDD for LONG tests per run (recommended for big RAIDZ vdevs)
# Version 1.1.1 (Cron-safe PATH + resolved tool paths)

set -euo pipefail
IFS=$'\n\t'
export LC_ALL=C

# Cron often has a minimal PATH; make it predictable.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Resolve commonly used tools once (cron-proof)
SMARTCTL="$(command -v smartctl || true)"
NVME="$(command -v nvme || true)"
ZPOOL="$(command -v zpool || true)"
CURL="$(command -v curl || true)"
MAIL="$(command -v mail || true)"

# =============================================================================
# CONFIGURATION (override via env)
# =============================================================================

# Test type: short | long
TEST_TYPE="${TEST_TYPE:-short}"

# Rotation mode for long tests:
# - true  : only run long test on ONE HDD per run (rotating)
# - false : run long test on ALL HDDs (honors MAX_CONCURRENT)
ROTATE_LONG_TESTS="${ROTATE_LONG_TESTS:-true}"

# Include NVMe tests on long runs as well
INCLUDE_NVME_ON_LONG="${INCLUDE_NVME_ON_LONG:-true}"

# Maximum concurrent tests (for SHORT, or for LONG when ROTATE_LONG_TESTS=false)
MAX_CONCURRENT="${MAX_CONCURRENT:-2}"

# For LONG tests, default to 1 unless user overrides MAX_CONCURRENT explicitly
DEFAULT_MAX_CONCURRENT_LONG="${DEFAULT_MAX_CONCURRENT_LONG:-1}"

# Skip if system load is too high (1-min loadavg)
MAX_LOAD="${MAX_LOAD:-4.0}"

# State directory/file for rotation
STATE_DIR="${STATE_DIR:-/var/lib/smart-test-scheduler}"
STATE_FILE="${STATE_FILE:-/var/lib/smart-test-scheduler/state_hdd_index}"

# Log file
LOGFILE="${LOGFILE:-/var/log/smart-test-scheduler.log}"

# Notifications (optional)
EMAIL="${EMAIL:-}"
SEND_EMAIL="${SEND_EMAIL:-false}"     # true/false. Uses `mail` command if enabled.
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
DISCORD_ENABLED="${DISCORD_ENABLED:-false}"

# Optional: restrict tests to disks that are members of ZFS pools only (true/false)
ONLY_ZFS_MEMBER_DISKS="${ONLY_ZFS_MEMBER_DISKS:-false}"

# =============================================================================
# UTIL / LOGGING
# =============================================================================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

# We keep have() for any other commands, but prefer resolved vars above.
have() { command -v "$1" >/dev/null 2>&1; }

mkdirs() {
  mkdir -p "$(dirname "$LOGFILE")" || true
  mkdir -p "$STATE_DIR" || true
  touch "$LOGFILE" 2>/dev/null || true
}

# =============================================================================
# ZFS GUARDS
# =============================================================================
check_zfs_activity() {
  # If zpool isn't present, no guard needed.
  [[ -n "${ZPOOL:-}" ]] || return 0

  local pools pool status
  pools="$("$ZPOOL" list -H -o name 2>/dev/null || true)"
  [ -n "$pools" ] || return 0

  while read -r pool; do
    [ -n "$pool" ] || continue
    status="$("$ZPOOL" status "$pool" 2>/dev/null || true)"

    if echo "$status" | grep -qE "scan: (scrub|resilver) in progress"; then
      log "ZFS scan in progress on pool '$pool' - skipping SMART tests"
      return 1
    fi
  done <<< "$pools"

  return 0
}

# =============================================================================
# LOAD GUARD
# =============================================================================
check_system_load() {
  local load
  load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0.0)"

  # compare floats using awk (no bc dependency)
  if awk -v a="$load" -v b="$MAX_LOAD" 'BEGIN{exit (a>b)?0:1}'; then
    log "System load too high ($load > $MAX_LOAD) - skipping SMART tests"
    return 1
  fi
  return 0
}

# =============================================================================
# DISK DISCOVERY (by-id)
# =============================================================================

# Return stable by-id paths for HDD/SATA/SAS disks (ata-*, excludes partitions)
discover_hdd_byid() {
  local id base
  for id in /dev/disk/by-id/ata-*; do
    [ -L "$id" ] || continue
    base="$(basename "$id")"
    case "$base" in
      *-part* ) continue ;;
    esac
    printf '%s\n' "$id"
  done
}

# Return stable by-id paths for NVMe disks:
# Prefer nvme-eui.* if present; otherwise use nvme-<model> entries (exclude partitions).
discover_nvme_byid() {
  local found_eui=0 id base

  for id in /dev/disk/by-id/nvme-eui.*; do
    if [ -L "$id" ]; then found_eui=1; break; fi
  done

  if [ "$found_eui" -eq 1 ]; then
    for id in /dev/disk/by-id/nvme-eui.*; do
      [ -L "$id" ] || continue
      base="$(basename "$id")"
      case "$base" in
        *-part* ) continue ;;
      esac
      printf '%s\n' "$id"
    done
    return 0
  fi

  for id in /dev/disk/by-id/nvme-*; do
    [ -L "$id" ] || continue
    base="$(basename "$id")"
    case "$base" in
      *-part* ) continue ;;
      nvme-eui.* ) continue ;;
    esac
    printf '%s\n' "$id"
  done
}

discover_all_byid() {
  { discover_hdd_byid; discover_nvme_byid; } | awk 'NF' | sort -u
}

# Optionally filter to only disks that appear in any zpool status output
filter_to_zfs_members() {
  [[ -n "${ZPOOL:-}" ]] || { cat; return 0; }

  local tmp
  tmp="$(mktemp)"
  "$ZPOOL" status 2>/dev/null | awk '{print $1}' | grep -E '^(ata-|nvme-)' | sort -u >"$tmp" || true

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if grep -qx "$(basename "$id")" "$tmp"; then
      printf '%s\n' "$id"
    fi
  done

  rm -f "$tmp" 2>/dev/null || true
}

id_to_dev() { readlink -f "$1" 2>/dev/null || true; }

# =============================================================================
# TEST IN-PROGRESS CHECKS
# =============================================================================
sata_is_testing() {
  local dev="$1"
  "$SMARTCTL" -a "$dev" 2>/dev/null | grep -qE "Self-test execution status:.*in progress"
}

# NVMe: best-effort. Some firmware doesn't support log; treat errors as "unknown/not testing".
nvme_is_testing() {
  local dev="$1"
  [[ -n "${NVME:-}" ]] || return 1
  local out
  out="$("$NVME" self-test-log "$dev" 2>/dev/null || true)"
  echo "$out" | grep -qiE "in progress|operation.*in progress"
}

count_active_tests() {
  local count=0 id dev
  while IFS= read -r id; do
    dev="$(id_to_dev "$id")"
    [ -n "$dev" ] || continue
    if [[ "$dev" == /dev/nvme* ]]; then
      if nvme_is_testing "$dev"; then count=$((count+1)); fi
    else
      if sata_is_testing "$dev"; then count=$((count+1)); fi
    fi
  done <<< "$(discover_all_byid)"
  echo "$count"
}

# =============================================================================
# START TESTS
# =============================================================================
start_sata_test() {
  local id="$1" type="$2" dev
  dev="$(id_to_dev "$id")"
  [ -n "$dev" ] || { log "WARN: cannot resolve $id"; return 1; }

  if sata_is_testing "$dev"; then
    log "Skip (already testing): $id -> $dev"
    return 2
  fi

  log "Start SATA $type test: $id -> $dev"
  if "$SMARTCTL" -t "$type" "$dev" >/dev/null 2>&1; then
    log "OK: started $type on $dev"
    return 0
  else
    log "ERROR: failed to start $type on $dev"
    return 1
  fi
}

start_nvme_test() {
  local id="$1" type="$2" dev code
  dev="$(id_to_dev "$id")"
  [ -n "$dev" ] || { log "WARN: cannot resolve $id"; return 1; }

  case "$type" in
    short) code=1 ;;
    long)  code=2 ;;
    *) log "ERROR: invalid TEST_TYPE '$type'"; return 1 ;;
  esac

  if [[ -z "${NVME:-}" ]]; then
    log "WARN: nvme-cli not installed; skipping NVMe test for $id"
    return 2
  fi

  if nvme_is_testing "$dev"; then
    log "Skip (NVMe test appears in progress): $id -> $dev"
    return 2
  fi

  log "Start NVMe $type device-self-test: $id -> $dev (code=$code)"
  if "$NVME" device-self-test "$dev" --self-test-code="$code" >/dev/null 2>&1; then
    log "OK: started NVMe $type on $dev"
    return 0
  else
    log "WARN: nvme-cli could not start $type on $dev (may be unsupported or already running)"
    return 1
  fi
}

# =============================================================================
# ROTATION (HDD long test)
# =============================================================================
get_hdd_rotation_index() {
  if [ -f "$STATE_FILE" ]; then
    awk 'NR==1{print $1; exit}' "$STATE_FILE" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

set_hdd_rotation_index() {
  local idx="$1"
  echo "$idx" >"$STATE_FILE"
}

pick_next_hdd_for_rotation() {
  local -a hdds=()
  local id idx next

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    hdds+=("$id")
  done <<< "$(discover_hdd_byid | ( [[ "$ONLY_ZFS_MEMBER_DISKS" == "true" ]] && filter_to_zfs_members || cat ) | sort -u)"

  if [ "${#hdds[@]}" -eq 0 ]; then
    return 1
  fi

  idx="$(get_hdd_rotation_index)"
  if ! [[ "$idx" =~ ^[0-9]+$ ]]; then idx=0; fi

  next=$(( idx % ${#hdds[@]} ))
  echo "${hdds[$next]}"

  set_hdd_rotation_index $((next+1))
}

# =============================================================================
# NOTIFICATIONS
# =============================================================================
send_notification() {
  local subject="$1" message="$2" severity="$3"  # OK|WARN|CRIT

  if [[ "$SEND_EMAIL" == "true" && -n "${EMAIL}" ]]; then
    if [[ -n "${MAIL:-}" ]]; then
      echo "$message" | "$MAIL" -s "$subject" "$EMAIL" 2>/dev/null || true
    else
      log "WARN: mail command not found; cannot email notification"
    fi
  fi

  if [[ "$DISCORD_ENABLED" == "true" && -n "${DISCORD_WEBHOOK}" ]]; then
    local color=3066993
    case "$severity" in
      WARN) color=15105570 ;;
      CRIT) color=15158332 ;;
    esac

    local esc_msg
    esc_msg="${message//\\/\\\\}"
    esc_msg="${esc_msg//\"/\\\"}"

    if [[ -n "${CURL:-}" ]]; then
      "$CURL" -s -X POST "$DISCORD_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "{
          \"username\":\"SMART Test Scheduler\",
          \"embeds\":[{
            \"title\":\"${subject}\",
            \"description\":\"${esc_msg}\",
            \"color\":${color},
            \"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"
          }]
        }" >/dev/null 2>&1 || true
    else
      log "WARN: curl not found; cannot send Discord notification"
    fi
  fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  mkdirs
  log "=== SMART Test Scheduler Started ==="
  log "TEST_TYPE=${TEST_TYPE}  ROTATE_LONG_TESTS=${ROTATE_LONG_TESTS}  ONLY_ZFS_MEMBER_DISKS=${ONLY_ZFS_MEMBER_DISKS}"
  log "PATH=${PATH}"

  if [[ -z "${SMARTCTL:-}" ]]; then
    log "ERROR: smartctl not found in PATH. Install: apt update && apt install smartmontools"
    exit 1
  fi

  if ! check_zfs_activity; then
    log "Abort: ZFS activity detected."
    exit 0
  fi
  if ! check_system_load; then
    log "Abort: Load too high."
    exit 0
  fi

  # Long test default concurrency to 1 unless user overrides MAX_CONCURRENT
  if [[ "$TEST_TYPE" == "long" && -z "${MAX_CONCURRENT_SET_BY_USER:-}" ]]; then
    MAX_CONCURRENT="$DEFAULT_MAX_CONCURRENT_LONG"
  fi

  local started=0 skipped=0 failed=0
  local -a started_list=() skipped_list=() failed_list=()

  local hdd_list nvme_list
  hdd_list="$(discover_hdd_byid | ( [[ "$ONLY_ZFS_MEMBER_DISKS" == "true" ]] && filter_to_zfs_members || cat ) | sort -u)"
  nvme_list="$(discover_nvme_byid | ( [[ "$ONLY_ZFS_MEMBER_DISKS" == "true" ]] && filter_to_zfs_members || cat ) | sort -u)"

  log "HDD by-id count: $(echo "$hdd_list" | awk 'NF' | wc -l)"
  log "NVMe by-id count: $(echo "$nvme_list" | awk 'NF' | wc -l)"

  if [[ "$TEST_TYPE" == "long" && "$ROTATE_LONG_TESTS" == "true" ]]; then
    # Rotate ONE HDD per run
    local pick rc
    if pick="$(pick_next_hdd_for_rotation)"; then
      while [[ "$(count_active_tests)" -ge "$MAX_CONCURRENT" ]]; do
        log "Waiting for test slots (max: $MAX_CONCURRENT)..."
        sleep 60
      done

      set +e
      start_sata_test "$pick" long
      rc=$?
      set -e
      if [ "$rc" -eq 0 ]; then
        started=$((started+1)); started_list+=("HDD long: $(basename "$pick")")
      elif [ "$rc" -eq 2 ]; then
        skipped=$((skipped+1)); skipped_list+=("HDD long (busy): $(basename "$pick")")
      else
        failed=$((failed+1)); failed_list+=("HDD long (fail): $(basename "$pick")")
      fi
    else
      log "WARN: No HDDs discovered for long rotation."
    fi

    # NVMe long tests (optional)
    if [[ "$INCLUDE_NVME_ON_LONG" == "true" ]]; then
      local id rc
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        while [[ "$(count_active_tests)" -ge "$MAX_CONCURRENT" ]]; do
          log "Waiting for test slots (max: $MAX_CONCURRENT)..."
          sleep 60
        done

        set +e
        start_nvme_test "$id" long
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then
          started=$((started+1)); started_list+=("NVMe long: $(basename "$id")")
        elif [ "$rc" -eq 2 ]; then
          skipped=$((skipped+1)); skipped_list+=("NVMe long (skip): $(basename "$id")")
        else
          failed=$((failed+1)); failed_list+=("NVMe long (fail): $(basename "$id")")
        fi
      done <<< "$nvme_list"
    fi

  else
    # Short (or long without rotation): all disks
    local id rc
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      while [[ "$(count_active_tests)" -ge "$MAX_CONCURRENT" ]]; do
        log "Waiting for test slots (max: $MAX_CONCURRENT)..."
        sleep 60
      done

      set +e
      start_sata_test "$id" "$TEST_TYPE"
      rc=$?
      set -e
      if [ "$rc" -eq 0 ]; then
        started=$((started+1)); started_list+=("SATA ${TEST_TYPE}: $(basename "$id")")
        if [[ "$TEST_TYPE" == "long" ]]; then sleep 120; fi
      elif [ "$rc" -eq 2 ]; then
        skipped=$((skipped+1)); skipped_list+=("SATA ${TEST_TYPE} (busy): $(basename "$id")")
      else
        failed=$((failed+1)); failed_list+=("SATA ${TEST_TYPE} (fail): $(basename "$id")")
      fi
    done <<< "$hdd_list"

    while IFS= read -r id; do
      [ -n "$id" ] || continue
      while [[ "$(count_active_tests)" -ge "$MAX_CONCURRENT" ]]; do
        log "Waiting for test slots (max: $MAX_CONCURRENT)..."
        sleep 60
      done

      set +e
      start_nvme_test "$id" "$TEST_TYPE"
      rc=$?
      set -e
      if [ "$rc" -eq 0 ]; then
        started=$((started+1)); started_list+=("NVMe ${TEST_TYPE}: $(basename "$id")")
      elif [ "$rc" -eq 2 ]; then
        skipped=$((skipped+1)); skipped_list+=("NVMe ${TEST_TYPE} (skip): $(basename "$id")")
      else
        failed=$((failed+1)); failed_list+=("NVMe ${TEST_TYPE} (fail): $(basename "$id")")
      fi
    done <<< "$nvme_list"
  fi

  local severity="OK"
  if [ "$failed" -gt 0 ]; then severity="CRIT"
  elif [ "$skipped" -gt 0 ]; then severity="WARN"
  fi

  log "=== SMART Test Scheduler Completed ==="
  log "Started: $started  Skipped: $skipped  Failed: $failed"
  if [ "${#started_list[@]}" -gt 0 ]; then log "Started items: ${started_list[*]}"; fi
  if [ "${#skipped_list[@]}" -gt 0 ]; then log "Skipped items: ${skipped_list[*]}"; fi
  if [ "${#failed_list[@]}" -gt 0 ]; then log "Failed items: ${failed_list[*]}"; fi

  local host subject msg
  host="$(hostname -f 2>/dev/null || hostname)"
  subject="SMART Test Scheduler (${TEST_TYPE}) - ${host}"
  msg="Host: ${host}
Type: ${TEST_TYPE}
Rotate long HDD: ${ROTATE_LONG_TESTS}
Include NVMe on long: ${INCLUDE_NVME_ON_LONG}
Started: ${started}
Skipped: ${skipped}
Failed: ${failed}"

  if [ "${#started_list[@]}" -gt 0 ]; then
    msg="${msg}

Started:
- $(printf '%s\n' "${started_list[@]}" | sed 's/$/\n- /' | sed '$d')"
  fi
  if [ "${#skipped_list[@]}" -gt 0 ]; then
    msg="${msg}

Skipped:
- $(printf '%s\n' "${skipped_list[@]}" | sed 's/$/\n- /' | sed '$d')"
  fi
  if [ "${#failed_list[@]}" -gt 0 ]; then
    msg="${msg}

Failed:
- $(printf '%s\n' "${failed_list[@]}" | sed 's/$/\n- /' | sed '$d')"
  fi

  send_notification "$subject" "$msg" "$severity"
  log "Done."
}

# Track if MAX_CONCURRENT was set by env explicitly (best-effort)
if [ "${MAX_CONCURRENT:-}" != "2" ]; then
  export MAX_CONCURRENT_SET_BY_USER=1
fi

main "$@"
