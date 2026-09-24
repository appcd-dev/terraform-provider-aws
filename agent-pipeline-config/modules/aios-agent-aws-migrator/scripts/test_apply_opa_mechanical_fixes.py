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
    apply_remediations,
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
