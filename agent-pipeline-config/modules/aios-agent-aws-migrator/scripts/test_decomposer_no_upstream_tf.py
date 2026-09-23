#!/usr/bin/env python3
"""Decomposer must not emit upstream.tf / terraform_remote_state scaffolds."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from tfstate_monolith_decomposer import (
    scaffold_remote_state,
    write_upstream_refs_artifact,
)


class DecomposerNoUpstreamTfTests(unittest.TestCase):
    def test_scaffold_remote_state_is_noop(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            group_dir = Path(tmp) / "groups" / "aws-app"
            group_dir.mkdir(parents=True)
            refs = [
                {
                    "from_address": "aws_subnet.a",
                    "to_address": "aws_vpc.hub",
                    "to_group": "aws-global-l1-foundation",
                    "to_layer": 1,
                }
            ]
            scaffold_remote_state(str(group_dir), "aws-app", refs)
            self.assertFalse((group_dir / "upstream.tf").exists())
            self.assertEqual(list(group_dir.iterdir()), [])

    def test_write_upstream_refs_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = {
                "aws-app": {
                    "upstream_refs": [
                        {
                            "from_address": "aws_subnet.a",
                            "to_address": "aws_vpc.hub",
                            "to_group": "aws-global-l1-foundation",
                            "to_layer": 1,
                        }
                    ]
                },
                "aws-lonely": {"upstream_refs": []},
            }
            out = write_upstream_refs_artifact(str(root), manifest)
            self.assertEqual(Path(out).name, "upstream_refs.json")
            payload = json.loads(Path(out).read_text(encoding="utf-8"))
            self.assertIn("aws-app", payload)
            self.assertNotIn("aws-lonely", payload)
            self.assertEqual(payload["aws-app"][0]["to_group"], "aws-global-l1-foundation")


if __name__ == "__main__":
    unittest.main()
