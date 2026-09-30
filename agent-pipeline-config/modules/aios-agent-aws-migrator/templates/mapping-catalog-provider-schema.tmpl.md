# Mapping catalog and provider-schema research

Use this when deciding or reviewing an AWS-to-Azure/GCP mapping or generated target HCL. Existing catalogs, resolvers, and emitters are authoritative; this note is an index and method, not another mapping table.

- Azure: `mappings/aws-to-azure.json` → `azure_mapping_catalog.py` → `azure_iac_generate.py`.
- GCP: `mappings/aws-to-gcp.json` → `gcp_mapping_catalog.py` → `gcp_iac_generate.py`.

Read the decision for the source type: status, target, category, confidence, emission, review note, companions, and attribute mapping. Then inspect the emitter to see what it actually writes. `mapped` means a catalog target exists, not that equivalent HCL is complete. `non_applicable`, `unsupported`, `none`, placeholder, profile, and identity outputs differ.

Check source state for observed values and the selected provider version's schema/docs for required arguments, nested blocks, types, and accepted values. Similar AWS/target names do not prove semantic equivalence. If schema evidence is unavailable, leave the claim unverified.

Fix the owning layer: catalog/resolver for a bad decision, generator for repeated bad output, run HCL for a run-specific value, or provider config for a confirmed schema issue. Keep observations distinct from assumptions and add a focused regression test when changing reusable behavior.
