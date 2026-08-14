"""Application IAM helpers for acquisition-style AWS → destination migration.

Acquisition specialists care about **workload** identities (EC2/Lambda/ECS/EKS/… trust)
and their **custom permission surfaces** — not workforce users/groups/federation.

This module:
- Classifies IAM roles as workload vs human/service-linked noise
- Extracts inline/customer-managed policy statements from group tfstate
- Builds review-candidate GCP HCL (service account + custom role + binding)
- Builds review-candidate Azure HCL (UAI + role definition + assignment)

Without this, scans that exclude all IAM drop the permission map that apps need on
the destination cloud, and generate only empty identity stubs.
"""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any

# Trust principals that mean "this role runs an application/service", not a human.
WORKLOAD_TRUST_SERVICES = (
    "ec2.amazonaws.com",
    "lambda.amazonaws.com",
    "ecs-tasks.amazonaws.com",
    "ecs.amazonaws.com",
    "eks.amazonaws.com",
    "pods.eks.amazonaws.com",
    "rds.amazonaws.com",
    "states.amazonaws.com",
    "apigateway.amazonaws.com",
    "firehose.amazonaws.com",
    "sns.amazonaws.com",
    "sqs.amazonaws.com",
    "edgelambda.amazonaws.com",
    "codebuild.amazonaws.com",
    "codepipeline.amazonaws.com",
    "autoscaling.amazonaws.com",
    "application-autoscaling.amazonaws.com",
    "elasticloadbalancing.amazonaws.com",
    "elasticbeanstalk.amazonaws.com",
    "ecs.application-autoscaling.amazonaws.com",
    "scheduler.amazonaws.com",
    "events.amazonaws.com",
    "batch.amazonaws.com",
    "glue.amazonaws.com",
    "sagemaker.amazonaws.com",
    "airflow.amazonaws.com",
    "eks-fargate-pods.amazonaws.com",
    "vpc-flow-logs.amazonaws.com",
    "monitoring.amazonaws.com",
    "ops.apigateway.amazonaws.com",
    "ssm.amazonaws.com",
    "ci.amazonaws.com",
)

# Placeholder least-privilege GCP permissions — operators replace after action translation.
GCP_PLACEHOLDER_PERMISSIONS = (
    "iam.roles.get",
    "resourcemanager.projects.get",
)

# Placeholder Azure RBAC actions — operators replace after IAM→RBAC translation.
AZURE_PLACEHOLDER_ACTIONS = (
    "Microsoft.Resources/subscriptions/resourceGroups/read",
)


def _parse_jsonish(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, (dict, list)):
        return value
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return None
    return None


def _collect_principals(node: Any, out: set[str]) -> None:
    if isinstance(node, dict):
        for key, val in node.items():
            if key in ("Service", "AWS", "Federated") and isinstance(val, str):
                out.add(val)
            elif key in ("Service", "AWS", "Federated") and isinstance(val, list):
                for item in val:
                    if isinstance(item, str):
                        out.add(item)
            else:
                _collect_principals(val, out)
    elif isinstance(node, list):
        for item in node:
            _collect_principals(item, out)


def is_service_linked_role(name: str) -> bool:
    """Return True for AWS service-linked roles that should not be migrated as-is."""
    n = (name or "").strip()
    return n.startswith("AWSServiceRoleFor") or "/aws-service-role/" in n


def is_workload_assume_policy(assume_role_policy: Any) -> bool:
    """True when trust policy includes an AWS service principal used by app runtimes."""
    doc = _parse_jsonish(assume_role_policy)
    if not isinstance(doc, dict):
        return False
    principals: set[str] = set()
    _collect_principals(doc, principals)
    for principal in principals:
        p = principal.strip().lower()
        for svc in WORKLOAD_TRUST_SERVICES:
            if p == svc or p.endswith("." + svc) or svc in p:
                return True
    return False


def _statements_from_policy_doc(doc: Any) -> list[dict]:
    parsed = _parse_jsonish(doc)
    if not isinstance(parsed, dict):
        return []
    stmts = parsed.get("Statement")
    if isinstance(stmts, dict):
        return [stmts]
    if isinstance(stmts, list):
        return [s for s in stmts if isinstance(s, dict)]
    return []


def _flatten_actions(statements: list[dict]) -> list[str]:
    actions: list[str] = []
    for stmt in statements:
        act = stmt.get("Action")
        if isinstance(act, str):
            actions.append(act)
        elif isinstance(act, list):
            actions.extend(str(a) for a in act)
    # Stable, de-duped, capped for HCL comment size.
    uniq = sorted({a for a in actions if a})
    return uniq[:80]


def _hcl_string(value: str) -> str:
    return json.dumps(str(value))


