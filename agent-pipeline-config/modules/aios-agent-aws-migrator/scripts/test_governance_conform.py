#!/usr/bin/env python3
"""Unit tests for governance_conform.py (harness only — no Nile control catalog)."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import governance_conform as gc


class GovernanceConformTest(unittest.TestCase):
    def _gov_fixture(self, tmp: Path, extra: str = "") -> Path:
        root = tmp / "govsrc"
        (root / "governance").mkdir(parents=True)
        (root / "architecture").mkdir(parents=True)
        for rel in gc.REQUIRED_DOC_PATHS:
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"# {rel}\n{extra}\n", encoding="utf-8")
        (root / "architecture" / "nile-overview.md").write_text("# overview\n", encoding="utf-8")
        return root

    def test_inventory_lists_each_resource(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            groups = Path(tmp) / "azure" / "groups" / "g1"
            groups.mkdir(parents=True)
            (groups / "main.tf").write_text(
                "\n".join(
                    [
                        'resource "azurerm_storage_account" "data" {',
                        '  name = "stexample"',
                        "}",
                        'resource "azurerm_linux_virtual_machine" "app" {',
                        '  name = "vm"',
                        "}",
                    ]
                ),
                encoding="utf-8",
            )
            inv = gc.inventory_resources(Path(tmp) / "azure" / "groups", "azure")
            addresses = {r["address"] for r in inv["resources"]}
            self.assertEqual(
                addresses,
                {"azurerm_storage_account.data", "azurerm_linux_virtual_machine.app"},
            )
            cats = {r["address"]: r["suggested_category"] for r in inv["resources"]}
            self.assertEqual(cats["azurerm_storage_account.data"], "storage")
            self.assertEqual(cats["azurerm_linux_virtual_machine.app"], "compute")

    def test_refresh_fail_closed_when_docs_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            empty = Path(tmp) / "empty"
            empty.mkdir()
            with self.assertRaises(gc.GovernanceDocsUnavailable):
                gc.refresh_governance(Path(tmp) / "work", "https://example.invalid/gov.git", "main", source_dir=empty)

    def test_refresh_records_sha_and_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = self._gov_fixture(Path(tmp), extra="priority-1 tags")
            work = Path(tmp) / "work"
            work.mkdir()
            source = gc.refresh_governance(
                work,
                "https://github.com/Walmart-StackGen/Governance-and-Policy.git",
                "main",
                source_dir=src,
            )
            self.assertEqual(source["ref"], "main")
            self.assertIn("governance/priority-controls.md", source["paths_read"])
            self.assertTrue((work / "governance" / "governance" / "priority-controls.md").is_file())

    def test_scaffold_run_is_not_conformant(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp) / "work"
            groups = work / "azure" / "groups" / "g1"
            groups.mkdir(parents=True)
            (groups / "main.tf").write_text(
                'resource "azurerm_resource_group" "rg" { name = "rg" }\n',
                encoding="utf-8",
            )
            src = self._gov_fixture(Path(tmp))
            rc = gc.run(
                [
                    "--work-root",
                    str(work),
                    "--cloud",
                    "azure",
                    "--all",
                    "--governance-dir",
                    str(src),
                ]
            )
            self.assertEqual(rc, 1)
            report = json.loads((work / "azure" / "artifacts" / "governance-conformance-report.json").read_text())
            self.assertFalse(report["conformance_ok"])
            self.assertFalse(report["authored"])
            findings = json.loads((work / "azure" / "artifacts" / "governance-findings.json").read_text())
            codes = [f["control_id"] for f in findings["findings"]]
            self.assertIn("validator_not_authored", codes)

    def test_authored_validator_clears_when_no_blocking_findings(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp) / "work"
            groups = work / "azure" / "groups" / "g1"
            groups.mkdir(parents=True)
            (groups / "main.tf").write_text(
                'resource "azurerm_resource_group" "rg" { name = "rg" }\n',
                encoding="utf-8",
            )
            src = self._gov_fixture(Path(tmp))
            artifacts = work / "azure" / "artifacts"
            artifacts.mkdir(parents=True)
            (artifacts / "governance-validator.py").write_text(
                "\n".join(
                    [
                        "#!/usr/bin/env python3",
                        "import argparse, json, sys",
                        "from pathlib import Path",
                        "p = argparse.ArgumentParser(); p.add_argument('--work-root'); p.add_argument('--cloud')",
                        "args = p.parse_args()",
                        "out = Path(args.work_root) / args.cloud / 'artifacts' / 'governance-findings.json'",
                        "payload = {'authored': True, 'findings': [], 'resources': [{'address': 'azurerm_resource_group.rg', 'conformance_ok': True}]}",
                        "out.write_text(json.dumps(payload))",
                        "print(json.dumps(payload))",
                    ]
                ),
                encoding="utf-8",
            )
            rc = gc.run(
                [
                    "--work-root",
                    str(work),
                    "--cloud",
                    "azure",
                    "--all",
                    "--governance-dir",
                    str(src),
                ]
            )
            self.assertEqual(rc, 0)
            report = json.loads((artifacts / "governance-conformance-report.json").read_text())
            self.assertTrue(report["conformance_ok"])
            self.assertTrue(report["authored"])
            self.assertEqual(report["blocking_count"], 0)

    def test_refresh_unavailable_sets_blocked_exit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp) / "work"
            work.mkdir()
            rc = gc.run(
                [
                    "--work-root",
                    str(work),
                    "--cloud",
                    "gcp",
                    "--refresh",
                    "--governance-dir",
                    str(Path(tmp) / "missing"),
                ]
            )
            self.assertEqual(rc, 2)
            report = json.loads((work / "gcp" / "artifacts" / "governance-conformance-report.json").read_text())
            self.assertEqual(report["blocked"], "governance_docs_unavailable")
            self.assertFalse(report["conformance_ok"])

    def test_docs_change_is_visible_in_inventory_run_without_hardcoded_tags(self) -> None:
        """Harness must not bake tagging keys; only the refreshed file content changes."""
        with tempfile.TemporaryDirectory() as tmp:
            src = self._gov_fixture(Path(tmp), extra="required_tag: CostCenter")
            work = Path(tmp) / "work"
            work.mkdir()
            first = gc.refresh_governance(work, "repo", "main", source_dir=src)
            text1 = (work / "governance" / "governance" / "priority-controls.md").read_text()
            (src / "governance" / "priority-controls.md").write_text("# changed\nrequired_tag: Environment\n", encoding="utf-8")
            second = gc.refresh_governance(work, "repo", "main", source_dir=src)
            text2 = (work / "governance" / "governance" / "priority-controls.md").read_text()
            self.assertIn("CostCenter", text1)
            self.assertIn("Environment", text2)
            self.assertNotEqual(text1, text2)
            self.assertEqual(first["repo"], second["repo"])


if __name__ == "__main__":
    unittest.main()
