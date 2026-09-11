#!/usr/bin/env python3
"""Unit tests for hcl_sanity.py gates."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from hcl_sanity import (
    apply_surgical_fixes,
    check_destination_resources,
    check_source_parity,
    emit_from_state,
    import_addresses,
    parse_tofu_errors,
    resource_addresses,
)


class HclSanityTests(unittest.TestCase):
    def test_import_and_resource_parsers(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "imports.tf").write_text(
                'import {\n  to = aws_eip.nat\n  id = "eipalloc-1"\n}\n'
                'import {\n  to = aws_subnet.public\n  id = "subnet-1"\n}\n',
                encoding="utf-8",
            )
            (root / "generated.tf").write_text(
                'resource "aws_eip" "nat" {\n  domain = "vpc"\n}\n'
                'resource "aws_subnet" "public" {\n  cidr_block = "10.0.0.0/24"\n}\n',
                encoding="utf-8",
            )
            self.assertEqual(
                import_addresses(root / "imports.tf"),
                {"aws_eip.nat", "aws_subnet.public"},
            )
            self.assertEqual(
                resource_addresses(root),
                {"aws_eip.nat", "aws_subnet.public"},
            )
            self.assertEqual(check_source_parity(root), 0)

    def test_source_parity_fails_when_generated_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "imports.tf").write_text(
                'import {\n  to = aws_eip.nat\n  id = "eipalloc-1"\n}\n'
                'import {\n  to = aws_subnet.public\n  id = "subnet-1"\n}\n',
                encoding="utf-8",
            )
            (root / "generated.tf").write_text(
                'resource "aws_eip" "nat" {\n  domain = "vpc"\n}\n',
                encoding="utf-8",
            )
            self.assertEqual(check_source_parity(root), 1)

    def test_source_parity_fails_when_generated_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "imports.tf").write_text(
                'import {\n  to = aws_eip.nat\n  id = "eipalloc-1"\n}\n',
                encoding="utf-8",
            )
            self.assertEqual(check_source_parity(root), 1)

    def test_destination_requires_resources(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "main.tf").write_text(
                'terraform {\n  required_version = ">= 1.5"\n}\n',
                encoding="utf-8",
            )
            self.assertEqual(check_destination_resources(root), 1)
            (root / "main.tf").write_text(
                'resource "azurerm_resource_group" "rg" {\n  name = "rg"\n  location = "eastus"\n}\n',
                encoding="utf-8",
            )
            self.assertEqual(check_destination_resources(root), 0)

    def test_emit_from_state_writes_missing_resources(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "imports.tf").write_text(
                'import {\n  to = aws_eip.nat\n  id = "eipalloc-1"\n}\n',
                encoding="utf-8",
            )
            state = {
                "resources": [
                    {
                        "mode": "managed",
                        "type": "aws_eip",
                        "name": "nat",
                        "instances": [
                            {
                                "attributes": {
                                    "id": "eipalloc-1",
                                    "domain": "vpc",
                                    "tags": {"Name": "nat"},
                                    "name_prefix": "x",
                                    "name": "nat-eip",
                                }
                            }
                        ],
                    }
                ]
            }
            (root / "terraform.tfstate").write_text(
                __import__("json").dumps(state), encoding="utf-8"
            )
            self.assertEqual(emit_from_state(root), 0)
            text = (root / "generated.tf").read_text(encoding="utf-8")
            self.assertIn('resource "aws_eip" "nat"', text)
            self.assertIn('domain = "vpc"', text)
            self.assertNotIn("name_prefix", text)
            self.assertEqual(check_source_parity(root), 0)

    def test_emit_route_table_as_blocks(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "imports.tf").write_text(
                'import {\n  to = aws_route_table.rtb\n  id = "rtb-1"\n}\n',
                encoding="utf-8",
            )
            state = {
                "resources": [
                    {
                        "mode": "managed",
                        "type": "aws_route_table",
                        "name": "rtb",
                        "instances": [
                            {
                                "attributes": {
                                    "id": "rtb-1",
                                    "vpc_id": "vpc-1",
                                    "route": [
                                        {
                                            "cidr_block": "0.0.0.0/0",
                                            "gateway_id": "igw-1",
                                            "nat_gateway_id": "",
                                            "vpc_peering_connection_id": "",
                                        },
                                        {
                                            "cidr_block": "10.1.0.0/16",
                                            "gateway_id": "",
                                            "vpc_peering_connection_id": "pcx-1",
                                        },
                                    ],
                                }
                            }
                        ],
                    }
                ]
            }
            (root / "terraform.tfstate").write_text(
                __import__("json").dumps(state), encoding="utf-8"
            )
            self.assertEqual(emit_from_state(root), 0)
            text = (root / "generated.tf").read_text(encoding="utf-8")
            self.assertIn("route {", text)
            self.assertNotIn("route = [", text)
            self.assertIn('cidr_block = "0.0.0.0/0"', text)
            self.assertIn('gateway_id = "igw-1"', text)
            self.assertIn('vpc_peering_connection_id = "pcx-1"', text)
            self.assertNotIn('nat_gateway_id = ""', text)

    def test_emit_api_gateway_resource_required_attrs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "imports.tf").write_text(
                'import {\n  to = aws_api_gateway_resource.r\n  id = "api/res"\n}\n',
                encoding="utf-8",
            )
            state = {
                "resources": [
                    {
                        "mode": "managed",
                        "type": "aws_api_gateway_resource",
                        "name": "r",
                        "instances": [
                            {
                                "attributes": {
                                    "id": "res",
                                    "path": "/",
                                    "path_part": "/",
                                    "parent_id": "parent",
                                    "rest_api_id": "api",
                                }
                            }
                        ],
                    }
                ]
            }
            (root / "terraform.tfstate").write_text(
                __import__("json").dumps(state), encoding="utf-8"
            )
            self.assertEqual(emit_from_state(root), 0)
            text = (root / "generated.tf").read_text(encoding="utf-8")
            self.assertIn('parent_id = "parent"', text)
            self.assertIn('path_part = "/"', text)
            self.assertIn('rest_api_id = "api"', text)
            self.assertNotIn("path =", text)

    def test_parse_and_apply_surgical_fixes(self) -> None:
        log = (
            "Error: Unsupported argument\n\n"
            '  with aws_vpc.appcd_vpc_developer,\n'
            "  on generated.tf line 100, in resource \"aws_vpc\" \"appcd_vpc_developer\":\n"
            " 100:   ipv6_ipam_pool_id                    = \"\"\n\n"
            'An argument named "ipv6_ipam_pool_id" is not expected here.\n\n'
            "Error: Conflicting configuration arguments\n\n"
            '  with aws_vpc.appcd_vpc_developer,\n'
            "  on generated.tf line 90:\n\n"
            '"assign_generated_ipv6_cidr_block": conflicts with ipv6_ipam_pool_id\n'
        )
        targets = parse_tofu_errors(log, group_id="g1")
        self.assertGreaterEqual(len(targets), 1)
        self.assertTrue(any(t.get("address") == "aws_vpc.appcd_vpc_developer" for t in targets))
        self.assertTrue(
            any(t.get("suggestion", "").startswith("drop_") for t in targets)
        )

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "generated.tf").write_text(
                'resource "aws_vpc" "appcd_vpc_developer" {\n'
                '  cidr_block = "10.0.0.0/16"\n'
                '  ipv6_ipam_pool_id = ""\n'
                '  assign_generated_ipv6_cidr_block = false\n'
                "}\n",
                encoding="utf-8",
            )
            removed = apply_surgical_fixes(root, targets)
            self.assertGreaterEqual(removed, 1)
            text = (root / "generated.tf").read_text(encoding="utf-8")
            self.assertNotIn("ipv6_ipam_pool_id", text)
            self.assertIn("cidr_block", text)


if __name__ == "__main__":
    unittest.main()
