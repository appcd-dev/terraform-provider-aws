# AWS → GCP migration mapping catalog

`aws-to-gcp.json` is the destination-cloud twin of [`aws-to-azure.json`](aws-to-azure.json).
The GCP blueprint and generate stages load it on the runner.

## Schema

Same shape as the Azure catalog, with:

- `destination_cloud`: `"gcp"`
- `gcp_service_label` instead of `azure_service_label`
- `default_target_resource_type` / companions using `google_*` types

Emission and status semantics match the Azure catalog (`mapped` ≠ full equivalent HCL).

Source discovery hygiene (IAM Deny + default `cloud2code_exclude` for `non_applicable` types) is documented in [`README.md`](README.md#source-cloud-discovery-hygiene).

## Extending

1. Add/adjust AWS types under `resource_migration_map` with honest `category` / `emission` implications.
2. Bump `version`.
3. Bump `local.script_pack_version` and re-preload the runner pack.
4. Run `python3 ../scripts/test_gcp_mapping_catalog.py`.
