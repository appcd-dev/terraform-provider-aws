#!/usr/bin/env python3
"""Unit tests for destination_iac_harden.py."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from destination_iac_harden import harden_group


class DestinationIacHardenTest(unittest.TestCase):
    def test_inserts_tls_and_strips_password(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            group = Path(tmp) / "g1"
            group.mkdir()
            (group / "main.tf").write_text(
                '\n'.join(
                    [
                        'resource "azurerm_storage_account" "this" {',
                        '  name = "stexample"',
                        "}",
                        "",
                        'resource "azurerm_linux_virtual_machine" "vm" {',
                        '  admin_password = "Secret123!"',
                        "}",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            result = harden_group(group, "azure")
            text = (group / "main.tf").read_text(encoding="utf-8")
            self.assertIn('min_tls_version = "TLS1_2"', text)
            self.assertIn("plaintext_password_removed", " ".join(result["fixes"]))
            self.assertNotIn('admin_password = "Secret123!"', text)

    def test_flags_open_ingress_without_rewrite(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            group = Path(tmp) / "g2"
            group.mkdir()
            (group / "nsg.tf").write_text(
                '\n'.join(
                    [
                        'resource "azurerm_network_security_rule" "ssh" {',
                        '  destination_port_range = "22"',
                        '  source_address_prefix  = "0.0.0.0/0"',
                        "}",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            result = harden_group(group, "azure")
            codes = [f["code"] for f in result["findings"]]
            self.assertIn("open_management_ingress", codes)
            self.assertEqual(result["files_touched"], [])


if __name__ == "__main__":
    unittest.main()
