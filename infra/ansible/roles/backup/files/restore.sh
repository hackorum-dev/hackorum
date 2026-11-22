#!/usr/bin/env bash
# Restore the app layer from restic. Used by the runbook, the staging nightly
# drill and the wipe drill. Exit code lands in hackorum_restore_last_status.
set -euo pipefail
set -a; . "$(dirname "$0")/restic.env"; set +a

FROM_HOST="${BACKUP_SOURCE_HOST:-}"
SNAPSHOT="latest"
while [ $# -gt 0 ]; do
  case "$1" in
    --from-host) FROM_HOST="$2"; shift 2 ;;
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$FROM_HOST" ] || [ "$SNAPSHOT" != latest ] || { echo "need --from-host, --snapshot or BACKUP_SOURCE_HOST" >&2; exit 2; }
RESTORE_MAIL="${RESTORE_MAIL:-$([ "$ENV_NAME" = prod ] && echo 1 || echo 0)}"

COMPOSE="docker compose -f $HACKORUM_ROOT/compose/compose.yml"
TEXTFILE="$PLATFORM_ROOT/textfile/restore.prom"
WIPE_MARKER="$PLATFORM_ROOT/restic/.wipe-in-progress"
DUMPS="$HACKORUM_DUMPS_ROOT/daily"
START=$(date +%s)
STOPPED=0
DROPPED=0
SILENCE=""

ping() { curl -fsS -m 10 --retry 3 -o /dev/null "$HEALTHCHECKS_RESTORE_URL$1" || true; }
am() { docker compose -f "$PLATFORM_ROOT/compose/compose.yml" exec -T alertmanager amtool --alertmanager.url=http://localhost:9093 "$@"; }
# best effort, monitoring must never fail a restore; RestoreDrill* stay live
unsilence() { if [ -n "$SILENCE" ]; then am silence expire "$SILENCE" || true; fi; }
metric() {
  cat > "$TEXTFILE.tmp" <<METRICS
hackorum_restore_last_run_timestamp_seconds{host="$ENV_NAME"} $(date +%s)
hackorum_restore_last_status{host="$ENV_NAME"} $1
hackorum_restore_duration_seconds{host="$ENV_NAME"} $(( $(date +%s) - START ))
METRICS
  mv "$TEXTFILE.tmp" "$TEXTFILE"
}
fail() {
  trap - ERR
  rm -rf "${TMP:-}"
  # nothing destroyed yet: do not leave the app down
  if [ "$STOPPED" = 1 ] && [ "$DROPPED" = 0 ]; then $COMPOSE up -d || true; fi
  unsilence
  metric 1
  ping /fail
  echo "restore failed at: $1" >&2
  exit 1
}

# the wipe drill calls us itself; the plain timer must not run on top of it
if [ -f "$WIPE_MARKER" ] && [ "$(( $(date +%s) - $(stat -c %Y "$WIPE_MARKER") ))" -lt 21600 ] && [ "${CALLED_FROM_WIPE:-0}" != 1 ]; then
  echo "wipe in progress, skipping timer run"; exit 0
fi

ping /start
trap 'fail "$BASH_COMMAND"' ERR
# prints just the silence id (amtool 0.35 has no -q on add)
SILENCE=$(am silence add 'alertname=~"SiteProbeFailing|TargetDown|SmtpBannerDown|ImapWorkerIdle"' \
  --duration=3h --author=restore.sh --comment="restore in progress" || true)

# an explicit snapshot id is already unique, --host only narrows "latest"
SNAP_ARGS=(--host "$FROM_HOST")
[ "$SNAPSHOT" = latest ] || SNAP_ARGS=()
# fail before touching anything if the snapshot is not there
if [ "$SNAPSHOT" = latest ]; then
  SNAPS=$(restic snapshots --retry-lock 30m "${SNAP_ARGS[@]}" --latest 1 --json)
  [[ "$SNAPS" == *short_id* ]] || { echo "no snapshot for host $FROM_HOST" >&2; false; }
else
  restic cat --retry-lock 30m snapshot "$SNAPSHOT" >/dev/null
fi

# download and validate everything first: apps keep running meanwhile
$COMPOSE up -d --wait db
mkdir -p "$DUMPS"
TMP=$(mktemp -d "$HACKORUM_DUMPS_ROOT/restore.XXXX")
restic restore --retry-lock 30m "$SNAPSHOT" "${SNAP_ARGS[@]}" --target "$TMP" --include "$DUMPS"
if [ "$RESTORE_MAIL" = 1 ]; then
  restic restore --retry-lock 30m "$SNAPSHOT" "${SNAP_ARGS[@]}" --target "$TMP" --include "$HACKORUM_ROOT/data/mail" --include "$HACKORUM_ROOT/dms"
fi
for db in hackorum umami; do
  [ -s "$TMP$DUMPS/$db.dump" ] || { echo "snapshot has no $db.dump" >&2; false; }
  # TMP sits under the dumps root, which the db container mounts at /dumps
  $COMPOSE exec -T db pg_restore -l "/dumps${TMP#"$HACKORUM_DUMPS_ROOT"}$DUMPS/$db.dump" >/dev/null
done

# compose refuses the whole stop if one name is not a service (orchestrator is prod only)
APPS=$($COMPOSE config --services | grep -xE 'web|jobs|imap_worker_local|orchestrator|umami' | tr '\n' ' ')
STOPPED=1
# shellcheck disable=SC2086 # one word per service
$COMPOSE stop $APPS
if [ "$RESTORE_MAIL" = 1 ]; then
  $COMPOSE stop mailserver
  mkdir -p "$HACKORUM_ROOT/data/mail" "$HACKORUM_ROOT/dms"
  rsync -a --delete "$TMP$HACKORUM_ROOT/data/mail/" "$HACKORUM_ROOT/data/mail/"
  rsync -a "$TMP$HACKORUM_ROOT/dms/" "$HACKORUM_ROOT/dms/"
fi
mv -f "$TMP$DUMPS/hackorum.dump" "$TMP$DUMPS/umami.dump" "$DUMPS/"
rm -rf "$TMP"

# no -d here, every call names its database
PSQL="$COMPOSE exec -T db psql -U hackorum -v ON_ERROR_STOP=1"
DROPPED=1
for db in hackorum umami hackorum_production_queue hackorum_production_cache hackorum_production_cable; do
  $PSQL -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE)"
