#!/usr/bin/env bash
set -euo pipefail

# Create monthly SQL dumps (compressed) into the /dumps volume.
# Layout (avoids circular dependencies between public and private dumps):
#   /dumps/public/schema-YYYY-MM.sql.gz       Full schema (all tables), no data.
#   /dumps/public/public-data-YYYY-MM.sql.gz  Data only, excluding private tables.
#   /dumps/private/private-data-YYYY-MM.sql.gz  Data only, only private tables.
#
# Import order: schema -> public-data -> private-data.
#
# aliases is split by row: the public dump only gets addresses seen in the
# archive, with the account link (user_id, verified_at) cleared. The private
# dump adds the remaining rows and restores the account links.
#
# Dumps older than RETENTION_DAYS (default 365) are deleted.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TABLES_FILE="${TABLES_FILE:-${ROOT}/backup/private_tables.txt}"
STAMP="$(date +%Y-%m)"
RETENTION_DAYS="${RETENTION_DAYS:-365}"

if [[ ! -f "${TABLES_FILE}" ]]; then
  echo "Private tables file not found: ${TABLES_FILE}" >&2
  exit 1
fi

readarray -t PRIVATE_TABLES < <(grep -E '^[a-z0-9_]+$' "${TABLES_FILE}")

if [[ ${#PRIVATE_TABLES[@]} -eq 0 ]]; then
  echo "No private tables found in ${TABLES_FILE}" >&2
  exit 1
fi

echo "Writing dumps for ${STAMP} to /dumps/public and /dumps/private..."

docker compose -f docker-compose.yml exec -T \
  -e STAMP="${STAMP}" -e RETENTION_DAYS="${RETENTION_DAYS}" -e PRIVATE_TABLES="${PRIVATE_TABLES[*]}" \
  db bash -s <<'SCRIPT'
set -euo pipefail

DUMP=(pg_dump -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-hackorum}" --format=plain --no-owner --no-privileges)
PSQL=(psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-hackorum}" -v ON_ERROR_STOP=1 -Atq)

EXCLUDE_ARGS=(--exclude-table-data=public.aliases)
INCLUDE_ARGS=()
for table in ${PRIVATE_TABLES}; do
  EXCLUDE_ARGS+=("--exclude-table-data=public.${table}")
  INCLUDE_ARGS+=("--table=public.${table}")
done

COLS="id, user_id, name, email, primary_alias, created_at, updated_at, verified_at, person_id, sender_count"
IN_ARCHIVE="a.sender_count > 0
  OR EXISTS (SELECT 1 FROM messages m WHERE m.sender_id = a.id)
  OR EXISTS (SELECT 1 FROM mentions mn WHERE mn.alias_id = a.id)"
SETVAL="SELECT pg_catalog.setval('public.aliases_id_seq', COALESCE((SELECT max(id) FROM public.aliases), 1));"

public_aliases() {
  echo "COPY public.aliases (${COLS}) FROM stdin;"
  "${PSQL[@]}" -c "COPY (SELECT id, NULL, name, email, primary_alias, created_at, updated_at, NULL, person_id, sender_count
    FROM aliases a WHERE ${IN_ARCHIVE} ORDER BY id) TO STDOUT"
  echo '\.'
  echo "${SETVAL}"
}

private_aliases() {
  echo "CREATE TEMP TABLE aliases_private AS SELECT ${COLS} FROM public.aliases WITH NO DATA;"
  echo "COPY aliases_private (${COLS}) FROM stdin;"
  "${PSQL[@]}" -c "COPY (SELECT ${COLS} FROM aliases a
    WHERE a.user_id IS NOT NULL OR a.verified_at IS NOT NULL OR NOT (${IN_ARCHIVE}) ORDER BY id) TO STDOUT"
  echo '\.'
  echo "INSERT INTO public.aliases (${COLS}) SELECT ${COLS} FROM aliases_private
    ON CONFLICT (id) DO UPDATE SET user_id = EXCLUDED.user_id, verified_at = EXCLUDED.verified_at;"
  echo "${SETVAL}"
}

mkdir -p /dumps/public /dumps/private

"${DUMP[@]}" --schema-only | gzip -9 > "/dumps/public/schema-${STAMP}.sql.gz"
{ "${DUMP[@]}" --data-only "${EXCLUDE_ARGS[@]}"; public_aliases; } \
  | gzip -9 > "/dumps/public/public-data-${STAMP}.sql.gz"
{ "${DUMP[@]}" --data-only "${INCLUDE_ARGS[@]}"; private_aliases; } \
  | gzip -9 > "/dumps/private/private-data-${STAMP}.sql.gz"

find /dumps/public /dumps/private -name '*.sql.gz' -mtime "+${RETENTION_DAYS}" -print -delete
SCRIPT

echo "Done."
