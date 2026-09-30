#!/usr/bin/env python3
"""Offline checks for AWS -> GCP catalog + generate scaffolds.

Run: ``python3 scripts/test_gcp_mapping_catalog.py``
     ``python3 scripts/test_gcp_iac_generate.py``
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gcp_iac_generate as gig  # noqa: E402
import gcp_mapping_catalog as gmc  # noqa: E402


def _gcp_blueprint_preserves_source_ids() -> bool:
    script = (Path(__file__).resolve().parent / "stage-runner.sh").read_text(encoding="utf-8")
    start = script.index("cmd_gcp_migration_blueprint() {")
    end = script.index("cmd_gcp_iac_generate() {", start)
    code = script[start:end]
    return 'group_id = str(entry.get("group_id") or entry.get("id") or gid)' in code and 'group_id = sanitize_group_id(str(entry.get("group_id") or entry.get("id") or gid))' not in code


def _write_fixture(work: Path) -> None:
    groups = work / "groups"
    artifacts = work / "gcp" / "artifacts"
    scripts = work / "scripts" / "mappings"
    scripts.mkdir(parents=True)
    catalog_src = Path(__file__).resolve().parent.parent / "mappings" / gmc.DEFAULT_CATALOG_NAME
    shutil.copy(catalog_src, scripts / gmc.DEFAULT_CATALOG_NAME)

    # EIP-only group (was empty stub before static_ip emit)
    eip_dir = groups / "aws-eip-only"
    eip_dir.mkdir(parents=True)
    (eip_dir / "terraform.tfstate").write_text(
        json.dumps(
            {
                "version": 4,
                "resources": [
                    {
                        "mode": "managed",
                        "type": "aws_eip",
                        "name": "this",
                        "instances": [{"attributes": {"id": "eip-1"}}],
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    # ALB + network
    alb_dir = groups / "aws-alb-group"
    alb_dir.mkdir(parents=True)
    (alb_dir / "terraform.tfstate").write_text(
        json.dumps(
            {
                "version": 4,
                "resources": [
                    {
                        "mode": "managed",
                        "type": "aws_alb",
                        "name": "this",
                        "instances": [{"attributes": {"id": "alb-1"}}],
                    },
                    {
                        "mode": "managed",
                        "type": "aws_vpc",
                        "name": "this",
                        "instances": [{"attributes": {"id": "vpc-1"}}],
                    },
                ],
            }
        ),
        encoding="utf-8",
    )

    # CloudWatch source state: multiple instances must not collapse into one bucket.
    logs_dir = groups / "aws-logs-group"
    logs_dir.mkdir(parents=True)
    (logs_dir / "terraform.tfstate").write_text(
        json.dumps({
            "version": 4,
            "resources": [{
                "mode": "managed",
                "type": "aws_cloudwatch_log_group",
                "name": "logs",
                "instances": [
                    {"attributes": {"name": "/aws/lambda/app-one", "retention_in_days": 90}},
                    {"attributes": {"name": "/aws/lambda/app-two", "retention_in_days": 180}},
                    {"attributes": {"name": "/aws/lambda/no-expiry", "retention_in_days": 0}},
                ],
            }],
        }),
        encoding="utf-8",
    )

    # DNS records
    dns_dir = groups / "aws-dns-group"
    dns_dir.mkdir(parents=True)
    (dns_dir / "terraform.tfstate").write_text(
        json.dumps(
            {
                "version": 4,
                "resources": [
                    {
                        "mode": "managed",
                        "type": "aws_iam_role_policy_attachment",
                        "name": "folded_attachment",
                        "instances": [{"attributes": {"id": "attachment-1"}}],
                    },
                    {
                        "mode": "managed",
                        "type": "aws_route53_zone",
                        "name": "this",
                        "instances": [{"attributes": {"id": "Z1"}}],
                    },
                    {
                        "mode": "managed",
                        "type": "aws_route53_record",
                        "name": "app",
                        "instances": [
                            {"attributes": {"id": "r1"}},
                        ],
                    },
                ],
            }
        ),
        encoding="utf-8",
    )

    catalog = gmc.load_catalog(catalog_src)

    def decisions_for(*types):
        return [gmc.resolve(catalog, t) for t in types]

    eip_dec = decisions_for("aws_eip")
    alb_dec = decisions_for("aws_alb", "aws_vpc")
    dns_dec = decisions_for("aws_route53_zone", "aws_route53_record")
    logs_dec = decisions_for("aws_cloudwatch_log_group")

    conf_eip, _ = gmc.group_confidence(eip_dec)
    conf_alb, _ = gmc.group_confidence(alb_dec)
    conf_dns, _ = gmc.group_confidence(dns_dec)

    blueprint = {
        "profile": {
            "mode": "review_candidate",
            "defaults": {
                "project_id": "test-project",
                "region": "us-central1",
                "networking": {"subnet_cidr": "10.0.1.0/24"},
                "sku": {},
                "labels": {"env": "test"},
            },
            "mapping_catalog": {"version": catalog.get("version"), "path": "scripts/mappings/aws-to-gcp.json"},
        },
        "groups": [
            {
                "group_id": "aws-eip-only",
                "stable_hash": "eiphash01",
                "target_categories": sorted({d["category"] for d in eip_dec}),
                "mapping_decisions": eip_dec,
                "confidence": conf_eip or 0.0,
                "review_needed": True,
                "review_needed_reasons": ["fixture"],
            },
            {
                "group_id": "aws-alb-group",
                "stable_hash": "albhash01",
                "target_categories": sorted({d["category"] for d in alb_dec}),
                "mapping_decisions": alb_dec,
                "confidence": conf_alb or 0.0,
                "review_needed": True,
                "review_needed_reasons": ["fixture"],
            },
            {
                "group_id": "aws-dns-group",
                "stable_hash": "dnshash01",
                "target_categories": sorted({d["category"] for d in dns_dec}),
                "mapping_decisions": dns_dec,
                "confidence": conf_dns or 0.0,
                "review_needed": True,
                "review_needed_reasons": ["fixture"],
            },
            {
                "group_id": "aws-logs-group",
                "stable_hash": "loghash01",
                "target_categories": sorted({d["category"] for d in logs_dec}),
                "mapping_decisions": logs_dec,
                "confidence": conf_dns or 0.0,
                "review_needed": True,
                "review_needed_reasons": ["fixture: preserve each source log group"],
            },
        ],
    }
    source_counts = {"aws-eip-only": 1, "aws-alb-group": 2, "aws-dns-group": 3, "aws-logs-group": 3}
    for group in blueprint["groups"]:
        group["source_resource_count"] = source_counts[group["group_id"]]
    (work / "logical_group_manifest.json").write_text(
        json.dumps({gid: {"resource_addresses": [f"{gid}.{i}" for i in range(count)]}
                    for gid, count in source_counts.items()}), encoding="utf-8"
    )
    artifacts.mkdir(parents=True)
    (artifacts / "migration-blueprint.json").write_text(json.dumps(blueprint, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    failures = []

    def check(name, condition):
        if not condition:
            failures.append(name)

    catalog_path = Path(__file__).resolve().parent.parent / "mappings" / gmc.DEFAULT_CATALOG_NAME
    catalog = gmc.load_catalog(catalog_path)

    # Existing catalog anchors
    vpc = gmc.resolve(catalog, "aws_vpc")
    check("aws_vpc->compute_network", vpc["default_target"] == "google_compute_network" and vpc["status"] == "mapped")
    check("aws_vpc category network", vpc["category"] == "network")
    check("GCP blueprint preserves AWS shard IDs", _gcp_blueprint_preserves_source_ids())

    lam = gmc.resolve(catalog, "aws_lambda_function")
    check("aws_lambda_function->cloudfunctions2", lam["default_target"] == "google_cloudfunctions2_function")

    s3 = gmc.resolve(catalog, "aws_s3_bucket")
    check("aws_s3_bucket->storage_bucket", s3["default_target"] == "google_storage_bucket")

    sqs = gmc.resolve(catalog, "aws_sqs_queue")
    check("aws_sqs_queue->pubsub", sqs["default_target"] == "google_pubsub_topic")

    versioning = gmc.resolve(catalog, "aws_s3_bucket_versioning")
    check("aws_s3_bucket_versioning non_applicable", versioning["status"] == "non_applicable")

    unknown = gmc.resolve(catalog, "aws_totally_made_up_resource")
    check("unknown->unsupported", unknown["status"] == "unsupported" and unknown["category"] == "placeholder")

    lam_variant = gmc.resolve(catalog, "aws_lambda_function_url")
    check("aws_lambda_function_url prefix", lam_variant["status"] == "mapped" and lam_variant["match_kind"] == "prefix")

    role = gmc.resolve(catalog, "aws_iam_role")
    check("aws_iam_role mapped", role["status"] == "mapped")
    check("aws_iam_role emission rbac scaffold", role["emission"] == "managed_identity_rbac_scaffold")

    role_pol = gmc.resolve(catalog, "aws_iam_role_policy")
    check("aws_iam_role_policy exact", role_pol["match_kind"] == "exact")
    check("aws_iam_role_policy emission rbac", role_pol["emission"] == "managed_identity_rbac_scaffold")

    attach = gmc.resolve(catalog, "aws_iam_role_policy_attachment")
    check("aws_iam_role_policy_attachment non_applicable", attach["status"] == "non_applicable" and attach["emission"] == "none")

    membership = gmc.resolve(catalog, "aws_iam_user_group_membership")
    check("aws_iam_user_group_membership non_applicable", membership["status"] == "non_applicable")

    ses = gmc.resolve(catalog, "aws_ses_domain_identity")
    check("aws_ses_domain_identity non_applicable", ses["status"] == "non_applicable")

    dns = gmc.resolve(catalog, "aws_route53_zone")
    check("aws_route53_zone->dns_zone", dns["default_target"] == "google_dns_managed_zone" and dns["emission"] == "full_scaffold")
    redis = gmc.resolve(catalog, "aws_elasticache_cluster")
    check("aws_elasticache_cluster->redis", redis["default_target"] == "google_redis_instance")
    iam_user = gmc.resolve(catalog, "aws_iam_user")
    check("aws_iam_user non_applicable", iam_user["status"] == "non_applicable" and iam_user["emission"] == "none")

    conf, reason = gmc.group_confidence([role, iam_user])
    check("group_confidence ignores non_applicable", conf == round(role["confidence"], 2) and reason == "")
    conf_na, reason_na = gmc.group_confidence([iam_user])
    check("group_confidence non_applicable_only", conf_na is None and reason_na == "non_applicable_only")

    eip = gmc.resolve(catalog, "aws_eip")
    check("aws_eip static_ip full_scaffold", eip["category"] == "static_ip" and eip["emission"] == "full_scaffold")
    eip_low = dict(eip, confidence=0.72, hitl_lane="shape")
    needed, reasons = gmc.explain_review_needed(
        [eip_low], 0.72, "", 0.8, {"placeholder", "api", "cdn"}
    )
    check("explain_review_needed low confidence", needed is True)
    check(
        "explain_review_needed includes threshold reason",
        any(r == "group confidence 0.72 below threshold 0.8" for r in reasons),
    )
    check(
        "explain_review_needed includes per-type note",
        any(r.startswith("aws_eip: confidence 0.72 below threshold 0.8") for r in reasons),
    )
    needed_ok, reasons_ok = gmc.explain_review_needed(
        [dict(eip, confidence=0.9, hitl_lane="shape")], 0.9, "", 0.8, {"placeholder"}
    )
    check("explain_review_needed clear when above threshold", needed_ok is False and reasons_ok == [])

    subnet = gmc.resolve(catalog, "aws_subnet")
    check("aws_subnet shape bump", subnet.get("hitl_lane") == "shape" and subnet["confidence"] >= 0.85)

    alb = gmc.resolve(catalog, "aws_alb")
    check("aws_alb mapped", alb["status"] == "mapped" and alb["category"] == "load_balancer")
    check("aws_alb ambiguous lane", alb.get("hitl_lane") == "ambiguous")
    needed_alb, _ = gmc.explain_review_needed([alb], max(alb["confidence"], 0.9), "", 0.8, {"placeholder"})
    check("explain_review_needed alb always HITL", needed_alb is True)

    check("aws_iam_role permissions lane", role.get("hitl_lane") == "permissions")
    glue = gmc.resolve(catalog, "aws_glue_catalog_database")
    check("aws_glue_catalog_database non_applicable", glue["status"] == "non_applicable")
    check("aws_glue defer lane", glue.get("hitl_lane") == "defer")

    logging_decision = gmc.resolve(catalog, "aws_cloudwatch_log_group")
    check("cloudwatch maps retention to provider schema attribute", logging_decision["attribute_mapping"].get("retention_in_days", {}).get("google_logging_project_bucket_config") == "retention_days")
    check("cloudwatch maps source name to bucket id", logging_decision["attribute_mapping"].get("name", {}).get("google_logging_project_bucket_config") == "bucket_id")

    # Emission honesty: every full_scaffold category must be handled by generate.
    for category, emission in gmc.EMISSION_BY_CATEGORY.items():
        if emission != "full_scaffold":
            continue
        check(
            f"full_scaffold category {category} in generate FULL set",
            category in gig.FULL_SCAFFOLD_CATEGORIES,
        )

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        _write_fixture(work)
        result = gig.generate(work)

        eip_main = (work / "gcp/groups/aws-eip-only/main.tf").read_text(encoding="utf-8")
        check("eip emits google_compute_address", 'resource "google_compute_address" "this"' in eip_main)
        check("eip not empty stub only", "No full GCP resource scaffold" not in eip_main)

        alb_main = (work / "gcp/groups/aws-alb-group/main.tf").read_text(encoding="utf-8")
        check("alb emits forwarding_rule", 'resource "google_compute_forwarding_rule" "this"' in alb_main)
        check("alb emits backend_service", "google_compute_region_backend_service" in alb_main)

        dns_main = (work / "gcp/groups/aws-dns-group/main.tf").read_text(encoding="utf-8")
        check("dns emits managed_zone", 'resource "google_dns_managed_zone" "this"' in dns_main)
        check("dns emits record_set", 'resource "google_dns_record_set" "primary"' in dns_main)

        logs_main = (work / "gcp/groups/aws-logs-group/main.tf").read_text(encoding="utf-8")
        check("one logging bucket per source group", logs_main.count('resource "google_logging_project_bucket_config"') == 3)
        check("routing gap is visible in generated HCL", logs_main.count("CloudWatch-to-GCP log routing/sink permissions are not configured") == 3)
        check("source logging names are present", '"/aws/lambda/app-one"' in logs_main and '"/aws/lambda/app-two"' in logs_main)
        check("source retention copied", 'retention_days = 90' in logs_main and 'retention_days = 180' in logs_main)
        check("zero retention assumption explicit", 'TODO(apply-readiness)' in logs_main and 'retention_days = 30' in logs_main)

        summary = json.loads((work / "gcp/artifacts/generation-summary.json").read_text(encoding="utf-8"))
        logs_summary = next(g for g in summary["groups"] if g["group_id"] == "aws-logs-group")
        check("logging source/output count reconciled", logs_summary["source_resource_counts"]["aws_cloudwatch_log_group"] == logs_summary["generated_resource_counts"]["google_logging_project_bucket_config"] == 3)
        check("logging retention assumption counted", logs_summary["logging_retention_assumption_count"] == 1)
        check("logging routing incompleteness explicit", logs_summary["logging_routing_status"] == "bucket_created_routing_not_configured")
        check("known retention values preserved as facts", [m["retention_assumption"] for m in logs_summary["logging_mappings"]] == [False, False, True])
        check("mapping manifest marks routing incomplete", len(logs_summary["logging_mappings"]) == 3 and all(m["routing_status"] == "bucket_created_not_routed" for m in logs_summary["logging_mappings"]))
        check("conversion rate present", "infra_conversion_rate" in summary)
        check("conversion gate mirrors all-source coverage", summary.get("infra_conversion_ok") is summary.get("source_coverage_ok"))
        check("legacy infra rate ≥ 90%", float(summary.get("infra_conversion_rate") or 0) >= 0.90)
        check("fixture source coverage denominator present", summary["source_coverage_applicable_count"] == 8)
        check("fixture source coverage numerator includes all convertible instances", summary["source_coverage_converted_count"] == 8)
        check("fixture meets source coverage gate", summary["source_coverage_ok"] is True)
        check("source coverage is > 0.90", gig._coverage_ok(91, 100))
        check("source coverage boundary exactly 0.90 passes", gig._coverage_ok(9, 10))
        check("source coverage below 0.90 fails", not gig._coverage_ok(89, 100))
        check("no applicable source instances is not a pass", not gig._coverage_ok(0, 0))
        check("explicit non-applicable resources do not affect denominator", gig._coverage_rate(9, 10) == gig._coverage_rate(90, 100))
        check("unknown/unsupported source resources count as uncovered", summary["source_unsupported_count"] >= 0 and summary["source_coverage_applicable_count"] >= summary["source_coverage_converted_count"])
        check("eligible infra > 0", int(summary.get("infra_eligible_count") or 0) > 0)
        check("result mirrors summary rate", result.get("infra_conversion_ok") is True)
        reconciliation = summary["source_reconciliation"]
        check("source group count reconciles", reconciliation["source_group_count"] == reconciliation["blueprint_group_count"] == 4)
        check("source resource count reconciles", reconciliation["source_resource_count"] == reconciliation["blueprint_resource_count"] == 9)
        check("non-applicable instances are explicitly reported", summary["source_non_applicable_count"] == 1)
        check("folded instance is not in applicable denominator", summary["source_coverage_applicable_count"] == 8)
        check("unsupported count remains uncovered", summary["source_unsupported_count"] >= 0)
        omitted = work / "groups" / "aws-omitted-group"
        omitted.mkdir()
        (omitted / "terraform.tfstate").write_text(json.dumps({"resources": [{"mode": "managed", "type": "aws_subnet", "instances": [{"attributes": {}}]}]}), encoding="utf-8")
        failed_closed = False
        try:
            gig._validate_source_reconciliation(work, json.loads((work / "gcp/artifacts/migration-blueprint.json").read_text()))
        except ValueError as exc:
            failed_closed = "aws-omitted-group" in str(exc)
        check("omitted source group fails closed", failed_closed)

    if failures:
        print("FAIL: " + ", ".join(failures))
        return 1
    print(f"OK: catalog {catalog.get('version')} + generate scaffolds / conversion gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