done
$PSQL -d postgres -c "CREATE DATABASE hackorum OWNER hackorum"
$PSQL -d postgres -c "CREATE DATABASE umami OWNER umami"
$COMPOSE exec -T db pg_restore -U hackorum -d hackorum -j 4 --no-owner --no-privileges /dumps/daily/hackorum.dump
# hackorum is the bootstrap superuser: --role makes umami own what it restores
$COMPOSE exec -T db pg_restore -U hackorum -d umami -j 2 --no-owner --no-privileges --role=umami /dumps/daily/umami.dump

$COMPOSE run --rm --no-deps -l autoheal=false web bin/rails db:prepare

if [ "$ENV_NAME" = staging ]; then
  $COMPOSE run --rm --no-deps -l autoheal=false web bin/rails staging:sanitize
  $COMPOSE up -d --wait mailserver
  $COMPOSE exec -T mailserver doveadm expunge -u "$RECEIVER_USER@$MAIL_DOMAIN" mailbox INBOX all || true
fi

$COMPOSE up -d --remove-orphans
for i in $(seq 1 24); do
  curl -fs -o /dev/null http://127.0.0.1:3000/up && break
  [ "$i" = 24 ] && fail "web did not come up"
  sleep 5
done

unsilence
metric 0
ping ""
echo "restore ok from $FROM_HOST ($SNAPSHOT) in $(( $(date +%s) - START ))s"
