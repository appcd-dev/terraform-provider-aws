#!/usr/bin/env python3
"""Unit tests for gcp_iac_generate helpers (fmt-safe map emission)."""

from __future__ import annotations

import textwrap
import unittest

from gcp_iac_generate import hcl_string_map


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
