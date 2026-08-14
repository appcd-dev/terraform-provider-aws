#!/usr/bin/env bash
# Run N sequential db-state-split webhook triggers until N PRs are created.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
TARGET_PRs="${1:-3}"
TIMEOUT="${WORKFLOW_TIMEOUT:-3600}"
GUILD_URL="${GUILD_URL:-http://localhost:8088}"
PG_URL="${PG_URL:-postgres://guild:guild@localhost:5433/guild_db?sslmode=disable}"

success=0
run_num=0

while [ "$success" -lt "$TARGET_PRs" ]; do
  run_num=$((run_num + 1))
  echo "=== Trigger run ${run_num} (success ${success}/${TARGET_PRs}) ==="
  resp="$("$SCRIPTS/trigger-webhook.sh" 2>&1)"
  printf '%s\n' "$resp"
  sleep 25
  trace_id="$(psql "$PG_URL" -t -A -c \
    "SELECT trace_id FROM execution_agent_summaries
     WHERE workflow_name LIKE 'aws-migrator-discovery%'
     ORDER BY created_at DESC LIMIT 1;" | tr -d '[:space:]')"
  echo "monitor trace_id=$trace_id"
  if "$SCRIPTS/monitor-workflow-run.sh" --trace-id "$trace_id" --timeout "$TIMEOUT"; then
    success=$((success + 1))
    echo "=== PR ${success}/${TARGET_PRs} OK ==="
    sleep 10
    continue
  fi
  echo "=== Run ${run_num} failed (trace ${trace_id}) — stopping ===" >&2
  exit 1
done

echo "DONE: ${success} consecutive PR(s) created"
[ "$success" -ge "$TARGET_PRs" ]
