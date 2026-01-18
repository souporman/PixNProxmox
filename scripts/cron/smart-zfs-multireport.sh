#!/usr/bin/env bash
# Proxmox Multi-Report
# by Scott
# Version 1.0.3 (Cron-safe PATH + resolved binary paths; uses SMARTCTL/ZPOOL/CURL/MSMTP vars)

set -euo pipefail
IFS=$'\n\t'

# Cron usually has a tiny PATH; make it sane for Proxmox/Debian.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Resolve commonly-used binaries once (safer + faster + cron-proof)
SMARTCTL="$(command -v smartctl || true)"
ZPOOL="$(command -v zpool || true)"
CURL="$(command -v curl || true)"
MSMTP="$(command -v msmtp || true)"
PVEVERSION="$(command -v pveversion || true)"

# ============================================================================
# CONFIGURATION - Edit these or set via environment variables
# ============================================================================

# Email Configuration
email="${email:-email@email.com}"
subject_prefix="${subject_prefix:-Proxmox SMART/ZFS Multi-Report}"

# Discord Configuration
discord_webhook="${discord_webhook:-https://discord.com/api/webhooks/}"  # Set to your webhook URL to enable Discord
discord_enabled="${discord_enabled:-true}"

# Only send Discord when something is not OK
discord_only_on_alerts="${discord_only_on_alerts:-true}"     # true = skip Discord when everything looks good
discord_trigger_on_warn="${discord_trigger_on_warn:-true}"   # true = send on WARN or CRIT, false = CRIT only

# Logging
logfile="${logfile:-/var/log/smart-zfs-multireport/multireport.log}"
save_report_dir="${save_report_dir:-/var/log/smart-zfs-multireport}"
keep_reports_days="${keep_reports_days:-90}"

# Email - uses msmtp
send_email="${send_email:-true}"

# Drive Monitoring Thresholds
temp_warn="${temp_warn:-45}"
temp_crit="${temp_crit:-50}"
realloc_warn="${realloc_warn:-5}"
pending_warn="${pending_warn:-1}"
hours_warn="${hours_warn:-26280}"  # 3 years (currently informational only)

# Report Options
include_zfs_report="${include_zfs_report:-true}"
include_smart_attrs="${include_smart_attrs:-true}"
include_selftest_logs="${include_selftest_logs:-true}"
selftest_lines="${selftest_lines:-25}"

# ============================================================================
# FUNCTIONS
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$logfile"
}

# Create directories if needed
setup_dirs() {
    mkdir -p "$(dirname "$logfile")"
    mkdir -p "$save_report_dir"
    # Make sure logfile exists so tee won't error in weird edge cases
    touch "$logfile" 2>/dev/null || true
}

# Cleanup old reports
cleanup_old_reports() {
    if [[ -d "$save_report_dir" ]]; then
        find "$save_report_dir" -type f -name "*.html" -mtime +"$keep_reports_days" -delete 2>/dev/null || true
    fi
}

# Get hostname
get_hostname() {
    hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown"
}

# Discover physical drives (excluding partitions, loop devices, etc.)
discover_drives() {
    local -a drives=()

    while IFS= read -r drive; do
        [[ -z "$drive" ]] && continue
        [[ "$drive" == /dev/zd* ]] && continue
        [[ "$drive" == /dev/loop* ]] && continue
        [[ "$drive" == /dev/sr* ]] && continue
        drives+=("$drive")
    done < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" {print "/dev/"$1}')

    printf '%s\n' "${drives[@]}"
}

# SMART helpers
smart_available() {
    [[ -n "${SMARTCTL:-}" ]] || return 1
    "$SMARTCTL" -i "$1" &>/dev/null
}

smart_model() {
    "$SMARTCTL" -i "$1" 2>/dev/null | awk -F: '/Device Model|Model Number|Product:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}'
}

smart_serial() {
    "$SMARTCTL" -i "$1" 2>/dev/null | awk -F: '/Serial Number|Serial number/ {gsub(/^[ \t]+/,"",$2); print $2; exit}'
}

smart_health() {
    "$SMARTCTL" -H "$1" 2>/dev/null | awk -F: '/SMART overall-health|SMART Health Status|test result:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}'
}

# SATA/SAS attributes
get_smart_attr() {
    local drive="$1"
    local attr_id="$2"
    "$SMARTCTL" -A "$drive" 2>/dev/null | awk -v id="$attr_id" '$1==id {print $10; exit}'
}

