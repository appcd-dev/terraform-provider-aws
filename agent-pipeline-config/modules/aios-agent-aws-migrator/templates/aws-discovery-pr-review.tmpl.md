# AWS discovery PR review

Use this skill while preparing the discovery PR and final handoff. Treat it as a review lens, not a template for conclusions.

Read the generated artifacts and decide what a reviewer needs to know. Ground statements in the account, region, scan settings, state, Cloud2Code log, per-type summaries, Terraform groups, and validation outputs. Connect each notable finding to its source and its practical effect on review or downstream migration.

Use specific observations instead of generic praise or workflow narration. Keep counts tied to the artifact that produced them. A warning sample does not describe every skipped resource. If the logs do not identify a cause, leave it unknown. Avoid repeating metrics that do not change the review, and do not claim fixes, coverage, or validation that the artifacts do not show.

The PR should let a human quickly see what was discovered, what needs attention, where the evidence lives, and what remains uncertain. Make the judgment from the evidence; this skill does not prescribe a completeness verdict.
