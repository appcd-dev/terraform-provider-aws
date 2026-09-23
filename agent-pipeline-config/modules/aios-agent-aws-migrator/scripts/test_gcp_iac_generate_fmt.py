#!/usr/bin/env python3
"""Unit tests for gcp_iac_generate helpers (fmt-safe map emission)."""

from __future__ import annotations

import textwrap
import unittest

from gcp_iac_generate import (
    REQUIRED_GCP_LABELS,
    gcp_instance_template_name_prefix,
    hcl_string_map,
)

# Nile tagging-labeling-standard §7 / TAG-002 (session c6cb3339 deny root cause).
NILE_REQUIRED_LABEL_KEYS = (
    "owner",
    "created_by",
    "cost_center",
    "environment",
    "function",
    "service",
    "repo",
    "application_name",
    "name",
    "notification_distlist",
    "ssp",
    "tr_product_id",
    "apm_id",
)


class RequiredGcpLabelsTests(unittest.TestCase):
    def test_required_defaults_cover_nile_keys(self):
        # `name` is filled per group at emit time; the other 12 are constants.
        self.assertEqual(
            set(REQUIRED_GCP_LABELS),
            set(NILE_REQUIRED_LABEL_KEYS) - {"name"},
        )
        banned = {"tbd", "test", "unknown", "placeholder", "changeme", "none"}
        for key, value in REQUIRED_GCP_LABELS.items():
            self.assertTrue(str(value).strip(), key)
            self.assertNotIn(str(value).lower(), banned, key)


class MigNamePrefixTests(unittest.TestCase):
    def test_long_group_id_stays_within_gcp_limit(self):
        prefix = gcp_instance_template_name_prefix(
            "aws-staging-l3-untagged-autoscaling-group"
        )
        self.assertLessEqual(len(prefix), 37)
        self.assertTrue(prefix.startswith("mig-"))
        self.assertTrue(prefix.endswith("-"))

    def test_short_group_id_keeps_full_stem(self):
        prefix = gcp_instance_template_name_prefix("app")
        self.assertEqual(prefix, "mig-app-")


class HclStringMapTests(unittest.TestCase):
    def test_empty_map(self):
        self.assertEqual(hcl_string_map({}), "{}")

    def test_map_preserves_dedent_common_prefix(self):
        labels = {
            "generated_by": "stackgen-aws-migrator",
            "migration_group": "aws-default-l3-untagged-iam-role-169",
        }
        rendered = textwrap.dedent(
            f"""
      variable "labels" {{
        type    = map(string)
        default = {hcl_string_map(labels)}
      }}
    """
        ).lstrip()
        # First non-blank line must start at column 0 after dedent (tofu-friendly).
        first = next(line for line in rendered.splitlines() if line.strip())
        self.assertTrue(first.startswith("variable "), first)
        self.assertIn('"generated_by" = "stackgen-aws-migrator"', rendered)
        self.assertNotIn('"generated_by":', rendered)
        # Single-line map must not inject a bare `{` that breaks sibling indent.
        self.assertIn('default = { "', rendered)
        for line in rendered.splitlines():
            if line.strip().startswith("type"):
                self.assertTrue(line.startswith("  type"), line)
            if line.strip().startswith("default"):
                self.assertTrue(line.startswith("  default"), line)


if __name__ == "__main__":
    unittest.main()
