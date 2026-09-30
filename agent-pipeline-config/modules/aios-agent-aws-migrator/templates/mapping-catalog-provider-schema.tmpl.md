# Mapping catalog and provider-schema research

Use this when deciding or reviewing an AWS-to-Azure/GCP mapping or generated target HCL. Existing catalogs, resolvers, and emitters are authoritative; this note is an index and method, not another mapping table.

- Azure: `mappings/aws-to-azure.json` → `azure_mapping_catalog.py` → `azure_iac_generate.py`.
- GCP: `mappings/aws-to-gcp.json` → `gcp_mapping_catalog.py` → `gcp_iac_generate.py`.

Read the decision for the source type: status, target, category, confidence, emission, review note, companions, and attribute mapping. Then inspect the emitter to see what it actually writes. `mapped` means a catalog target exists, not that equivalent HCL is complete. `non_applicable`, `unsupported`, `none`, placeholder, profile, and identity outputs differ.

## Research a mapping instead of guessing

Do not stop at the checked-in catalog when a source type is unsupported, low-confidence, or only receives a placeholder/profile scaffold. The catalog is not an exhaustive answer; treat it as a prior, not a closed list. Use the actual source state to understand what the AWS object does, then search the **Terraform Registry** for candidate GCP resources and inspect each candidate's documentation at the provider version pinned by the generated root (`gcp/groups/<group_id>/versions.tf`). Start with Registry search and the exact resource page, for example:

- Registry provider/resource search: `https://registry.terraform.io/search/providers?q=<service-or-resource-keyword>`
- Google provider resource docs: `https://registry.terraform.io/providers/hashicorp/google/<pinned-version>/docs/resources/<resource-name>`
- Google provider data-source docs: same path under `/docs/data-sources/`

Search by the AWS service concept and observed behavior, not just by `aws_*` name. Inspect required arguments, nested blocks, lifecycle/identity model, networking, supported fields, references, and whether the candidate is a resource or data source. If Registry search or a page is unavailable, use the official provider documentation/source for the same pinned release and record that source; do not infer schema from an unpinned “latest” page. Compare against AWS provider docs/state and relevant GCP service semantics. A similar name or a successful `tofu validate` is not evidence of behavioral equivalence.

For each gap, form and compare plausible target candidates. Record the source type/instance, candidate GCP type(s), pinned provider version, Registry/upstream URLs, observed source attributes, semantic fit and mismatches, confidence, and unresolved decisions in the run's `gcp/artifacts/mapping-research.md` (or inline research evidence in the mapping decision). Then choose the most defensible candidate when evidence supports it; explicitly retain an unresolved/unsupported disposition when it does not. Never fabricate source values or claim parity from resource counts alone.

## Turn research into a correct change

A per-run decision may update the run's blueprint and generated HCL only when the target is supported by cited evidence and the generator can express the required shape. For a repeatable AWS type/category gap, update the AWS→GCP catalog and generator in the script-pack source, add a fixture from representative AWS state plus assertions on emitted HCL and source-to-target accounting, bump the catalog/pack versions, and run the GCP tests. Do not “fix” a missing mapping by simply relabeling it `mapped` or reusing an unrelated category. Keep source evidence, Registry evidence, assumptions, confidence, and residual gaps distinguishable for reviewers.

Fix the owning layer: catalog/resolver for a bad decision, generator for repeatable output, run blueprint/HCL for a run-specific evidence-backed choice, or provider config for a confirmed schema issue. If schema evidence is unavailable, leave the claim unverified. Add a focused regression test when changing reusable behavior.
