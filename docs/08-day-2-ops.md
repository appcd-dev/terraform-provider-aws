# 8. Day-2 operations

## Prerequisites

- OpenTofu / Terraform with StackGen provider (`sg`)  
- Access to a StackGen URL + token (env or tfvars — **never commit**)  
- Remote runner machine with `aiden-runner` started  
- AWS + GitHub credentials in vault as the module expects  
- Optional but recommended: Azure Reader SP (`ARM_*`) and/or GCP SA ADC for live plan  

## Bring-up (empty workspace) — `walle`

1. Copy example tfvars → local gitignored `walle.tfvars`.  
2. Fill `stackgen_url`, `stackgen_token`, `stackgen_project_id`, LLM keys, integration secrets.  
   For GCP live plan also set `gcp_credentials_json` + `gcp_project_id` (optional `gcp_region`).  
3. From `agent-pipeline-config/deployments/walle/`:

```bash
tofu init
tofu plan  -var-file=walle.tfvars
tofu apply -var-file=walle.tfvars
```

4. Start / confirm the remote runner using the module’s CLI/Helm output.  
5. **Preload script pack** after every `script_pack_version` bump (see deployments README / module README). SHA mismatch fails stages loudly.

## Trigger a run

- Guild UI: start azure-only, gcp-only, or discovery with required inputs (e.g. AWS split branch).  
- Or SE demo scripts if your org uses `solutions` playbooks — this repo’s deployments README is the source of truth for **walle**.

## After you change pack files

Any edit under module `scripts/` or `mappings/` that the runner must execute:

1. Bump `script_pack_version` (module) **and** `SCRIPT_PACK_VERSION` (`stage-runner.sh`) together.  
2. `tofu apply` the deployment.  
3. Preload pack onto the runner.  
4. Confirm stage logs show the new version / matching sha256.

Skipping preload is the most common “it works on my laptop JSON but fails in Guild” bug.

## Troubleshooting matrix

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `preload_sha256_mismatch` | Runner pack stale | Re-preload; verify version string |
| `skipped:missing_credentials` / hard fail on plan | No `ARM_*` / GCP ADC | Attach destination secrets; or disable require-live-plan only if policy allows |
| Generate/validate loop forever | Hard env error treated as soft | Fix pack/creds; don’t expect LLM to invent credentials |
| Empty / tiny destination PR | Wrong AWS branch or empty groups | Confirm `aws/groups` in source branch |
| “Success” but N/M sample in report | Sample caps | Expected unless caps raised intentionally |
| Agent mute / no tools | Integration / model / runner | See solutions skill `troubleshoot-agent-silence` |

## Debug bundle

If someone shares `execution-*.zip`, use the Guild execution debug skill / SE run-review skill: diagnose from **exported events only**, without guessing from chat.

## Security hygiene

- Rotate tokens pasted into Slack/tickets/chat.  
- Keep `*.tfvars` with secrets out of git.  
- Prefer Reader-only Azure SP / Viewer-style GCP SA for this pipeline.  
- Treat dangerous-ops HITL as load-bearing, not optional noise.
