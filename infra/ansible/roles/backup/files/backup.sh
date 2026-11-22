#!/usr/bin/env bash
# Nightly: pg_dump (uncompressed custom format, restic dedups) + restic backup + metrics + ping.
set -euo pipefail
set -a; . "$(dirname "$0")/restic.env"; set +a

COMPOSE="docker compose -f $HACKORUM_ROOT/compose/compose.yml"
TEXTFILE="$PLATFORM_ROOT/textfile/backup.prom"
DUMPS="$HACKORUM_DUMPS_ROOT/daily"
START=$(date +%s)

ping() { curl -fsS -m 10 --retry 3 -o /dev/null "$HEALTHCHECKS_BACKUP_URL$1" || true; }
metric() {
  cat > "$TEXTFILE.tmp" <<METRICS
hackorum_backup_last_success_timestamp_seconds{host="$ENV_NAME"} $1
hackorum_backup_duration_seconds{host="$ENV_NAME"} $2
hackorum_backup_repo_size_bytes{host="$ENV_NAME"} $3
METRICS
  mv "$TEXTFILE.tmp" "$TEXTFILE"
}
fail() {
  rm -f "$DUMPS"/*.tmp "$TEXTFILE.tmp"
  ping /fail
  echo "backup failed at: $1" >&2
  exit 1
}

ping /start
trap 'fail "$BASH_COMMAND"' ERR

mkdir -p "$DUMPS"
for db in hackorum umami; do
  $COMPOSE exec -T db pg_dump -U hackorum -d "$db" -Fc -Z0 > "$DUMPS/$db.dump.tmp"
  mv "$DUMPS/$db.dump.tmp" "$DUMPS/$db.dump"
done

restic backup --quiet --retry-lock 30m --tag nightly \
  --exclude "$HACKORUM_ROOT/data/mail-logs" \
  "$HACKORUM_DUMPS_ROOT" \
  "$HACKORUM_ROOT/data/mail" \
  "$HACKORUM_ROOT/dms" \
  "$HACKORUM_ROOT/compose" \
  "$PLATFORM_ROOT/data/caddy" \
  "$PLATFORM_ROOT/data/grafana" \
  "$PLATFORM_ROOT/data/prometheus" \
  "$PLATFORM_ROOT/compose"

if [ "$(date +%u)" = "7" ]; then
  restic forget --quiet --retry-lock 30m --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
fi

SIZE=$(restic stats --retry-lock 30m --mode raw-data --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_size"])')
END=$(date +%s)
metric "$END" "$((END - START))" "$SIZE"
ping ""
echo "backup ok in $((END - START))s, repo $SIZE bytes"
