# PixNProxmox 🧠💾  
ZFS-aware SMART testing + a daily SMART/ZFS health multi-report for **Proxmox** hosts.

This repo contains two cron-friendly scripts:

- **`smart-test-scheduler.sh`** – schedules SMART self-tests (SATA/SAS via `smartctl`, NVMe via `nvme-cli`) with safety guardrails.
- **`smart-zfs-multireport.sh`** – generates an HTML health report (SMART + ZFS) and can notify via email and/or Discord.

> These scripts are designed to run **on the Proxmox host (not inside an unprivileged container)** and typically need **root** so they can query disks and ZFS.

---

## What runs where

### On the host (recommended install paths)
In my setup, I install the scripts here and call them from root’s crontab:

- `/usr/local/sbin/smart-test-scheduler.sh`
- `/usr/local/sbin/smart-zfs-multireport.sh`

(Your repo layout can be whatever you want — the important part is where they live on the host when cron runs.)

---

## Logging & output locations (defaults)

### `smart-test-scheduler.sh`
- **Log file:** `/var/log/smart-test-scheduler.log`
- **Rotation state:** `/var/lib/smart-test-scheduler/state_hdd_index`  
  (used only when long-test rotation is enabled)

### `smart-zfs-multireport.sh`
- **Script log file:** `/var/log/smart-zfs-multireport/multireport.log`
- **HTML reports saved to:** `/var/log/smart-zfs-multireport/`  
  Example: `report_<hostname>_<YYYY-MM-DD_HHMMSS>.html`
- **Report retention:** defaults to **90 days** (older `.html` reports are deleted)

### Optional: cron stdout/stderr capture
If you redirect output in cron, you’ll also get an additional “cron run” log. Example below saves it to:

- `/var/log/smart-zfs-multireport/cronrunlog.log`

---

## What the scripts actually do

## 1) `smart-test-scheduler.sh` – SMART self-tests with guardrails

**Highlights**
- Uses **stable device paths**: `/dev/disk/by-id/*` (no reliance on `/dev/sdX` order)
- Skips tests if:
  - a **ZFS scrub/resilver** is in progress
  - **system load** is above a threshold (default: `MAX_LOAD=4.0`)
- Supports concurrency for short tests (`MAX_CONCURRENT`)
- For long tests, can **rotate** one HDD per run (recommended for large RAIDZ vdevs)
- Optional notifications:
  - email via `mail`
  - Discord via `curl`

---

## 2) `smart-zfs-multireport.sh` – Daily SMART/ZFS HTML report + notifications

**Highlights**
- Discovers disks, pulls SMART health + key attributes (SATA/SAS and NVMe)
- Includes ZFS pool summaries (`zpool list` + `zpool status`)
- Generates an **HTML report** and saves it to disk
- Optional notifications:
  - email via `msmtp` (HTML email)
  - Discord webhook (can be “only on alerts”)

---

## Dependencies

On a typical Proxmox/Debian host:

```bash
apt update
apt install -y smartmontools nvme-cli curl msmtp
# Optional (only if you enable scheduler email notifications):
apt install -y bsd-mailx
```

Notes:
- `zpool` is normally present on Proxmox hosts with ZFS enabled.
- For `smart-zfs-multireport.sh` email delivery, configure **msmtp** (system-wide or per-root).

---

## Install

```bash
# Copy scripts to the host
install -m 0755 smart-test-scheduler.sh   /usr/local/sbin/smart-test-scheduler.sh
install -m 0755 smart-zfs-multireport.sh  /usr/local/sbin/smart-zfs-multireport.sh

# Create log dirs
mkdir -p /var/log/smart-zfs-multireport
touch /var/log/smart-test-scheduler.log
touch /var/log/smart-zfs-multireport/multireport.log
```

---

## Cron jobs (example)

These are the exact cron entries I use on the host:

```cron
# Every day at 2:15 AM SMART Short Self Test
15 2 * * * TEST_TYPE=short /usr/local/sbin/smart-test-scheduler.sh

# Every Sunday at 3:15 AM SMART Long Self Test
15 3 * * 0 TEST_TYPE=long ROTATE_LONG_TESTS=true /usr/local/sbin/smart-test-scheduler.sh

# Every day at 8:00am Send Multi-Report
0 8 * * * /usr/local/sbin/smart-zfs-multireport.sh >>/var/log/smart-zfs-multireport/cronrunlog.log 2>&1
```

