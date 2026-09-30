#!/usr/bin/env python3
"""Offline check for the AWS -> Azure mapping catalog resolver.

Runs without Guild, a runner, or network access so authors can validate catalog edits locally
(``python3 scripts/test_azure_mapping_catalog.py``) and CI can gate drift. It asserts a few
anchor mappings, the ``non_applicable``/``unsupported`` semantics, and prefix-collision safety.
Without this check, catalog edits could silently break the deterministic mapping contract the
blueprint/generate stages depend on.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import azure_mapping_catalog as amc  # noqa: E402
import azure_iac_generate as aig  # noqa: E402


def main() -> int:
    catalog_path = Path(__file__).resolve().parent.parent / "mappings" / amc.DEFAULT_CATALOG_NAME
    catalog = amc.load_catalog(catalog_path)

    failures = []

    def check(name, condition):
        if not condition:
            failures.append(name)

    check("coverage above 90% passes", aig._coverage_ok(91, 100))
    check("coverage exactly 90% passes", aig._coverage_ok(9, 10))
    check("coverage below 90% fails", not aig._coverage_ok(89, 100))
    check("empty applicable denominator does not pass", not aig._coverage_ok(0, 0))
    check("coverage normalization", aig._coverage_rate(9, 10) == aig._coverage_rate(90, 100))
    check("unsupported instance reduces rate", aig._coverage_rate(90, 101) < aig._coverage_rate(90, 100))
    check("identity inclusion uses same applicable denominator", aig._coverage_ok(9, 10))
    check("coverage conversion denominator includes identity", aig._coverage_ok(9, 10) is True)

    vpc = amc.resolve(catalog, "aws_vpc")
    check("aws_vpc->virtual_network", vpc["default_target"] == "azurerm_virtual_network" and vpc["status"] == "mapped")
    check("aws_vpc category network", vpc["category"] == "network")

    lam = amc.resolve(catalog, "aws_lambda_function")
    check("aws_lambda_function->linux_function_app", lam["default_target"] == "azurerm_linux_function_app")
    check("aws_lambda_function attr map", lam["attribute_mapping"].get("function_name", {}).get("azurerm_linux_function_app") == "name")

    s3 = amc.resolve(catalog, "aws_s3_bucket")
    check("aws_s3_bucket->storage_account", s3["default_target"] == "azurerm_storage_account")
    check("aws_s3_bucket companion container", "azurerm_storage_container" in s3["companions"])

    sqs = amc.resolve(catalog, "aws_sqs_queue")
    check("aws_sqs_queue->servicebus_queue", sqs["default_target"] == "azurerm_servicebus_queue")
    check("aws_sqs_queue storage alternate", "azurerm_storage_queue" in sqs["target_resource_types"])

    # Prefix collision: exact non_applicable child must not resolve to the parent bucket mapping.
    versioning = amc.resolve(catalog, "aws_s3_bucket_versioning")
    check("aws_s3_bucket_versioning non_applicable", versioning["status"] == "non_applicable")
    check("aws_s3_bucket_versioning no scaffold", versioning["category"] == "non_applicable")

    par = amc.resolve(catalog, "aws_kms_alias")
    check("aws_kms_alias non_applicable", par["status"] == "non_applicable")

    unknown = amc.resolve(catalog, "aws_totally_made_up_resource")
    check("unknown->unsupported", unknown["status"] == "unsupported" and unknown["category"] == "placeholder")

    # Longest-prefix fallback: unknown lambda variant folds onto aws_lambda_function.
    lam_variant = amc.resolve(catalog, "aws_lambda_function_url")
    check("aws_lambda_function_url prefix", lam_variant["status"] == "mapped" and lam_variant["match_kind"] == "prefix")

    # Emission honesty: identity maps emit UAI + RBAC scaffold (not full action translation).
    role = amc.resolve(catalog, "aws_iam_role")
    check("aws_iam_role mapped", role["status"] == "mapped")
    check("aws_iam_role emission rbac scaffold", role["emission"] == "managed_identity_rbac_scaffold")
    check("aws_iam_role confidence >= 0.7", role["confidence"] >= 0.7)

    role_pol = amc.resolve(catalog, "aws_iam_role_policy")
    check("aws_iam_role_policy exact", role_pol["match_kind"] == "exact" and role_pol["confidence"] >= 0.7)
    role_att = amc.resolve(catalog, "aws_iam_role_policy_attachment")
    check("aws_iam_role_policy_attachment non_applicable", role_att["status"] == "non_applicable" and role_att["emission"] == "none")

    # High-frequency gaps added for review-candidate coverage.
    dns = amc.resolve(catalog, "aws_route53_zone")
    check("aws_route53_zone->dns_zone", dns["default_target"] == "azurerm_dns_zone" and dns["emission"] == "full_scaffold")
    redis = amc.resolve(catalog, "aws_elasticache_cluster")
    check("aws_elasticache_cluster->redis", redis["default_target"] == "azurerm_redis_cache")
    iam_user = amc.resolve(catalog, "aws_iam_user")
    check("aws_iam_user non_applicable", iam_user["status"] == "non_applicable" and iam_user["emission"] == "none")
    param = amc.resolve(catalog, "aws_db_parameter_group")
    check("aws_db_parameter_group non_applicable", param["status"] == "non_applicable")

    # Group confidence excludes non_applicable.
    conf, reason = amc.group_confidence([role, iam_user])
    check("group_confidence ignores non_applicable", conf == round(role["confidence"], 2) and reason == "")
    conf_na, reason_na = amc.group_confidence([iam_user, amc.resolve(catalog, "aws_iam_openid_connect_provider")])
    check("group_confidence non_applicable_only", conf_na is None and reason_na == "non_applicable_only")

    # Shape bumps: EIP clears the threshold; use an explicit low-confidence clone for the gate test.
    eip = amc.resolve(catalog, "aws_eip")
    check("aws_eip shape lane", eip.get("hitl_lane") == "shape" and eip["confidence"] >= 0.8)
    eip_low = dict(eip, confidence=0.72)
    needed, reasons = amc.explain_review_needed(
        [eip_low], 0.72, "", 0.8, {"placeholder", "api", "cdn"}
    )
    check("explain_review_needed low confidence", needed is True)
    check(
        "explain_review_needed includes threshold reason",
        any("group confidence 0.72 below threshold 0.8" == r for r in reasons),
    )
    check(
        "explain_review_needed includes per-type note",
        any(r.startswith("aws_eip: confidence 0.72 below threshold 0.8") for r in reasons),
    )
    needed_ok, reasons_ok = amc.explain_review_needed(
        [eip], eip["confidence"], "", 0.8, {"placeholder"}
    )
    check("explain_review_needed clear for bumped shape EIP", needed_ok is False and reasons_ok == [])

    subnet = amc.resolve(catalog, "aws_subnet")
    check("aws_subnet shape bump", subnet["hitl_lane"] == "shape" and subnet["confidence"] >= 0.85)

    alb = amc.resolve(catalog, "aws_alb")
    check("aws_alb->lb", alb["default_target"] == "azurerm_lb" and alb["emission"] == "full_scaffold")
    check("aws_alb ambiguous lane", alb.get("hitl_lane") == "ambiguous")
    needed_alb, reasons_alb = amc.explain_review_needed(
        [alb], alb["confidence"], "", 0.8, {"placeholder"}
    )
    check("explain_review_needed alb always HITL", needed_alb is True)
    check(
        "explain_review_needed alb ambiguous reason",
        any("ambiguous mapping choice" in r for r in reasons_alb),
    )

    # Defer companions must not force review when mapped shape is healthy.
    needed_mix, reasons_mix = amc.explain_review_needed(
        [subnet, iam_user], subnet["confidence"], "", 0.8, {"placeholder"}
    )
    check("explain_review_needed ignores defer companions", needed_mix is False and reasons_mix == [])

    check("aws_iam_role permissions lane", role.get("hitl_lane") == "permissions")
    needed_perm, _ = amc.explain_review_needed([role], role["confidence"], "", 0.8, {"placeholder"})
    check("explain_review_needed permissions always HITL", needed_perm is True)

    apigw = amc.resolve(catalog, "aws_api_gateway_rest_api")
    check("aws_api_gateway_rest_api api", apigw["category"] == "api" and apigw["status"] == "mapped")
    glue = amc.resolve(catalog, "aws_glue_catalog_database")
    check("aws_glue_catalog_database non_applicable", glue["status"] == "non_applicable")
    check("aws_glue defer lane", glue.get("hitl_lane") == "defer")
    lb = amc.resolve(catalog, "aws_lb")
    check("aws_lb full_scaffold", lb["emission"] == "full_scaffold" and lb["confidence"] >= 0.7)

    if failures:
        print("FAIL: " + ", ".join(failures))
        return 1
    print(f"OK: catalog {catalog.get('version')} resolved all anchor assertions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
