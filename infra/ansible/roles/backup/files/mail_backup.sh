#!/usr/bin/env bash
# Hourly: restic backup of the maildirs only. The nightly job covers them too and does the pruning.
set -euo pipefail
set -a; . "$(dirname "$0")/restic.env"; set +a

TEXTFILE="$PLATFORM_ROOT/textfile/mail_backup.prom"

ping() { [ -z "$HEALTHCHECKS_MAIL_BACKUP_URL" ] || curl -fsS -m 10 --retry 3 -o /dev/null "$HEALTHCHECKS_MAIL_BACKUP_URL$1" || true; }
fail() {
  rm -f "$TEXTFILE.tmp"
  ping /fail
  echo "mail backup failed at: $1" >&2
  exit 1
}

ping /start
trap 'fail "$BASH_COMMAND"' ERR

# 3: files vanished between scan and read, normal in a live maildir; the snapshot exists
rc=0
restic backup --quiet --retry-lock 30m --tag mail-hourly "$HACKORUM_MAIL_DATA" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 3 ]

echo "hackorum_mail_backup_last_success_timestamp_seconds{host=\"$ENV_NAME\"} $(date +%s)" > "$TEXTFILE.tmp"
mv "$TEXTFILE.tmp" "$TEXTFILE"
restic forget --quiet --retry-lock 30m --tag mail-hourly --keep-last 24
ping ""
echo "mail backup ok"