def _safe_tf_name(value: str, max_len: int = 40) -> str:
    value = re.sub(r"[^a-z0-9_]+", "_", (value or "role").lower()).strip("_")
    return (value[:max_len].strip("_") or "role")


def _gcp_sa_account_id(stable: str, label: str, used: set[str], idx: int = 0) -> str:
    """Build a unique google_service_account.account_id that passes provider validation.

    Provider regexp: ^[a-z](?:[-a-z0-9]{4,28}[a-z0-9])$ (length 6–30). Underscores and
    truncated collisions previously failed tofu validate on dense IAM groups.
    """
    slug = re.sub(r"[^a-z0-9]+", "-", f"{stable}-{label}".lower())
    slug = re.sub(r"-{2,}", "-", slug).strip("-") or f"role{idx}"
    candidate = f"sa-{slug}"
    candidate = re.sub(r"-{2,}", "-", candidate).strip("-")
    if not candidate[0].isalpha():
        candidate = f"sa-{candidate}"

    def _fit(value: str) -> str:
        value = value[:30].rstrip("-")
        if len(value) < 6:
            value = (value + "xxxxxx")[:6]
        if value[-1] == "-":
            value = value[:-1] + "0"
        if not re.fullmatch(r"^[a-z](?:[-a-z0-9]{4,28}[a-z0-9])$", value):
            digest = hashlib.sha1(f"{stable}:{label}:{idx}".encode()).hexdigest()[:10]
            value = f"sa{digest}"[:30]
        return value

    out = _fit(candidate)
    n = 0
    while out in used:
        n += 1
        stem = candidate[: max(6, 30 - 4)].rstrip("-")
        out = _fit(f"{stem}-{n:02d}")
    used.add(out)
    return out


def extract_workload_roles_from_state(state: dict) -> list[dict]:
    """Extract customer-managed workload roles + custom policy statements from a tfstate.

    Returns a list of dicts:
      name, id, trust_services_hint, aws_actions, policy_names, source_addresses
    """
    if not isinstance(state, dict):
        return []

    roles: dict[str, dict] = {}
    policies_by_id: dict[str, dict] = {}
    inline_by_role: dict[str, list[dict]] = {}

    for resource in state.get("resources") or []:
        if resource.get("mode") != "managed":
            continue
        rtype = str(resource.get("type") or "")
        for inst in resource.get("instances") or []:
            attrs = (inst.get("attributes") or {}) if isinstance(inst, dict) else {}
            addr = f"{rtype}.{resource.get('name')}"
            if rtype == "aws_iam_role":
                name = str(attrs.get("name") or attrs.get("id") or resource.get("name") or "")
                if is_service_linked_role(name) or is_service_linked_role(str(attrs.get("path") or "")):
                    continue
                if not is_workload_assume_policy(attrs.get("assume_role_policy")):
                    continue
                roles[name] = {
                    "name": name,
                    "id": str(attrs.get("id") or name),
                    "arn": str(attrs.get("arn") or ""),
                    "assume_role_policy": attrs.get("assume_role_policy"),
                    "aws_actions": [],
                    "policy_names": [],
                    "source_addresses": [addr],
                }
            elif rtype == "aws_iam_policy":
                pid = str(attrs.get("id") or attrs.get("arn") or attrs.get("name") or "")
                policies_by_id[pid] = {
                    "name": str(attrs.get("name") or pid),
                    "arn": str(attrs.get("arn") or ""),
                    "policy": attrs.get("policy"),
                    "address": addr,
                }
            elif rtype == "aws_iam_role_policy":
                role_name = str(attrs.get("role") or "")
                inline_by_role.setdefault(role_name, []).append(
                    {
                        "name": str(attrs.get("name") or "inline"),
                        "policy": attrs.get("policy"),
                        "address": addr,
                    }
                )

    # Attachments: record managed policy names for review (glue, not separate emit).
    for resource in state.get("resources") or []:
        if resource.get("type") != "aws_iam_role_policy_attachment":
            continue
        for inst in resource.get("instances") or []:
            attrs = (inst.get("attributes") or {}) if isinstance(inst, dict) else {}
            role_name = str(attrs.get("role") or "")
            if role_name not in roles:
                continue
            pol_arn = str(attrs.get("policy_arn") or "")
            roles[role_name]["policy_names"].append(pol_arn or "attached-policy")
            # If the customer-managed policy is in this group state, fold its actions.
            for pid, pol in policies_by_id.items():
                if pol_arn and (pol_arn == pol.get("arn") or pol_arn.endswith("/" + pol.get("name", ""))):
                    actions = _flatten_actions(_statements_from_policy_doc(pol.get("policy")))
                    roles[role_name]["aws_actions"].extend(actions)
                    roles[role_name]["policy_names"].append(pol.get("name") or pid)
                    roles[role_name]["source_addresses"].append(pol.get("address") or "")

    for role_name, inlines in inline_by_role.items():
        if role_name not in roles:
            # Inline policy may reference role id; try match by id.
            matched = None
            for r in roles.values():
                if r["id"] == role_name or r["name"] == role_name:
                    matched = r["name"]
                    break
            if not matched:
                continue
            role_name = matched
        for inline in inlines:
            actions = _flatten_actions(_statements_from_policy_doc(inline.get("policy")))
            roles[role_name]["aws_actions"].extend(actions)
            roles[role_name]["policy_names"].append(inline.get("name") or "inline")
            roles[role_name]["source_addresses"].append(inline.get("address") or "")

    out = []
    for role in sorted(roles.values(), key=lambda r: r["name"]):
        role["aws_actions"] = sorted({a for a in role["aws_actions"] if a})[:80]
        role["policy_names"] = sorted({p for p in role["policy_names"] if p})[:40]
        role["source_addresses"] = sorted({a for a in role["source_addresses"] if a})
        out.append(role)
    return out