# NVMe specific (via smartctl)
nvme_temp() {
    "$SMARTCTL" -a "$1" 2>/dev/null | awk -F: '/Temperature:/ {gsub(/^[ \t]+/,"",$2); gsub(/[^0-9].*/,"",$2); print $2; exit}'
}

nvme_percentage_used() {
    "$SMARTCTL" -a "$1" 2>/dev/null | awk -F: '/Percentage Used/ {gsub(/^[ \t]+/,"",$2); gsub(/%/,"",$2); print $2; exit}'
}

nvme_power_on_hours() {
    "$SMARTCTL" -a "$1" 2>/dev/null | awk -F: '/Power On Hours/ {gsub(/^[ \t]+/,"",$2); gsub(/,/,"",$2); print $2; exit}'
}

nvme_media_errors() {
    "$SMARTCTL" -a "$1" 2>/dev/null | awk -F: '/Media and Data Integrity Errors/ {gsub(/^[ \t]+/,"",$2); print $2; exit}'
}

# Determine drive type
get_drive_type() {
    local drive="$1"
    if [[ "$drive" == /dev/nvme* ]]; then
        echo "NVMe"
    elif "$SMARTCTL" -i "$drive" 2>/dev/null | grep -q "SCSI"; then
        echo "SCSI/SAS"
    else
        echo "SATA"
    fi
}

# Capacity helpers (TB, decimal base-10)
bytes_to_tb() {
    local bytes="$1"
    awk -v b="$bytes" 'BEGIN{ if (b=="" || b==0) {print "N/A"} else {printf "%.2f TB", b/1000000000000.0} }'
}

drive_capacity_tb() {
    local drive="$1"
    local bytes
    bytes="$(lsblk -b -dn -o SIZE "$drive" 2>/dev/null | head -n1)"
    if [[ -n "$bytes" && "$bytes" =~ ^[0-9]+$ ]]; then
        bytes_to_tb "$bytes"
    else
        echo "N/A"
    fi
}

# ============================================================================
# Compute overall system state for Discord gating
# Returns: OK, WARN, or CRIT
# ============================================================================
get_system_state() {
    local state="OK"

    # ZFS: any pool not ONLINE => CRIT
    if [[ -n "${ZPOOL:-}" ]]; then
        while IFS= read -r pool; do
            [[ -z "$pool" ]] && continue
            local pool_health
            pool_health="$("$ZPOOL" list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")"
            if [[ "$pool_health" != "ONLINE" ]]; then
                echo "CRIT"
                return 0
            fi
        done < <("$ZPOOL" list -H -o name 2>/dev/null)
    fi

    # Drives
    while IFS= read -r drive; do
        [[ -z "$drive" ]] && continue
        smart_available "$drive" || continue

        local drive_type health temp realloc pending media_err
        drive_type="$(get_drive_type "$drive")"
        health="$(smart_health "$drive" || echo "UNKNOWN")"

        # Health not PASSED/OK => CRIT (unless UNKNOWN)
        if [[ "$health" != "UNKNOWN" && "$health" != *"PASSED"* && "$health" != *"OK"* ]]; then
            echo "CRIT"
            return 0
        fi

        if [[ "$drive_type" == "NVMe" ]]; then
            temp="$(nvme_temp "$drive" || echo "")"
            media_err="$(nvme_media_errors "$drive" || echo "")"
            if [[ -n "$media_err" && "$media_err" =~ ^[0-9]+$ && "$media_err" -gt 0 ]]; then
                echo "CRIT"
                return 0
            fi
        else
            temp="$(get_smart_attr "$drive" 194 || echo "")"
            realloc="$(get_smart_attr "$drive" 5 || echo "")"
            pending="$(get_smart_attr "$drive" 197 || echo "")"

            if [[ -n "$pending" && "$pending" =~ ^[0-9]+$ && "$pending" -gt "$pending_warn" ]]; then
                echo "CRIT"
                return 0
            fi
            if [[ -n "$realloc" && "$realloc" =~ ^[0-9]+$ && "$realloc" -gt "$realloc_warn" ]]; then
                state="WARN"
            fi
        fi

        # Temp thresholds
        if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ ]]; then
            if [[ "$temp" -ge "$temp_crit" ]]; then
                echo "CRIT"
                return 0
            elif [[ "$temp" -ge "$temp_warn" ]]; then
                state="WARN"
            fi
        fi
    done < <(discover_drives)

    echo "$state"
}

