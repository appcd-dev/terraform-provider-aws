#!/usr/bin/env python3
"""Offline checks for acquisition app-IAM classification and inventory-first emit."""

from __future__ import annotations

import json
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import app_iam as aim  # noqa: E402


def check(name: str, cond: bool) -> None:
    if not cond:
        raise SystemExit(f"FAIL: {name}")
    print(f"OK: {name}")


def main() -> int:
    trust_ec2 = json.dumps(
        {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {"Service": "ec2.amazonaws.com"},
                    "Action": "sts:AssumeRole",
                }
            ],
        }
    )
    trust_user = json.dumps(
        {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {"AWS": "arn:aws:iam::123456789012:root"},
                    "Action": "sts:AssumeRole",
                }
            ],
        }
    )
    check("ec2 trust is workload", aim.is_workload_assume_policy(trust_ec2))
    check("account-root trust is not workload", not aim.is_workload_assume_policy(trust_user))
    check("service-linked name", aim.is_service_linked_role("AWSServiceRoleForECS"))
    check("customer role name", not aim.is_service_linked_role("my-app-exec-role"))

    state = {
        "resources": [
            {
                "mode": "managed",
                "type": "aws_iam_role",
                "name": "app",
                "instances": [
                    {
                        "attributes": {
                            "name": "my-app-exec-role",
                            "id": "my-app-exec-role",
                            "arn": "arn:aws:iam::123:role/my-app-exec-role",
                            "assume_role_policy": trust_ec2,
                        }
                    }
                ],
            },
            {
                "mode": "managed",
                "type": "aws_iam_role",
                "name": "slr",
                "instances": [
                    {
                        "attributes": {
                            "name": "AWSServiceRoleForECS",
                            "id": "AWSServiceRoleForECS",
                            "assume_role_policy": trust_ec2,
                        }
                    }
                ],
            },
            {
                "mode": "managed",
                "type": "aws_iam_role_policy",
                "name": "inline",
                "instances": [
                    {
                        "attributes": {
                            "role": "my-app-exec-role",
                            "name": "custom",
                            "policy": json.dumps(
                                {
                                    "Version": "2012-10-17",
                                    "Statement": [
                                        {
                                            "Effect": "Allow",
                                            "Action": ["s3:GetObject", "dynamodb:Query"],
                                            "Resource": "*",
                                        }
                                    ],
                                }
                            ),
                        }
                    }
                ],
            },
        ]
    }
    roles = aim.extract_workload_roles_from_state(state)
    check("one workload role extracted", len(roles) == 1)
    check("role name preserved", roles[0]["name"] == "my-app-exec-role")
    check("custom actions captured", "s3:GetObject" in roles[0]["aws_actions"])
    check("dynamodb action captured", "dynamodb:Query" in roles[0]["aws_actions"])

    inv = aim.build_app_iam_inventory(roles, "app-group", cloud="gcp")
    check("inventory schema", inv["schema"] == "nile-app-iam-inventory/v1")
    check("inventory has actions", "s3:GetObject" in inv["workload_roles"][0]["aws_actions"])
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "app-iam-inventory.json"
        aim.write_app_iam_inventory(path, inv)
        check("inventory written", path.is_file())

    hcl = "\n".join(aim.build_gcp_app_iam_hcl(roles, "app-group", "abc12345"))
    check("emits service account", 'resource "google_service_account"' in hcl)
    check("no placeholder custom role", 'resource "google_project_iam_custom_role"' not in hcl)
    check("no placeholder iam member", 'resource "google_project_iam_member"' not in hcl)
    check("points at inventory", "app-iam-inventory.json" in hcl)
    ids = re.findall(r'account_id\s*=\s*"([^"]+)"', hcl)
    check("emits account_id", bool(ids))
    for aid in ids:
        check(
            f"account_id matches gcp regexp ({aid})",
            bool(re.fullmatch(r"^[a-z](?:[-a-z0-9]{4,28}[a-z0-9])$", aid)),
        )

    used_roles = [
        {
            "name": f"terraform_2025111206320932800000000{i}",
            "arn": f"arn:aws:iam::1:role/r{i}",
            "id": f"r{i}",
            "aws_actions": [],
            "policy_names": [],
        }
        for i in range(5)
    ]
    dense = "\n".join(aim.build_gcp_app_iam_hcl(used_roles, "iam-dense", "f6c3b0ae"))
    dense_ids = re.findall(r'account_id\s*=\s*"([^"]+)"', dense)
    check("dense account ids unique", len(dense_ids) == len(set(dense_ids)))
    for aid in dense_ids:
        check(
            f"dense account_id valid ({aid})",
            bool(re.fullmatch(r"^[a-z](?:[-a-z0-9]{4,28}[a-z0-9])$", aid)),
        )

    empty = "\n".join(aim.build_gcp_app_iam_hcl([], "empty", "zzz"))
    check("empty fallback still scaffolds SA", 'google_service_account" "workload"' in empty)
    check("empty has no custom role", 'resource "google_project_iam_custom_role"' not in empty)

    az = "\n".join(aim.build_azure_app_iam_hcl(roles, "app-group", "abc12345"))
    check("azure emits uai", 'resource "azurerm_user_assigned_identity"' in az)
    check("azure no role definition", 'resource "azurerm_role_definition"' not in az)
    check("azure no role assignment", 'resource "azurerm_role_assignment"' not in az)
    check("azure points at inventory", "app-iam-inventory.json" in az)
    az_empty = "\n".join(aim.build_azure_app_iam_hcl([], "empty", "zzz"))
    check("azure empty fallback UAI", 'azurerm_user_assigned_identity" "workload"' in az_empty)

    print("OK: app_iam acquisition helpers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
