#!/usr/bin/env python3
"""Unit tests for governance_opa_check.py."""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

import governance_opa_check as goc


SAMPLE_PLAN = {
    "format_version": "1.2",
    "resource_changes": [
        {
            "address": "google_compute_network.example",
            "mode": "managed",
            "type": "google_compute_network",
            "name": "example",
            "change": {
                "actions": ["create"],
                "after": {
                    "name": "vpc-example",
                    "labels": {"owner": "team"},
                },
            },
        }
    ],
}


class GovernanceOpaCheckTest(unittest.TestCase):
    def test_parse_control_id_extracts_prefix(self) -> None:
        self.assertEqual(goc.parse_control_id("TLS-002: google_compute_network.example missing label"), "TLS-002")
        self.assertEqual(goc.parse_control_id("no prefix message"), "OPA_DENY")

    def test_parse_resource_address_matches_type_name(self) -> None:
        msg = "TLS-002: google_compute_network.example missing required GCP label"
        addr = goc.parse_resource_address(msg, SAMPLE_PLAN)
        self.assertEqual(addr, "google_compute_network.example")

    def test_refresh_rules_local_fixture(self) -> None:
        rules_root = Path("/tmp/nile-pr6-fix/rules")
        if not rules_root.is_dir():
            self.skipTest("local PR #6 rules fixture missing")
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp) / "work"
            work.mkdir()
            source = goc.refresh_rules(work, "https://example.invalid/nile.git", "main", rules_dir=rules_root)
            self.assertGreaterEqual(source["pack_count"], 1)
            self.assertTrue(Path(source["rules_root"]).is_dir())

    def test_eval_pack_denies_missing_labels(self) -> None:
        if shutil.which("opa") is None:
            self.skipTest("opa not installed")
        rules_root = Path("/tmp/nile-pr6-fix/rules")
        if not rules_root.is_dir():
            self.skipTest("local PR #6 rules fixture missing")
        policy = rules_root / "governance" / "tagging-labeling-standard" / "policy.rego"
        if not policy.is_file():
            self.skipTest("tagging policy missing")
        denies = goc.eval_pack_denies("opa", policy, SAMPLE_PLAN)
        self.assertTrue(any("TLS-002" in msg for msg in denies))

    def test_eval_pack_denies_clean_plan(self) -> None:
        if shutil.which("opa") is None:
            self.skipTest("opa not installed")
        rules_root = Path("/tmp/nile-pr6-fix/rules")
        if not rules_root.is_dir():
            self.skipTest("local PR #6 rules fixture missing")
        policy = rules_root / "governance" / "tagging-labeling-standard" / "policy.rego"
        if not policy.is_file():
            self.skipTest("tagging policy missing")
        good_labels = {
            "owner": "platformengineering",
            "created_by": "pipeline-sa",
            "cost_center": "cc-1001",
            "environment": "prod",
            "function": "network",
            "service": "nile",
            "repo": "walmart-stackgen_nile-factory",
            "application_name": "projectnile",
            "name": "vpc-nile-prod",
            "notification_distlist": "ops-team",
            "ssp": "ssp-123",
            "tr_product_id": "tr-456",
            "apm_id": "apm-789",
        }
        plan = {
            "format_version": "1.2",
            "resource_changes": [
                {
                    "address": "google_compute_network.example",
                    "mode": "managed",
                    "type": "google_compute_network",
                    "name": "example",
                    "change": {"actions": ["create"], "after": {"labels": good_labels}},
                }
            ],
        }
        denies = goc.eval_pack_denies("opa", policy, plan)
        self.assertEqual(denies, [])

    def test_deny_to_finding_shape(self) -> None:
        pack_dir = Path("tagging-labeling-standard")
        finding = goc.deny_to_finding(
            message="TLS-002: google_compute_network.example missing required GCP label \"repo\"",
            pack_dir=pack_dir,
            group_id="g1",
            plan=SAMPLE_PLAN,
        )
        self.assertEqual(finding["control_id"], "TLS-002")
        self.assertEqual(finding["group_id"], "g1")
        self.assertTrue(finding["blocks_commit"])

    def test_rego_guidance_targets_gke_provider_schema_path(self) -> None:
        if shutil.which("opa") is None:
            self.skipTest("opa not installed")
        policy = Path(__file__).resolve().parents[4] / "rules" / "governance" / "policy-catalog" / "policy.rego"
        if not policy.is_file():
            self.skipTest("Nile policy-catalog Rego not in source checkout")
        plan = {
            "resource_changes": [{
                "address": "google_container_cluster.this",
                "mode": "managed",
                "type": "google_container_cluster",
                "name": "this",
                "change": {"actions": ["create"], "after": {"resource_labels": {}}},
            }],
        }
        guidance = goc.eval_pack_remediation(shutil.which("opa") or "opa", policy, plan)
        self.assertTrue(guidance)
        self.assertTrue(all(item["control_id"] == "NPC-002" for item in guidance))
        self.assertTrue(all(item["target_path"].startswith("resource_labels.") for item in guidance))
        self.assertTrue(all("value_source" in item and "rationale" in item for item in guidance))

    def test_synthesize_plan_from_hcl_resolves_var_labels(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            group = Path(tmp) / "compute-web"
            group.mkdir()
            (group / "variables.tf").write_text(
                'variable "labels" {\n  default = {\n    owner = "platform"\n  }\n}\n',
                encoding="utf-8",
            )
            (group / "main.tf").write_text(
                '''
resource "google_compute_instance" "this" {
  name   = "vm-web"
  labels = var.labels
  network_interface {
    network = "default"
  }
}
''',
                encoding="utf-8",
            )
            plan = goc.synthesize_plan_from_hcl(group)
            self.assertIsNotNone(plan)
            assert plan is not None
            self.assertTrue(plan.get("synthetic"))
            changes = plan["resource_changes"]
            self.assertEqual(len(changes), 1)
            after = changes[0]["change"]["after"]
            self.assertEqual(after["name"], "vm-web")
            self.assertEqual(after["labels"], {"owner": "platform"})
            self.assertEqual(after["network_interface"][0]["network"], "default")

    def test_synthesize_plan_parses_quoted_single_line_label_defaults(self) -> None:
        """GCP generator emits default = { \"apm_id\" = \"…\", … } on one line."""
        with tempfile.TemporaryDirectory() as tmp:
            group = Path(tmp) / "api-gw"
            group.mkdir()
            (group / "variables.tf").write_text(
                'variable "labels" {\n'
                "  type = map(string)\n"
                '  default = { "apm_id" = "apm-migration", "owner" = "platformengineering", '
                '"cost_center" = "cc-migration" }\n'
                "}\n",
                encoding="utf-8",
            )
            (group / "main.tf").write_text(
                'resource "google_storage_bucket" "this" {\n'
                '  name     = "bkt"\n'
                '  location = "US"\n'
                "  labels   = var.labels\n"
                "}\n",
                encoding="utf-8",
            )
            defaults = goc._variable_defaults(group)
            self.assertEqual(defaults["labels"]["apm_id"], "apm-migration")
            self.assertEqual(defaults["labels"]["owner"], "platformengineering")
            plan = goc.synthesize_plan_from_hcl(group)
            assert plan is not None
            after = plan["resource_changes"][0]["change"]["after"]
            self.assertEqual(after["labels"]["apm_id"], "apm-migration")
            self.assertEqual(after["labels"]["cost_center"], "cc-migration")

    def test_plan_diagnostics_group_repeated_root_causes(self) -> None:
        findings = [
            {
                "control_id": "PLAN_FAILED",
                "group_id": f"group-{i}",
                "message": (
                    f'PLAN_FAILED: group-{i}: Error: Unsupported argument\\n'
                    'on main.tf line 3, in resource "google_logging_project_bucket_config" "this":\\n'
                    'An argument named "labels" is not expected here.'
                ),
            }
            for i in range(3)
        ]
        summaries = goc.summarize_failure_classes(findings)
        self.assertEqual(len(summaries), 1)
        self.assertEqual(summaries[0]["kind"], "unsupported_argument")
        self.assertEqual(summaries[0]["resource_type"], "google_logging_project_bucket_config")
        self.assertEqual(summaries[0]["attribute"], "labels")
        self.assertEqual(len(summaries[0]["groups"]), 3)

    def test_unclassified_diagnostic_does_not_guess_repair(self) -> None:
        result = goc.diagnose_plan_failure("Error: arbitrary provider failure")
        self.assertEqual(result["kind"], "unclassified_plan_error")
        self.assertEqual(result["recommended_action"], "inspect_full_plan_error_before_editing")

    def test_is_credential_plan_error(self) -> None:
        self.assertTrue(goc.is_credential_plan_error("Error: Could not find default credentials"))
        self.assertFalse(goc.is_credential_plan_error("Error: Unsupported argument"))


if __name__ == "__main__":
    unittest.main()