# ============================================================================
# HTML REPORT GENERATION
# ============================================================================
generate_html_report() {
    local hostname report_time
    hostname="$(get_hostname)"
    report_time="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    cat <<'HTMLSTART'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Proxmox Multi-Report</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px; }
        .container { max-width: 1400px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #6D28D9; border-bottom: 3px solid #6D28D9; padding-bottom: 10px; }
        h2 { color: #333; background: #f0f0f0; padding: 10px; border-left: 4px solid #6D28D9; margin-top: 30px; }
        .info-box { background: #f9f9f9; border: 1px solid #ddd; padding: 15px; margin: 20px 0; border-radius: 4px; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; font-size: 14px; }
        th { background: #6D28D9; color: white; padding: 12px 8px; text-align: left; font-weight: 600; }
        td { padding: 10px 8px; border-bottom: 1px solid #ddd; }
        tr:hover { background: #f5f5f5; }
        .status-ok { color: green; font-weight: bold; }
        .status-warn { color: orange; font-weight: bold; }
        .status-crit { color: red; font-weight: bold; }
        .alert { background: #fff3cd; border: 1px solid #ffc107; padding: 15px; margin: 20px 0; border-radius: 4px; }
        .alert-crit { background: #f8d7da; border: 1px solid #dc3545; }
        .pre-box { background: #f4f4f4; border: 1px solid #ddd; padding: 15px; overflow-x: auto; font-family: 'Courier New', monospace; font-size: 12px; white-space: pre; }
        .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #ddd; text-align: center; color: #666; font-size: 12px; }
    </style>
</head>
<body>
    <div class="container">
HTMLSTART

    local pve_ver="N/A"
    if [[ -n "${PVEVERSION:-}" ]]; then
        pve_ver="$("$PVEVERSION" 2>/dev/null || echo "N/A")"
    fi

    cat <<EOF
        <h1>📊 Proxmox Multi-Report</h1>
        <div class="info-box">
            <strong>Hostname:</strong> $hostname<br>
            <strong>Report Time:</strong> $report_time<br>
            <strong>Proxmox Version:</strong> ${pve_ver}
        </div>
EOF

    generate_critical_alerts

    if [[ "$include_zfs_report" == "true" ]]; then
        generate_zfs_section
    fi

    generate_drive_summary_table

    if [[ "$include_smart_attrs" == "true" ]]; then
        generate_smart_attributes_section
    fi

    if [[ "$include_selftest_logs" == "true" ]]; then
        generate_selftest_section
    fi

    cat <<'HTMLEND'
        <div class="footer">
            Generated by Proxmox Multi-Report
        </div>
    </div>
</body>
</html>
HTMLEND
}

generate_critical_alerts() {
    local alerts=()

    while IFS= read -r drive; do
        [[ -z "$drive" ]] && continue
        smart_available "$drive" || continue

        local health
        health="$(smart_health "$drive" || echo "UNKNOWN")"

        if [[ "$health" != *"PASSED"* && "$health" != *"OK"* && "$health" != "UNKNOWN" ]]; then
            alerts+=("Drive $drive health status: $health")
        fi

        local drive_type
        drive_type="$(get_drive_type "$drive")"

        if [[ "$drive_type" == "NVMe" ]]; then
            local media_err
            media_err="$(nvme_media_errors "$drive" || echo "")"
            if [[ -n "$media_err" && "$media_err" != "0" && "$media_err" =~ ^[0-9]+$ ]]; then
                alerts+=("Drive $drive has $media_err media errors")
            fi
        else
            local realloc pending
            realloc="$(get_smart_attr "$drive" 5 || echo "")"
            pending="$(get_smart_attr "$drive" 197 || echo "")"

            if [[ -n "$realloc" && "$realloc" =~ ^[0-9]+$ && "$realloc" -gt "$realloc_warn" ]]; then
                alerts+=("Drive $drive has $realloc reallocated sectors")
            fi

            if [[ -n "$pending" && "$pending" =~ ^[0-9]+$ && "$pending" -gt "$pending_warn" ]]; then
                alerts+=("Drive $drive has $pending pending sectors")
            fi
        fi
    done < <(discover_drives)

    if [[ ${#alerts[@]} -gt 0 ]]; then
        echo '<div class="alert alert-crit">'
        echo '<strong>⚠️ CRITICAL ALERTS:</strong><ul>'
        for alert in "${alerts[@]}"; do
            echo "<li>$alert</li>"
        done
        echo '</ul></div>'
    fi
}

generate_zfs_section() {
    echo '<h2>💾 ZFS Pool Status</h2>'

    if [[ -z "${ZPOOL:-}" ]]; then
        echo '<p>ZFS not available on this system.</p>'
        return
    fi

    echo '<div class="pre-box">'
    "$ZPOOL" list 2>/dev/null || echo "No ZFS pools found"
    echo '</div>'

    while IFS= read -r pool; do
        [[ -z "$pool" ]] && continue
        echo "<h3>Pool: $pool</h3>"
        echo '<div class="pre-box">'
        "$ZPOOL" status "$pool" 2>/dev/null
        echo '</div>'
    done < <("$ZPOOL" list -H -o name 2>/dev/null)
}

generate_drive_summary_table() {
    echo '<h2>🔍 Drive Summary</h2>'
    echo '<table>'
    echo '<tr>'
    echo '<th>Device</th>'
    echo '<th>Type</th>'
    echo '<th>Model</th>'
    echo '<th>Serial</th>'
    echo '<th>Capacity</th>'
    echo '<th>Health</th>'
    echo '<th>Temp (°C)</th>'
    echo '<th>Power On Hours</th>'
    echo '<th>Reallocated</th>'
    echo '<th>Pending</th>'
    echo '<th>% Used</th>'
    echo '</tr>'

    while IFS= read -r drive; do
        [[ -z "$drive" ]] && continue
        smart_available "$drive" || continue

        local model serial health temp poh realloc pending pct_used
        local drive_type health_class temp_class cap_tb

        drive_type="$(get_drive_type "$drive" || echo "Unknown")"
        model="$(smart_model "$drive" || echo "")"
        serial="$(smart_serial "$drive" || echo "")"
        health="$(smart_health "$drive" || echo "")"
        cap_tb="$(drive_capacity_tb "$drive")"

        if [[ "$health" == *"PASSED"* || "$health" == *"OK"* ]]; then
            health_class="status-ok"
        else
            health_class="status-crit"
        fi

        pct_used="N/A"
        if [[ "$drive_type" == "NVMe" ]]; then
            temp="$(nvme_temp "$drive" || echo "")"
            poh="$(nvme_power_on_hours "$drive" || echo "")"
            pending="$(nvme_media_errors "$drive" || echo "")"
            realloc="N/A"

            local pct
            pct="$(nvme_percentage_used "$drive" || echo "")"
            if [[ -n "$pct" && "$pct" =~ ^[0-9]+$ ]]; then
                pct_used="${pct}%"
            fi
        else
            temp="$(get_smart_attr "$drive" 194 || echo "")"
            poh="$(get_smart_attr "$drive" 9 || echo "")"
            realloc="$(get_smart_attr "$drive" 5 || echo "")"
            pending="$(get_smart_attr "$drive" 197 || echo "")"
        fi

        temp_class="status-ok"
        if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ ]]; then
            if [[ "$temp" -ge "$temp_crit" ]]; then
                temp_class="status-crit"
            elif [[ "$temp" -ge "$temp_warn" ]]; then
                temp_class="status-warn"
            fi
        fi

        echo '<tr>'
        echo "<td>$drive</td>"
        echo "<td>$drive_type</td>"
        echo "<td>${model:-N/A}</td>"
        echo "<td>${serial:-N/A}</td>"
        echo "<td>${cap_tb:-N/A}</td>"
        echo "<td class=\"$health_class\">${health:-N/A}</td>"
        echo "<td class=\"$temp_class\">${temp:-N/A}</td>"
        echo "<td>${poh:-N/A}</td>"
        echo "<td>${realloc:-N/A}</td>"
        echo "<td>${pending:-N/A}</td>"
        echo "<td>${pct_used:-N/A}</td>"
        echo '</tr>'
    done < <(discover_drives)

    echo '</table>'
}

generate_smart_attributes_section() {
    echo '<h2>📈 Detailed SMART Attributes</h2>'

    while IFS= read -r drive; do
        [[ -z "$drive" ]] && continue
        smart_available "$drive" || continue

        local model
        model="$(smart_model "$drive" || echo "Unknown")"

        echo "<h3>$drive - ${model:-Unknown}</h3>"
        echo '<div class="pre-box">'
        "$SMARTCTL" -A "$drive" 2>/dev/null || echo "SMART attributes not available"
        echo '</div>'
    done < <(discover_drives)
}

generate_selftest_section() {
    echo '<h2>🧪 Self-Test Logs</h2>'

    while IFS= read -r drive; do
        [[ -z "$drive" ]] && continue
        smart_available "$drive" || continue

        local model
        model="$(smart_model "$drive" || echo "Unknown")"

        echo "<h3>$drive - ${model:-Unknown}</h3>"
        echo '<div class="pre-box">'

        if [[ "$drive" == /dev/nvme* ]]; then
            local tmp
            tmp=$(mktemp)
            "$SMARTCTL" -l selftest "$drive" > "$tmp" 2>&1 || true

            if grep -qi "Invalid Field in Command\|not supported" "$tmp"; then
                echo "Self-test log not supported by this NVMe device"
            else
                tail -n "$selftest_lines" "$tmp" 2>/dev/null || echo "No self-test data available"
            fi
            rm -f "$tmp" 2>/dev/null || true
        else
            "$SMARTCTL" -l selftest "$drive" 2>/dev/null | tail -n "$selftest_lines" || echo "No self-test logs available"
        fi

        echo '</div>'
    done < <(discover_drives)
}

# ============================================================================
# DISCORD WEBHOOK FUNCTIONS
# ============================================================================
send_discord_webhook() {
    local hostname="$1"
    local state="${2:-OK}"

    if [[ -z "$discord_webhook" || "$discord_enabled" != "true" ]]; then
        return 0
    fi

    if [[ -z "${CURL:-}" ]]; then
        log "WARNING: curl not found, cannot send Discord webhook"
        return 1
    fi

    local drive_summary=""
    local drive_count=0
    local alert_count=0

    while IFS= read -r drive; do
        [[ -z "$drive" ]] && continue
        smart_available "$drive" || continue

        local model health temp poh drive_type
        drive_type="$(get_drive_type "$drive" || echo "Unknown")"
        model="$(smart_model "$drive" || echo "Unknown")"
        model="${model:0:30}"
        health="$(smart_health "$drive" || echo "Unknown")"

        if [[ "$drive_type" == "NVMe" ]]; then
            temp="$(nvme_temp "$drive" || echo "?")"
            poh="$(nvme_power_on_hours "$drive" || echo "?")"
        else
            temp="$(get_smart_attr "$drive" 194 || echo "?")"
            poh="$(get_smart_attr "$drive" 9 || echo "?")"
        fi

        local status_icon="✅"
        if [[ "$health" != *"PASSED"* && "$health" != *"OK"* ]]; then
            status_icon="🔴"
            ((alert_count++))
        elif [[ -n "$temp" && "$temp" =~ ^[0-9]+$ && "$temp" -ge "$temp_crit" ]]; then
            status_icon="🔴"
            ((alert_count++))
        elif [[ -n "$temp" && "$temp" =~ ^[0-9]+$ && "$temp" -ge "$temp_warn" ]]; then
            status_icon="⚠️"
        fi

        drive_summary="${drive_summary}${status_icon} **$(basename "$drive")** (${drive_type}): ${temp}°C | ${poh}h | ${health}
"
        ((drive_count++))
    done < <(discover_drives)

    local embed_color=3066993
    if [[ "$state" == "WARN" ]]; then
        embed_color=15105570
    elif [[ "$state" == "CRIT" ]]; then
        embed_color=15158332
    fi

    local zfs_summary=""
    if [[ -n "${ZPOOL:-}" ]]; then
        while IFS= read -r pool; do
            [[ -z "$pool" ]] && continue
            local pool_health
            pool_health="$("$ZPOOL" list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")"
            local pool_icon="✅"
            [[ "$pool_health" != "ONLINE" ]] && pool_icon="🔴"
            zfs_summary="${zfs_summary}${pool_icon} **${pool}**: ${pool_health}
"
        done < <("$ZPOOL" list -H -o name 2>/dev/null)
    else
        zfs_summary="ZFS not available"
    fi

    drive_summary="${drive_summary//\\/\\\\}"
    drive_summary="${drive_summary//\"/\\\"}"
    zfs_summary="${zfs_summary//\\/\\\\}"
    zfs_summary="${zfs_summary//\"/\\\"}"

    local pve_version="N/A"
    if [[ -n "${PVEVERSION:-}" ]]; then
        pve_version="$("$PVEVERSION" 2>/dev/null | head -1 | cut -d'/' -f1 || echo 'N/A')"
    fi

    local temp_json
    temp_json=$(mktemp)

    cat > "$temp_json" <<EOF
{
  "username": "Proxmox Storage Mon",
  "avatar_url": "https://www.proxmox.com/images/proxmox/Proxmox_symbol_standard_hex_400px.png",
  "embeds": [{
    "title": "📊 Proxmox Multi-Report: ${hostname}",
    "description": "System health monitoring report (state: ${state})",
    "color": ${embed_color},
    "fields": [
      {
        "name": "🖥️ System Info",
        "value": "**Hostname**: ${hostname}\n**Time**: $(date '+%Y-%m-%d %H:%M:%S')\n**Version**: ${pve_version}",
        "inline": false
      },
      {
        "name": "💾 ZFS Pools",
        "value": "${zfs_summary}",
        "inline": false
      },
      {
        "name": "🔍 Drives (${drive_count} total, ${alert_count} alerts)",
        "value": "${drive_summary}",
        "inline": false
      }
    ],
    "footer": { "text": "Proxmox Multi-Report" },
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  }]
}
EOF

    local http_code
    http_code=$("$CURL" -s -w "%{http_code}" -o /tmp/discord_response.txt -X POST "$discord_webhook" \
        -H "Content-Type: application/json" \
        -d @"$temp_json")

    local response
    response=$(cat /tmp/discord_response.txt 2>/dev/null || true)

    rm -f "$temp_json" /tmp/discord_response.txt

    if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
        log "Discord webhook sent successfully (HTTP $http_code, state=$state)"
        return 0
    else
        log "ERROR: Discord webhook failed (HTTP $http_code): $response"
        return 1
    fi
}

# ============================================================================
# EMAIL FUNCTIONS
# ============================================================================
send_email_via_mail() {
    local subject="$1"
    local html_file="$2"

    if [[ -z "${MSMTP:-}" ]]; then
        log "ERROR: 'msmtp' command not found. Install msmtp package."
        return 1
    fi

    local mail_from
    mail_from="${mail_from:-root@$(get_hostname)}"

    {
        echo "To: $email"
        echo "From: $mail_from"
        echo "Subject: $subject"
        echo "Date: $(date -R)"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/html; charset=UTF-8"
        echo ""
        cat "$html_file"
    } | "$MSMTP" -t

    log "Email sent to $email using msmtp"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    setup_dirs
    cleanup_old_reports

    log "Starting Proxmox Multi-Report"

    if [[ -z "${SMARTCTL:-}" ]]; then
        log "ERROR: smartctl not found in PATH: $PATH"
        log "       Install smartmontools:"
        log "       apt update && apt install smartmontools"
        exit 1
    fi

    local hostname timestamp html_file subject
    hostname="$(get_hostname)"
    timestamp="$(date '+%Y-%m-%d_%H%M%S')"
    html_file="$save_report_dir/report_${hostname}_${timestamp}.html"

    log "Generating report..."
    generate_html_report > "$html_file"
    log "Report generated: $html_file"

    local state
    state="$(get_system_state | tr -d '\r\n')"
    [[ -z "$state" ]] && state="OK"
    log "Computed system state: $state"

    subject="$subject_prefix - $hostname - $(date +%F)"
    if grep -q "CRITICAL ALERTS" "$html_file"; then
        subject="⚠️ ALERT - $subject"
    fi

    if [[ "$send_email" == "true" ]]; then
        log "Sending email..."
        if send_email_via_mail "$subject" "$html_file"; then
            log "Email sent successfully"
        else
            log "ERROR: Failed to send email"
        fi
    else
        log "Email sending disabled"
    fi

    # Discord gating
    if [[ "$discord_enabled" == "true" && -n "$discord_webhook" ]]; then
        local send_discord="true"

        if [[ "$discord_only_on_alerts" == "true" ]]; then
            if [[ "$discord_trigger_on_warn" == "true" ]]; then
                [[ "$state" == "OK" ]] && send_discord="false"
            else
                [[ "$state" != "CRIT" ]] && send_discord="false"
            fi
        fi

        if [[ "$send_discord" == "true" ]]; then
            log "Sending Discord webhook (state=$state)..."
            if send_discord_webhook "$hostname" "$state"; then
                log "Discord webhook sent successfully"
            else
                log "ERROR: Failed to send Discord webhook"
            fi
        else
            log "Skipping Discord webhook (state=$state, only_on_alerts=$discord_only_on_alerts, trigger_on_warn=$discord_trigger_on_warn)"
        fi
    fi

    log "Proxmox Multi-Report completed successfully"
    echo ""
    echo "Report saved to: $html_file"
    echo "You can view it with: firefox $html_file"
}

main "$@"
