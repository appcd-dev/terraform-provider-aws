# 9. How to change things

## Before you edit

1. Read [mental model](01-mental-model.md) + [LLM vs scripts](05-llm-vs-scripts.md).  
2. Decide which world you are changing: **pipeline config** or **generator/catalog**.  
3. Prefer a **small fixture** (1–3 groups) over a 300-group demo for first validation.

## Change types

### A. Catalog only (new AWS type → existing emission)

1. Edit `mappings/aws-to-azure.json` and/or `mappings/aws-to-gcp.json`.  
2. Update the matching mappings README if schema/behavior docs need it.  
3. Bump pack version + apply + preload.  
4. Run azure-only / gcp-only on a branch that contains that type.

### B. Generator HCL shapes

1. Edit `scripts/azure_iac_generate.py` or `scripts/gcp_iac_generate.py`.  
2. Add/adjust tests beside the script.  
3. Bump pack version + apply + preload.  
4. Diff one generated group folder before/after.

### C. Workflow stage text / evidence

1. Edit the right `workflows_*.tf` / `locals_*_stages.tf` / `templates/*.tftpl`.  
2. Keep stage instructions clear: LLM pastes series; scripts do mapping.  
3. Apply deployment (pack bump only if templates embed pack scripts that changed).

### D. Destination live-plan wiring

1. Azure: `aios-integration-azure` + runner `ARM_*` secrets + `require_azure_live_plan`.  
2. GCP: `aios-integration-gcp` + runner ADC secret + `require_gcp_live_plan`.  
3. Document PR honesty if sample caps stay low.

### E. Policies

1. Edit deployment `policies/*.rego` carefully.  
2. Apply; verify HITL still gates destructive shell.

## Definition of done (suggested)

- [ ] Docs/README updated if behavior changed for humans  
- [ ] Pack version bumped when runner files changed  
- [ ] Apply + preload done on a real runner  
- [ ] One azure-only run on a small PR  
- [ ] PR review checklist in [doc 07](07-reading-azure-prs.md) passes for that run  
- [ ] No secrets in git  

## What not to do

- Do not “fix” bad Azure HCL by lengthening the agent persona.  
- Do not claim full live plan when sample caps are enabled.  
- Do not commit `walle.tfvars`, tokens, or `init.out`/`plan.out`.  
- Do not raise `AZURE_LIVE_PLAN_MAX_GROUPS` to “all” in demos without checking runtime cost.
