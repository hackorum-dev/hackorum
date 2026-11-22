#!/usr/bin/env bash
# Temporary, runs on the OLD prod (deploy/ based) until cutover: pushes a nightly
# pg_dump into the same restic repo so staging can restore prod data.
# Setup (as root on the old box):
#  1. Check free disk first: an uncompressed -Z0 dump of the 24GB DB can be larger than
#     the DB itself, and the old disk is small. The script keeps only one dump at a time.
#  2. Install restic. Needs >= 0.16 (--retry-lock) and >= 0.14 (repo format v2, the new
#     box inits with 0.18): check `restic version`. Distro packages can be older
#     (Ubuntu 22.04 ships 0.12), then use the static binary from the GitHub release.
#  3. Copy the storagebox ssh key to /root/.ssh/storagebox (0600) and add the Host block
#     (see infra/ansible/roles/backup/templates/ssh_config.j2) to /root/.ssh/config.
#  4. /root/oldprod-restic.env (0600): RESTIC_REPOSITORY=sftp:storagebox:/hackorum-restic
#     and RESTIC_PASSWORD=<restic_password from the vault>.
#  5. Install this file as /root/oldprod-push-dump.sh (0755), adjust OLD_DEPLOY_DIR, run it
#     once by hand, confirm `restic snapshots --host oldprod`, then cron:
#       0 2 * * * /root/oldprod-push-dump.sh >> /var/log/oldprod-push-dump.log 2>&1
# Staging's backup_source_host: oldprod must match --host oldprod below.
# Same absolute dump path as the new host, so restore finds it in the same place.
set -euo pipefail
set -a; . /root/oldprod-restic.env; set +a

OLD_DEPLOY_DIR="${OLD_DEPLOY_DIR:-/root/hackorum/deploy}"
DUMPS=/srv/bulk/hackorum/dumps
POSTGRES_USER="$(sed -n 's/^POSTGRES_USER=//p' "$OLD_DEPLOY_DIR/.env" | tail -n1 || true)"
POSTGRES_USER="${POSTGRES_USER:-postgres}"

cd "$OLD_DEPLOY_DIR"
mkdir -p "$DUMPS/daily"
rm -f "$DUMPS"/daily/*
trap 'rm -f "$DUMPS"/daily/*' EXIT
for db in hackorum umami; do
  docker compose exec -T db pg_dump -U "$POSTGRES_USER" -d "$db" -Fc -Z0 > "$DUMPS/daily/$db.dump.tmp"
  mv "$DUMPS/daily/$db.dump.tmp" "$DUMPS/daily/$db.dump"
done
restic backup --quiet --retry-lock 30m --host oldprod --tag nightly --tag oldprod "$DUMPS"

if [ "$(date +%u)" = "7" ]; then
  restic forget --quiet --retry-lock 30m --host oldprod --keep-daily 7 --prune
fi
echo "pushed $(date -Is)"
