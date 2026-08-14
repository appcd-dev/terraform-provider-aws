#!/usr/bin/env bash
# Poll Guild Postgres for aws-migrator-discovery PR creation.
# Usage: ./monitor-workflow-run.sh [--trace-id ID] [--run-id UUID] [--timeout 3600]
set -euo pipefail

PG_URL="${PG_URL:-postgres://guild:guild@localhost:5433/guild_db?sslmode=disable}"
TRACE_ID=""
RUN_ID=""
TIMEOUT=3600
POLL=20
WORKFLOW="aws-migrator-discovery"

while [ $# -gt 0 ]; do
  case "$1" in
    --trace-id) TRACE_ID="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --poll) POLL="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--trace-id ID] [--run-id UUID] [--timeout seconds]"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

deadline=$(( $(date +%s) + TIMEOUT ))

resolve_trace_id() {
  if [ -n "$TRACE_ID" ]; then
    printf '%s' "$TRACE_ID"
    return 0
  fi
  psql "$PG_URL" -t -A -c \
    "SELECT trace_id FROM execution_agent_summaries
     WHERE workflow_name LIKE '${WORKFLOW}%'
     ORDER BY created_at DESC LIMIT 1;" 2>/dev/null | tr -d '[:space:]'
}

while [ "$(date +%s)" -lt "$deadline" ]; do
  TRACE_ID="$(resolve_trace_id)"
  if [ -z "$TRACE_ID" ]; then
    echo "waiting for trace_id..."
    sleep "$POLL"
    continue
  fi

  last_stage="$(psql "$PG_URL" -t -A -c \
    "SELECT event_data->'data'->>'Message' FROM execution_events
     WHERE trace_id='${TRACE_ID}' AND event_type IN ('RUN_STARTED','RUN_FINISHED')
     ORDER BY created_at DESC LIMIT 1;" 2>/dev/null || true)"
  last_stage="$(printf '%s' "$last_stage" | tr -d '[:space:]')"

  pr_line="$(psql "$PG_URL" -t -A -c \
    "SELECT event_data::text FROM execution_events WHERE trace_id='${TRACE_ID}'
     AND event_data::text ILIKE '%pr_url=%' ORDER BY seq DESC LIMIT 1;" 2>/dev/null || true)"

  echo "[$(date -Iseconds)] trace=${TRACE_ID} stage=${last_stage:-?}"

  if printf '%s' "$pr_line" | grep -q 'pr_url='; then
    pr_url="$(printf '%s' "$pr_line" | grep -oE 'https://github.com/[^\"\\]+/pull/[0-9]+' | head -1 || true)"
    if [ -n "$pr_url" ]; then
      echo "SUCCESS pr_url=$pr_url"
      exit 0
    fi
  fi

  workflow_done="$(psql "$PG_URL" -t -A -c \
    "SELECT COUNT(*) FROM execution_events
     WHERE trace_id='${TRACE_ID}' AND event_type='RUN_FINISHED'
       AND event_data->'data'->>'Message'='done';" 2>/dev/null || true)"

  if [ "${workflow_done:-0}" -gt 0 ] && ! printf '%s' "$pr_line" | grep -q 'pr_url='; then
    blocker="$(psql "$PG_URL" -t -A -c \
      "SELECT event_data::text FROM execution_events WHERE trace_id='${TRACE_ID}'
       AND (event_data::text ILIKE '%pr_blocker%' OR event_data::text ILIKE '%blocked:%')
       ORDER BY seq DESC LIMIT 1;" 2>/dev/null || true)"
    echo "DONE without PR:"
    printf '%s\n' "$blocker" | head -c 1200
    exit 2
  fi

  sleep "$POLL"
done

echo "TIMEOUT waiting for PR (trace_id=${TRACE_ID})"
exit 3
