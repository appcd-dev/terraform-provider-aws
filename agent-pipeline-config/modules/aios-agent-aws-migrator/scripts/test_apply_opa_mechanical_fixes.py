#!/usr/bin/env python3
"""Unit tests for OPA mechanical remediations + finding→action mapping."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))

from apply_opa_mechanical_fixes import (  # noqa: E402
    apply_provider_schema_fixes,
    apply_remediations,
    ensure_resource_labels_line,
    remediations_from_findings,
)
from governance_opa_check import finding_to_remediation  # noqa: E402


class RemediationMappingTests(unittest.TestCase):
    def test_tag002_maps_to_set_label(self) -> None:
        finding = {
            "control_id": "TAG-002",
            "group_id": "g1",
            "resource_address": "google_storage_bucket.this",
            "message": (
                'TAG-002 governance/tagging-labeling-standard.md § Section 7 – '
                'GCP Label Standard: google_storage_bucket.this missing required '
                'GCP label "apm_id"'
            ),
        }
        rem = finding_to_remediation(finding, cloud="gcp")
        self.assertEqual(rem["action"], "set_label")
        self.assertEqual(rem["key"], "apm_id")
        self.assertTrue(rem["assumption"])

    def test_prio001_maps_to_set_label(self) -> None:
        finding = {
            "control_id": "PRIO-001",
            "group_id": "g1",
            "resource_address": "google_storage_bucket.this",
            "message": (
                'PRIO-001: governance/priority-controls.md § Section 5: '
                'google_storage_bucket.this missing required GCP label "owner"'
            ),
        }
        rem = finding_to_remediation(finding, cloud="gcp")
        self.assertEqual(rem["action"], "set_label")
        self.assertEqual(rem["key"], "owner")

    def test_firewall_label_deny_is_exempt(self) -> None:
        finding = {
            "control_id": "PRIO-001",
            "group_id": "g1",
            "resource_address": "google_compute_firewall.deny_ingress",
            "message": (
                'PRIO-001: google_compute_firewall.deny_ingress missing required '
                'GCP label "apm_id"'
            ),
        }
        rem = finding_to_remediation(finding, cloud="gcp")
        self.assertEqual(rem["action"], "exempt_resource")

    def test_provider_resources_without_labels_are_exempt(self) -> None:
        unsupported = {
            "google_logging_project_bucket_config": "google_logging_project_bucket_config.this",
            "google_bigtable_table": "google_bigtable_table.primary",
        }
        for resource_type, address in unsupported.items():
            with self.subTest(resource_type=resource_type):
                rem = finding_to_remediation(
                    {
                        "control_id": "TAG-002",
                        "resource_address": address,
                        "message": f'{address} missing required GCP label "owner"',
                    },
                    cloud="gcp",
                )
                self.assertEqual(rem["action"], "exempt_resource")

    def test_prg002_without_colon_parses_control(self) -> None:
        finding = {
            "control_id": "OPA_DENY",
            "group_id": "g1",
            "resource_address": "google_storage_bucket.this",
            "message": (
                'PRG-002 governance/production-readiness-gates.md ## 9: '
                'google_storage_bucket.this missing required GCP label "cost_center"'
            ),
        }
        rem = finding_to_remediation(finding, cloud="gcp")
        self.assertEqual(rem["control_id"], "PRG-002")
        self.assertEqual(rem["action"], "set_label")
        self.assertEqual(rem["key"], "cost_center")

    def test_fallback_from_findings(self) -> None:
        items = remediations_from_findings(
            [
                {
                    "control_id": "TAG-001",
                    "group_id": "a1",
                    "resource_address": "azurerm_resource_group.rg",
                    "message": (
                        'TAG-001 …: azurerm_resource_group.rg missing required '
                        'Azure tag "apmid"'
                    ),
                }
            ],
            "azure",
        )
        self.assertEqual(items[0]["action"], "set_tag")
        self.assertEqual(items[0]["key"], "apmid")


class ApplyFixesTests(unittest.TestCase):
    def test_schema_repair_does_not_delete_non_metadata_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            group = root / "gcp" / "groups" / "logs"
            group.mkdir(parents=True)
            main = group / "main.tf"
            original = 'resource "google_logging_project_bucket_config" "this" {\n  retention_days = 30\n}\n'
            main.write_text(original, encoding="utf-8")
            result = apply_provider_schema_fixes(
                root,
                "gcp",
                [{
                    "control_id": "PLAN_FAILED",
                    "group_id": "logs",
                    "message": (
                        'in resource "google_logging_project_bucket_config" "this": '
                        'An argument named "retention_days" is not expected here.'
                    ),
                }],
            )
            self.assertEqual(result["applied"], 0)
            self.assertEqual(main.read_text(encoding="utf-8"), original)

    def test_sql_user_labels_fix_is_nested_under_settings(self) -> None:
        source = (
            'resource "google_sql_database_instance" "this" {\n'
            '  settings {\n    tier = "db-f1-micro"\n  }\n'
            '}\n'
        )
        updated, count = ensure_resource_labels_line(
            source, "google_sql_database_instance.this"
        )
        self.assertEqual(count, 1)
        self.assertIn("user_labels = var.labels", updated)
        self.assertNotIn("\n  labels = var.labels", updated)

    def test_does_not_add_unsupported_gcp_label_arguments(self) -> None:
        resources = {
            "google_logging_project_bucket_config": 'resource "google_logging_project_bucket_config" "this" {\n  bucket_id = "b"\n}\n',
            "google_bigtable_table": 'resource "google_bigtable_table" "primary" {\n  name = "primary"\n}\n',
        }
        for resource_type, text in resources.items():
            with self.subTest(resource_type=resource_type):
                name = "primary" if resource_type.endswith("_table") else "this"
                updated, count = ensure_resource_labels_line(
                    text, f"{resource_type}.{name}"
                )
                self.assertEqual(count, 0)
                self.assertEqual(updated, text)

    def test_provider_schema_diagnostic_repairs_only_named_attribute(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            group = root / "gcp" / "groups" / "logs"
            group.mkdir(parents=True)
            main = group / "main.tf"
            main.write_text(
                'resource "google_logging_project_bucket_config" "this" {\n'
                '  bucket_id = "migration"\n'
                '  labels = var.labels\n'
                '}\n'
                'resource "google_storage_bucket" "other" {\n'
                '  labels = var.labels\n'
                '}\n',
                encoding="utf-8",
            )
            result = apply_provider_schema_fixes(
                root,
                "gcp",
                [{
                    "control_id": "PLAN_FAILED",
                    "group_id": "logs",
                    "message": (
                        'Error: Unsupported argument\\n  on main.tf line 3, in resource '
                        '"google_logging_project_bucket_config" "this":\\n'
                        'An argument named "labels" is not expected here.'
                    ),
                }],
            )
            updated = main.read_text(encoding="utf-8")
            self.assertEqual(result["applied"], 1)
            first_resource = updated.split('resource "google_storage_bucket"')[0]
            self.assertNotIn("labels = var.labels", first_resource)
            self.assertIn('resource "google_storage_bucket" "other" {', updated)
            self.assertIn('labels = var.labels', updated.split('resource "google_storage_bucket"')[1])

    def test_patches_labels_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            group = root / "gcp" / "groups" / "g1"
            group.mkdir(parents=True)
            (group / "variables.tf").write_text(
                '''variable "labels" {
  type = map(string)
  default = {
    owner = "platformengineering"
    environment = "dev"
  }
}
''',
                encoding="utf-8",
            )
            (group / "main.tf").write_text(
                '''resource "google_storage_bucket" "this" {
  name     = "bkt"
  location = "US"
}
''',
                encoding="utf-8",
            )
            (root / "gcp" / "artifacts").mkdir(parents=True)
            result = apply_remediations(
                root,
                "gcp",
                [
                    {
                        "action": "set_label",
                        "key": "apm_id",
                        "group_id": "g1",
                        "resource_address": "google_storage_bucket.this",
                    }
                ],
            )
            self.assertGreater(result["applied"], 0)
            vars_text = (group / "variables.tf").read_text(encoding="utf-8")
            self.assertIn("apm_id", vars_text)
            main_text = (group / "main.tf").read_text(encoding="utf-8")
            self.assertIn("labels = var.labels", main_text)
            assumptions = root / "gcp" / "artifacts" / "governance-assumptions.md"
            self.assertTrue(assumptions.is_file())
            self.assertIn("apm_id", assumptions.read_text(encoding="utf-8"))

    def test_patches_single_line_quoted_default_without_corruption(self) -> None:
        from apply_opa_mechanical_fixes import patch_labels_default_map

        src = (
            'variable "labels" {\n'
            "  type        = map(string)\n"
            '  default     = { "owner" = "platformengineering", "environment" = "dev" }\n'
            "}\n"
        )
        out, n = patch_labels_default_map(src, {"apm_id": "apm-migration"})
        self.assertGreater(n, 0)
        self.assertIn('apm_id = "apm-migration"', out)
        # Keys must stay inside the map braces, not after a same-line `}`.
        self.assertNotRegex(out, r'\}\s*\n\s*apm_id\s*=')
        # Map still closes before the variable block closes.
        self.assertIn("}", out.split("apm_id")[-1])


if __name__ == "__main__":
    unittest.main()
