# Terraform diagnose and verify

Use this when format, init, validate, plan, or generated-HCL checks fail.

Read the full diagnostic, affected file/resource, provider version, and relevant state or plan value. Decide whether the cause is syntax, unsupported schema, missing input/credential, provider setup, dependency, plan behavior, or policy. These have different owners.

Change the layer that owns the defect: run-specific HCL for run-specific values; catalog or generator for repeatable output defects; provider/version config for confirmed schema constraints; environment or credentials for access/setup failures. Keep source observations separate from migration assumptions.

Review the diff and rerun the failed check. Compare the new diagnostic and planned value with the old ones. A successful write is not proof the defect changed. Report any check that could not run separately from a pass.