def build_gcp_app_iam_hcl(roles: list[dict], group_id: str, stable: str) -> list[str]:
    """Emit review-candidate SA + custom role + project IAM member per workload role.

    AWS actions are preserved as comments for the acquisition review pack; GCP
    permissions stay placeholders until an IAM specialist translates them.
    """
    lines: list[str] = [
        "# Emission=managed_identity_rbac_scaffold: acquisition app-IAM capture.",
        "# Each AWS workload role → google_service_account + google_project_iam_custom_role",
        "# + google_project_iam_member. Translate AWS actions to GCP permissions before apply.",
        "",
    ]
    if not roles:
        used: set[str] = set()
        sa_id = _gcp_sa_account_id(stable, "workload", used, 0)
        role_id = f"mig{stable.replace('-', '')[:16]}"
        lines.extend(
            [
                "# No workload aws_iam_role instances in this group state — baseline SA + custom role scaffold.",
                'resource "google_service_account" "workload" {',
                f"  account_id   = {_hcl_string(sa_id)}",
                f'  display_name = "migration-{group_id}"',
                "}",
                "",
                'resource "google_project_iam_custom_role" "workload" {',
                f"  role_id     = {_hcl_string(role_id)}",
                f'  title       = "migration-{group_id}"',
                '  description = "Review-candidate custom role; replace permissions with translated AWS IAM actions."',
                "  permissions = [",
                *[f'    "{p}",' for p in GCP_PLACEHOLDER_PERMISSIONS],
                "  ]",
                "}",
                "",
                'resource "google_project_iam_member" "workload" {',
                "  project = var.project_id",
                '  role    = "projects/${var.project_id}/roles/${google_project_iam_custom_role.workload.role_id}"',
                '  member  = "serviceAccount:${google_service_account.workload.email}"',
                "}",
                "",
            ]
        )
        return lines

    used_account_ids: set[str] = set()
    for idx, role in enumerate(roles):
        suffix = _safe_tf_name(role.get("name") or f"role{idx}")
        res = "workload" if idx == 0 and len(roles) == 1 else f"app_{suffix}"[:50]
        sa_id = _gcp_sa_account_id(stable[:8], suffix, used_account_ids, idx)
        role_id = re.sub(r"[^a-zA-Z0-9_.]", "", f"mig{stable[:6]}{suffix}")[:64] or f"mig{idx}"
        actions = role.get("aws_actions") or []
        pol_names = role.get("policy_names") or []
        lines.append(f"# AWS role: {role.get('name')} ({role.get('arn') or role.get('id')})")
        if pol_names:
            lines.append(f"# Source policies: {', '.join(pol_names[:12])}")
        if actions:
            lines.append("# AWS actions to translate (sample):")
            for act in actions[:40]:
                lines.append(f"#   - {act}")
        else:
            lines.append(
                "# No inline/customer policy statements found in this group state — "
                "confirm managed-policy attachments in review-needed.md."
            )
        role_name = str(role.get("name") or res)
        lines.extend(
            [
                f'resource "google_service_account" "{res}" {{',
                f"  account_id   = {_hcl_string(sa_id)}",
                f"  display_name = {_hcl_string('aws:' + role_name)}",
                f"  description  = {_hcl_string('Migrated from AWS IAM role ' + role_name)}",
                "}",
                "",
                f'resource "google_project_iam_custom_role" "{res}" {{',
                f"  role_id     = {_hcl_string(role_id)}",
                f"  title       = {_hcl_string('aws-' + role_name[:60])}",
                '  description = "Acquisition review-candidate; translate AWS IAM actions before apply."',
                "  permissions = [",
                *[f'    "{p}",' for p in GCP_PLACEHOLDER_PERMISSIONS],
                "  ]",
                "}",
                "",
                f'resource "google_project_iam_member" "{res}" {{',
                "  project = var.project_id",
                f'  role    = "projects/${{var.project_id}}/roles/${{google_project_iam_custom_role.{res}.role_id}}"',
                f'  member  = "serviceAccount:${{google_service_account.{res}.email}}"',
                "}",
                "",
            ]
        )
    return lines


