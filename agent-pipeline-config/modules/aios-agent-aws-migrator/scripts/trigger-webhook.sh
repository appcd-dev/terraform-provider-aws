#!/usr/bin/env bash
# Trigger aws-migrator-discovery webhook on local Guild.
set -euo pipefail

GUILD_URL="${GUILD_URL:-http://localhost:8088}"
WEBHOOK_TOKEN="${WEBHOOK_TOKEN:?Set WEBHOOK_TOKEN to the Guild webhook bearer token}"
MONOLITH_URI="${MONOLITH_URI:-https://drive.usercontent.google.com/u/0/uc?id=1NCsJ6IGeDtkdIXflVHaOvw5iISgmGK-L&export=download}"
IAC_REPO="${IAC_REPOSITORY_URL:-https://github.com/sks/code-context-engine}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-tfstates}"
GROUPING="${GROUPING_STRATEGY:-tag_seeded_connectivity_capped}"
MAX_CAP="${MAX_RESOURCES_PER_APPSTACK:-200}"

payload="$(jq -n \
  --arg uri "$MONOLITH_URI" \
  --arg repo "$IAC_REPO" \
  --arg branch "$DEFAULT_BRANCH" \
  --arg strat "$GROUPING" \
  --argjson cap "$MAX_CAP" \
  '{
    monolith_state_uri: $uri,
    iac_repository_url: $repo,
    default_branch: $branch,
    grouping_strategy: $strat,
    max_resources_per_appstack: $cap
  }')"

resp="$(curl -sS -X POST "${GUILD_URL}/guild/api/v1/webhooks/trigger" \
  -H "Authorization: Bearer ${WEBHOOK_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$payload")"

printf '%s\n' "$resp"
run_id="$(printf '%s' "$resp" | jq -r '.run_id // .data.run_id // empty' 2>/dev/null || true)"
if [ -n "$run_id" ]; then
  echo "run_id=${run_id}"
fi
