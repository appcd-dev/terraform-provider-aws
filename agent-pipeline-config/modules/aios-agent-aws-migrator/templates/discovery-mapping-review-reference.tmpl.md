# Discovery mapping review reference

This is an index to the live-in-repository migration sources, not another mapping authority. Read the selected destination catalog and resolver for the decision used in a run.

- Azure: `mappings/aws-to-azure.json`, resolved by `azure_mapping_catalog.py`; emitted HCL comes from `azure_iac_generate.py`.
- GCP: `mappings/aws-to-gcp.json`, resolved by `gcp_mapping_catalog.py`; emitted HCL comes from `gcp_iac_generate.py`.
- The catalogs record version, source type, target type, category, confidence, review note, companions, and any mapped attributes. Resolver output also derives status, emission, and HITL lane. The generator determines actual output.
- A target name or attribute mapping is a candidate decision, not proof of semantic equivalence. Check the source state values, generator output, and target provider schema for required fields and nested block shape.
- A `mapped` status does not by itself mean full-equivalent HCL. Check emission (`full_scaffold`, profile/identity scaffold, `resource_group_only`, `none`, or another value) and the review note.
- For AWS type semantics and attributes, use the AWS provider schema/docs; for target arguments, use the selected AzureRM or Google provider version schema/docs. Record which source/version supports a claim if it affects an edit.
- Keep corrections at the owning layer: catalog/resolver for a bad decision, generator for repeated wrong HCL, run HCL for run-specific values, and provider/version only for a confirmed schema issue. Keep AWS observations separate from assumed destination values.

Examples from the current catalogs to investigate, not copy as universal rules:

- `aws_vpc.cidr_block` is mapped toward a target network address-space field. Check whether the source value needs conversion to the target collection shape.
- `aws_subnet.vpc_id` is mapped toward a target network reference. Confirm whether the target expects a name, self-link, or generated-resource reference rather than copying an AWS ID.
- `aws_db_instance` defaults to a PostgreSQL target in both catalogs, while its review note calls out engine selection. Check the source engine before accepting that default.
- `aws_iam_role` has no ordinary attribute map. The generators emit identity scaffolding; they do not automatically translate AWS actions to Azure RBAC or GCP IAM.
- `aws_s3_bucket.bucket` maps toward a target storage name. Check provider constraints and whether generation emits an account/bucket/container structure.

For exhaustive per-type decisions and current values, inspect the versioned JSON catalogs. Do not copy or create a second static mapping table here.
