# PixNProxmox

Scripts and configs I use to monitor a Proxmox server (ZFS-friendly).

## Structure
- `scripts/cron/` – scripts intended to run from cron
- `configs/` – example env files (copy elsewhere and put real values there)

## Scripts
### smart-test-scheduler.sh
Runs SMART tests with guardrails (load/ZFS activity, stable disk IDs, etc).

### smart-zfs-multireport.sh
Builds a SMART/ZFS health report and optionally notifies (email/Discord/etc).

## Cron
Add cron entries that point to where you install these scripts on the host, e.g.
- `/usr/local/sbin/smart-test-scheduler.sh`
- `/usr/local/sbin/smart-zfs-multireport.sh`
