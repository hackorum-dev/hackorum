#!/usr/bin/env bash
# Weekly: read back 10% of the pack data. A timer unit failing alone pages nobody, so ping /fail.
set -euo pipefail
set -a; . "$(dirname "$0")/restic.env"; set +a

if ! restic check --read-data-subset=10% --retry-lock 30m; then
  curl -fsS -m 10 --retry 3 -o /dev/null "$HEALTHCHECKS_BACKUP_URL/fail" || true
  echo "restic check failed" >&2
  exit 1
fi