### Pro tip: keep secrets out of crontab
If you’re using Discord webhooks and/or email settings, consider a root-only env file:

`/etc/pixnproxmox.env` (chmod 600)

```bash
# Multireport
email="you@example.com"
subject_prefix="Proxmox SMART/ZFS Multi-Report"
discord_webhook="https://discord.com/api/webhooks/XXXXX/XXXXX"

# Scheduler
DISCORD_WEBHOOK="https://discord.com/api/webhooks/XXXXX/XXXXX"
EMAIL="you@example.com"
```

Then source it in cron:

```cron
15 2 * * * . /etc/pixnproxmox.env; TEST_TYPE=short /usr/local/sbin/smart-test-scheduler.sh
0 8 * * *  . /etc/pixnproxmox.env; /usr/local/sbin/smart-zfs-multireport.sh >>/var/log/smart-zfs-multireport/cronrunlog.log 2>&1
```

---

## Configuration (environment variables)

### `smart-test-scheduler.sh` key vars
| Variable | Default | Purpose |
|---|---:|---|
| `TEST_TYPE` | `short` | `short` or `long` |
| `ROTATE_LONG_TESTS` | `true` | If `true`, long runs test **one HDD per run** (rotates) |
| `INCLUDE_NVME_ON_LONG` | `true` | Also run NVMe long tests on long runs |
| `MAX_CONCURRENT` | `2` | Max simultaneous tests |
| `MAX_LOAD` | `4.0` | Skip if 1-min load average exceeds this |
| `LOGFILE` | `/var/log/smart-test-scheduler.log` | Scheduler log path |
| `STATE_DIR` | `/var/lib/smart-test-scheduler` | Rotation state directory |
| `ONLY_ZFS_MEMBER_DISKS` | `false` | If `true`, test only disks found in `zpool status` |
| `SEND_EMAIL` | `false` | Enable `mail` notifications |
| `EMAIL` | *(blank)* | Recipient for `mail` |
| `DISCORD_ENABLED` | `false` | Enable Discord notifications |
| `DISCORD_WEBHOOK` | *(blank)* | Discord webhook URL |

### `smart-zfs-multireport.sh` key vars
| Variable | Default | Purpose |
|---|---:|---|
| `logfile` | `/var/log/smart-zfs-multireport/multireport.log` | Script log path |
| `save_report_dir` | `/var/log/smart-zfs-multireport` | Where HTML reports are stored |
| `keep_reports_days` | `90` | Delete old reports after N days |
| `send_email` | `true` | Email the report via `msmtp` |
| `email` | `email@email.com` | Recipient address |
| `mail_from` | `root@<host>` | Override From header |
| `discord_enabled` | `true` | Enable Discord notifications |
| `discord_only_on_alerts` | `true` | Only post to Discord on WARN/CRIT |
| `discord_trigger_on_warn` | `true` | Post on WARN too (else only CRIT) |
| `temp_warn` / `temp_crit` | `45` / `50` | Temp thresholds (°C) |
| `realloc_warn` | `5` | Reallocated sector threshold |
| `pending_warn` | `1` | Pending sector threshold |

---

## Troubleshooting

- **Check logs first**
  - Scheduler: `/var/log/smart-test-scheduler.log`
  - Multi-report: `/var/log/smart-zfs-multireport/multireport.log`
  - Optional cron capture: `/var/log/smart-zfs-multireport/cronrunlog.log`

- **Run manually**
  ```bash
  TEST_TYPE=short /usr/local/sbin/smart-test-scheduler.sh
  /usr/local/sbin/smart-zfs-multireport.sh
  ```

- **Verify tools**
  ```bash
  smartctl --version
  nvme version
  zpool list
  ```

- **Email**
  - `smart-zfs-multireport.sh` uses `msmtp` — confirm `msmtp` is installed and configured for root.

---

## Disclaimer
SMART tests and ZFS operations can affect performance. These scripts try to be polite (load + ZFS activity checks), but you should schedule long tests during low-usage windows.
