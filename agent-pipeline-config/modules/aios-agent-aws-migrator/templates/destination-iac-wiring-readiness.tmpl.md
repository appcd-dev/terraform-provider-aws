# Destination IaC wiring and apply-readiness reasoning

Use this skill for generated Azure/GCP IaC, especially when validation or policy findings expose incomplete wiring. The objective is the most complete **evidence-supported** destination configuration, not merely syntactically valid scaffolding. Do not call a review scaffold apply-ready because `tofu validate` passed.

## Trace each source resource to the destination

For each inventoried managed source instance:

1. Read the source state/HCL attributes and resource relationships. Keep source observations, derived values, assumptions, and unknowns distinct.
2. Resolve the AWS type through the checked-in destination mapping catalog and resolver. Inspect status, target, category, emission, mapped attributes, companion resources, and review rationale.
3. Inspect the actual generator branch for that category and compare its output with the source instance values. A category-level placeholder is not instance-level migration.
4. Check the pinned provider schema/docs for the exact destination resource type, required arguments, nested blocks, computed/immutable fields, accepted values, and dependency references.
5. Wire resource references and generated outputs to the actual objects. Ensure one source instance is not silently collapsed into one generic destination object when the target model supports per-instance resources. If one-to-many or many-to-one translation is necessary, document the grouping/aggregation semantics and preserve inventory/accounting.
6. Record the disposition for every source instance: emitted with evidence-backed fields, intentionally folded into a named destination resource, non-applicable with reason, unsupported/blocked, or unresolved assumption. Report counts and prove reconciliation against source inventory.

## Fix at the right layer

- A repeatable category/type defect belongs in the catalog, resolver, or generator, with a regression fixture representing source state and expected generated HCL.
- A value unique to this migration belongs in generated HCL or its inputs, derived from source evidence when available.
- A policy false positive belongs in the Rego predicate and needs a plan-shaped test; do not distort correct provider HCL to appease it.
- A provider setup, credentials, permissions, or live-plan outage is an execution/evidence blocker, not an IaC repair.
- If the source lacks a necessary choice (for example, destination region, retention policy, identity permissions, data residency), preserve a safe, explicit variable only when the provider supports it, record the assumption and replacement steps, and do not invent an owner decision.

## Verify the wiring, not just syntax

After edits:

- Compare source instance counts/attributes/relationships with emitted destination resources and explicit folded/unsupported records.
- Run `tofu fmt`, `tofu validate`, tests, and a plan when credentials are available; inspect the plan values and dependency graph for the changed resources.
- Run Rego against that plan, compare findings/fingerprints, and confirm the evaluator observed the new values.
- Report static validation, live-plan evidence, governance, and unresolved architectural choices as separate statuses. Missing credentials means no live-plan evidence; it is never a plan pass.

Do not run `tofu apply` in the migration workflow. Human approval, permissions, quotas, networking, and cutover decisions remain outside the agent's authority. An output may be the best review candidate possible without being apply-ready; state that boundary plainly.
