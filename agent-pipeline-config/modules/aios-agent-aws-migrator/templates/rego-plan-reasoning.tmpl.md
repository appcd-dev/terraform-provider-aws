# Rego findings and Terraform plans

Use this when OPA/Rego reports a finding against generated Terraform.

Read the rule's predicate and remediation data, then inspect the affected resource address and exact plan JSON path/value. Compare that value with generated HCL, source-cloud evidence, and the selected provider schema. A field on one resource type may not exist at the same path on another.

Classify the cause before editing: absent source value, absent generated argument, unsupported provider field, stale/incomplete plan input, or policy/path mismatch. Change HCL or generator when configuration is wrong. Change Rego and add a plan-shaped regression test when the policy reads valid provider output incorrectly. Do not weaken a control or distort valid HCL to hide a mismatch.

After an edit, rerun plan and policy evaluation. Compare the new plan value and finding with the prior result. Record whether the evaluator observed the change and which findings remain.
