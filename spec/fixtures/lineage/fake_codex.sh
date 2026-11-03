#!/usr/bin/env bash
# Mimics `codex exec --json -o FILE`: emits two turns of events, writes the
# result file. FAKE_CODEX_SLEEP delays the exit for timeout tests,
# FAKE_CODEX_ERROR replaces the result with error events and exit 1.
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo '{"type":"thread.started","thread_id":"t1"}'
if [ -n "$FAKE_CODEX_ERROR" ]; then
  echo "{\"type\":\"error\",\"message\":\"$FAKE_CODEX_ERROR\"}"
  echo "{\"type\":\"turn.failed\",\"error\":{\"message\":\"$FAKE_CODEX_ERROR\"}}"
  exit 1
fi
echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10}}'
echo '{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":5}}'
[ -n "$out" ] && echo '{"lineage":[],"verdicts":[],"story":"fake"}' > "$out"
echo "fake stderr" >&2
sleep "${FAKE_CODEX_SLEEP:-0}"
exit "${FAKE_CODEX_EXIT:-0}"