def build_azure_app_iam_hcl(roles: list[dict], group_id: str, stable: str) -> list[str]:
    """Emit review-candidate UAI + custom role definition + assignment per workload role.

    AWS actions are preserved as comments for the acquisition review pack; Azure
    RBAC actions stay placeholders until an IAM specialist translates them.
    """
    lines: list[str] = [
        "# Emission=managed_identity_rbac_scaffold: acquisition app-IAM capture.",
        "# Each AWS workload role → azurerm_user_assigned_identity + azurerm_role_definition",
        "# + azurerm_role_assignment. Translate AWS actions to Azure RBAC before apply.",
        "",
    ]
    if not roles:
        lines.extend(
            [
                "# No workload aws_iam_role instances in this group state — baseline UAI + custom role scaffold.",
                'resource "azurerm_user_assigned_identity" "workload" {',
                f'  name                = "id-{group_id[:56]}"',
                "  location            = azurerm_resource_group.this.location",
                "  resource_group_name = azurerm_resource_group.this.name",
                "  tags                = var.tags",
                "}",
                "",
                'resource "azurerm_role_definition" "workload" {',
                f'  name        = "role-{group_id[:50]}"',
                "  scope       = azurerm_resource_group.this.id",
                '  description = "Review-candidate custom role; replace permissions with translated AWS IAM actions."',
                "",
                "  permissions {",
                "    actions     = [",
                *[f'      "{a}",' for a in AZURE_PLACEHOLDER_ACTIONS],
                "    ]",
                "    not_actions = []",
                "  }",
                "",
                "  assignable_scopes = [",
                "    azurerm_resource_group.this.id,",
                "  ]",
                "}",
                "",
                'resource "azurerm_role_assignment" "workload" {',
                "  scope              = azurerm_resource_group.this.id",
                "  role_definition_id = azurerm_role_definition.workload.role_definition_resource_id",
                "  principal_id       = azurerm_user_assigned_identity.workload.principal_id",
                "}",
                "",
            ]
        )
        return lines

    for idx, role in enumerate(roles):
        suffix = _safe_tf_name(role.get("name") or f"role{idx}")
        res = "workload" if idx == 0 and len(roles) == 1 else f"app_{suffix}"[:50]
        id_name = f"id-{stable[:8]}-{suffix}"[:64].rstrip("-_")
        role_name_hcl = f"role-{stable[:6]}-{suffix}"[:64].rstrip("-_")
        actions = role.get("aws_actions") or []
        pol_names = role.get("policy_names") or []
        lines.append(f"# AWS role: {role.get('name')} ({role.get('arn') or role.get('id')})")
        if pol_names:
            lines.append(f"# Source policies: {', '.join(pol_names[:12])}")
        if actions:
            lines.append("# AWS actions to translate (sample):")
            for act in actions[:40]:
                lines.append(f"#   - {act}")
        else:
            lines.append(
                "# No inline/customer policy statements found in this group state — "
                "confirm managed-policy attachments in review-needed.md."
            )
        lines.extend(
            [
                f'resource "azurerm_user_assigned_identity" "{res}" {{',
                f"  name                = {_hcl_string(id_name)}",
                "  location            = azurerm_resource_group.this.location",
                "  resource_group_name = azurerm_resource_group.this.name",
                "  tags                = var.tags",
                "}",
                "",
                f'resource "azurerm_role_definition" "{res}" {{',
                f"  name        = {_hcl_string(role_name_hcl)}",
                "  scope       = azurerm_resource_group.this.id",
                '  description = "Acquisition review-candidate; translate AWS IAM actions before apply."',
                "",
                "  permissions {",
                "    actions     = [",
                *[f'      "{a}",' for a in AZURE_PLACEHOLDER_ACTIONS],
                "    ]",
                "    not_actions = []",
                "  }",
                "",
                "  assignable_scopes = [",
                "    azurerm_resource_group.this.id,",
                "  ]",
                "}",
                "",
                f'resource "azurerm_role_assignment" "{res}" {{',
                "  scope              = azurerm_resource_group.this.id",
                f"  role_definition_id = azurerm_role_definition.{res}.role_definition_resource_id",
                f"  principal_id       = azurerm_user_assigned_identity.{res}.principal_id",
                "}",
                "",
            ]
        )
    return lines
