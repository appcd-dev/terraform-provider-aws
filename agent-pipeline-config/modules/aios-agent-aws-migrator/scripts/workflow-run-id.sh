#!/usr/bin/env bash
# Shared workflow-id check for pack scripts that build $HOME/.<id>.
#
# Guild sometimes leaves the literal '{{workflow_run_id}}' in the pasted
# command. Rejecting braces alone is not enough: any other string, including a
# path, would be interpolated into the work-root directory. Accept only the
# id shape the stagerunner emits, plus the short wf-test ids used by pack tests.
#
# Source this file. Do not execute it.

resolve_workflow_run_id() {
  local id="${1:-}"
  # Fall back when argv is empty, still a template, or not a single path segment.
  if [ -z "$id" ] || [[ "$id" == *'{{'* ]] || [[ "$id" == *'}}'* ]] \
    || [[ "$id" == *'{'* ]] || [[ "$id" == *'}'* ]] \
    || [[ "$id" == *'/'* ]] || [[ "$id" == *'.'* ]]; then
    id="${WORKFLOW_RUN_ID:-}"
  fi
  # wf-<token> with only [a-z0-9-], no leading/trailing/double hyphen.
  if [[ ! "$id" =~ ^wf-[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    return 1
  fi
  printf '%s' "$id"
}
