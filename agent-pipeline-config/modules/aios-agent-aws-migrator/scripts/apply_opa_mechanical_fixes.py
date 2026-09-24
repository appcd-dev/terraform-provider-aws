#!/usr/bin/env python3
"""Apply mechanical OPA remediations to destination group HCL.

Reads governance-opa-remediations.json (or derives from findings), patches
labels/tags/TLS attrs and variable defaults, and records migration assumptions
when source values are missing.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Keep in sync with gcp_iac_generate.REQUIRED_GCP_LABELS (TAG-002 / TAG-003 safe).
REQUIRED_GCP_LABELS = {
    "owner": "platformengineering",
    "created_by": "stackgen-aws-migrator",
    "cost_center": "cc-migration",
    "environment": "dev",
    "function": "migration",
    "service": "nile",
    "repo": "walmart-stackgen-nile-factory",
    "application_name": "projectnile",
    "notification_distlist": "nile-ops",
    "ssp": "ssp-migration",
    "tr_product_id": "tr-migration",
    "apm_id": "apm-migration",
    "name": "nile-migration",
}

REQUIRED_AZURE_TAGS = {
    "owner": "platformengineering",
    "created-by": "stackgen-aws-migrator",
    "cost-center": "cc-migration",
    "environment": "dev",
    "function": "migration",
    "service": "nile",
    "repo": "walmart-stackgen-nile-factory",
    "applicationname": "projectnile",
    "name": "nile-migration",
    "notificationdistlist": "nile-ops",
    "ssp": "ssp-migration",
    "trproductid": "tr-migration",
    "apmid": "apm-migration",
}

# TLS / private-by-default attrs harden already covers; still apply when OPA names them.
TLS_ATTR_DEFAULTS = {
    "enable_https_traffic_only": "true",
    "min_tls_version": '"TLS1_2"',
    "https_only": "true",
    "uniform_bucket_level_access": "true",
    "public_network_access_enabled": "false",
    "can_ip_forward": "false",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path: Path) -> Any:
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def aws_tag_map(work_root: Path) -> dict[str, str]:
    """Best-effort map of Nile label keys from AWS inventory / blueprint tags."""
    out: dict[str, str] = {}
    candidates = [
        work_root / "aws" / "artifacts" / "inventory.json",
        work_root / "gcp" / "artifacts" / "migration-blueprint.json",
        work_root / "azure" / "artifacts" / "migration-blueprint.json",
    ]
    key_aliases = {
        "apm_id": ("apm_id", "apmid", "APM_ID", "ApmId"),
        "apmid": ("apmid", "apm_id", "APM_ID"),
        "cost_center": ("cost_center", "cost-center", "CostCenter"),
        "cost-center": ("cost-center", "cost_center", "CostCenter"),
        "owner": ("owner", "Owner", "OWNER"),
        "environment": ("environment", "Environment", "env"),
        "application_name": ("application_name", "applicationname", "Application"),
        "applicationname": ("applicationname", "application_name"),
        "service": ("service", "Service"),
        "repo": ("repo", "repository", "Repo"),
    }
    raw_tags: dict[str, str] = {}

    def harvest(obj: Any) -> None:
        if isinstance(obj, dict):
            tags = obj.get("tags") or obj.get("labels") or {}
            if isinstance(tags, dict):
                for k, v in tags.items():
                    if isinstance(v, (str, int)) and str(v).strip():
                        raw_tags[str(k)] = str(v).strip()
            for v in obj.values():
                harvest(v)
        elif isinstance(obj, list):
            for item in obj[:200]:
                harvest(item)

    for path in candidates:
        payload = load_json(path)
        if payload is not None:
            harvest(payload)

    for target, aliases in key_aliases.items():
        for alias in aliases:
            if alias in raw_tags:
                out[target] = re.sub(r"[^a-z0-9_-]", "-", raw_tags[alias].lower())[:63]
                break
    return out


def ensure_assumptions_md(path: Path) -> None:
    if path.is_file():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "# Migration assumptions\n\n"
        "Documented by pack mechanical fixes and the governance agent when source "
        "AWS metadata lacks a Nile-required key. Replace before production apply.\n\n"
        "| When | Cloud | Key | Value | Reason |\n"
        "| --- | --- | --- | --- | --- |\n",
        encoding="utf-8",
    )


def append_assumption(
    path: Path,
    *,
    cloud: str,
    key: str,
    value: str,
    reason: str,
) -> None:
    ensure_assumptions_md(path)
    line = f"| {utc_now()} | `{cloud}` | `{key}` | `{value}` | {reason} |\n"
    with path.open("a", encoding="utf-8") as fh:
        fh.write(line)


def resolve_label_value(
    key: str,
    *,
    cloud: str,
    aws_tags: dict[str, str],
    assumptions_path: Path,
) -> tuple[str, bool]:
    defaults = REQUIRED_GCP_LABELS if cloud == "gcp" else REQUIRED_AZURE_TAGS
    if key in aws_tags and aws_tags[key]:
        return aws_tags[key], False
    # Cross-alias for apm
    if key in ("apm_id", "apmid"):
        for alt in ("apm_id", "apmid"):
            if alt in aws_tags and aws_tags[alt]:
                return aws_tags[alt], False
    value = defaults.get(key, f"migration-{key.replace('_', '-')}")
    append_assumption(
        assumptions_path,
        cloud=cloud,
        key=key,
        value=value,
        reason="Source AWS tags lacked this Nile key; migration placeholder applied",
    )
    return value, True


def _matching_brace_span(text: str, open_idx: int) -> tuple[int, int] | None:
    """Return (open, close) indices for `{...}` starting at open_idx."""
    if open_idx < 0 or open_idx >= len(text) or text[open_idx] != "{":
        return None
    depth = 0
    in_str = False
    str_ch = ""
    i = open_idx
    while i < len(text):
        ch = text[i]
        if in_str:
            if ch == "\\" and i + 1 < len(text):
                i += 2
                continue
            if ch == str_ch:
                in_str = False
            i += 1
            continue
        if ch in ('"', "'"):
            in_str = True
            str_ch = ch
            i += 1
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return open_idx, i
        i += 1
    return None


def patch_labels_default_map(text: str, updates: dict[str, str]) -> tuple[str, int]:
    """Merge keys into variable \"labels\" / \"tags\" default = { ... } blocks.

    Handles both multiline and single-line map defaults. Uses brace matching so
    keys are never appended after a same-line closing `}`.
    """
    if not updates:
        return text, 0
    var_re = re.compile(r'variable\s+"(?:labels|tags)"\s*\{', re.M)
    match = var_re.search(text)
    if not match:
        return text, 0
    var_span = _matching_brace_span(text, match.end() - 1)
    if var_span is None:
        return text, 0
    var_body = text[var_span[0] + 1 : var_span[1]]
    default_m = re.search(r"default\s*=\s*\{", var_body)
    if not default_m:
        return text, 0
    map_open_in_body = default_m.end() - 1
    map_span = _matching_brace_span(var_body, map_open_in_body)
    if map_span is None:
        return text, 0
    map_body = var_body[map_span[0] + 1 : map_span[1]]
    changed = 0
    new_map_body = map_body
    for key, val in updates.items():
        # Quoted or bare key already present?
        if re.search(
            rf'(?m)^\s*(?:"{re.escape(key)}"|{re.escape(key)})\s*=',
            new_map_body,
        ) or re.search(
            rf'(?:^|[,{{])\s*(?:"{re.escape(key)}"|{re.escape(key)})\s*=',
            new_map_body,
        ):
            new_map_body, n = re.subn(
                rf'((?:"{re.escape(key)}"|{re.escape(key)})\s*=\s*")[^"]*(")',
                rf"\g<1>{val}\2",
                new_map_body,
                count=1,
            )
            if n:
                changed += n
            continue
        # Prefer multiline insert when the map already has newlines.
        if "\n" in new_map_body:
            new_map_body = new_map_body.rstrip() + f'\n    {key} = "{val}"\n  '
        else:
            stripped = new_map_body.strip()
            sep = ", " if stripped else ""
            new_map_body = f'{stripped}{sep}{key} = "{val}"'
        changed += 1
    if changed == 0:
        return text, 0
    abs_map_open = var_span[0] + 1 + map_span[0]
    abs_map_close = var_span[0] + 1 + map_span[1]
    new_text = text[: abs_map_open + 1] + new_map_body + text[abs_map_close:]
    return new_text, changed


def ensure_resource_labels_line(text: str, address: str) -> tuple[str, int]:
    """Ensure labels = var.labels (or tags = var.tags) on a resource that can take them."""
    m = re.match(r"^([^.]+)\.(.+)$", address)
    if not m:
        return text, 0
    rtype, rname = m.group(1), m.group(2)
    attr = "tags" if rtype.startswith("azurerm_") else "labels"
    var_ref = "var.tags" if attr == "tags" else "var.labels"
    pattern = re.compile(
        rf'(resource\s+"{re.escape(rtype)}"\s+"{re.escape(rname)}"\s*\{{)(.*?)(\n\}})',
        re.S,
    )
    match = pattern.search(text)
    if not match:
        return text, 0
    body = match.group(2)
    if re.search(rf"(?m)^\s*{attr}\s*=", body) or re.search(
        rf"(?m)^\s*resource_labels\s*=", body
    ):
        return text, 0
    insert = f"\n  {attr} = {var_ref}\n"
    new_body = body.rstrip() + insert
    return text[: match.start(2)] + new_body + text[match.end(2) :], 1


def ensure_tls_attr(text: str, address: str, attr: str, literal: str) -> tuple[str, int]:
    m = re.match(r"^([^.]+)\.(.+)$", address)
    if not m:
        return text, 0
    rtype, rname = m.group(1), m.group(2)
    pattern = re.compile(
        rf'(resource\s+"{re.escape(rtype)}"\s+"{re.escape(rname)}"\s*\{{)(.*?)(\n\}})',
        re.S,
    )
    match = pattern.search(text)
    if not match:
        return text, 0
    body = match.group(2)
    if re.search(rf"(?m)^\s*{re.escape(attr)}\s*=", body):
        new_body, n = re.subn(
            rf"(?m)^(\s*{re.escape(attr)}\s*=\s*).*$",
            rf"\g<1>{literal}",
            body,
            count=1,
        )
        if n:
            return text[: match.start(2)] + new_body + text[match.end(2) :], 1
        return text, 0
    insert = f"\n  {attr} = {literal}\n"
    new_body = body.rstrip() + insert
    return text[: match.start(2)] + new_body + text[match.end(2) :], 1


def apply_remediations(
    work_root: Path,
    cloud: str,
    remediations: list[dict[str, Any]],
) -> dict[str, Any]:
    groups_root = work_root / cloud / "groups"
    assumptions_path = work_root / cloud / "artifacts" / "governance-assumptions.md"
    aws_tags = aws_tag_map(work_root)
    applied = 0
    skipped = 0
    by_group: dict[str, list[dict[str, Any]]] = {}

    for item in remediations:
        action = str(item.get("action") or "")
        if action in ("", "unknown", "exempt_resource"):
            skipped += 1
            continue
        gid = str(item.get("group_id") or "")
        if not gid:
            skipped += 1
            continue
        by_group.setdefault(gid, []).append(item)

    # Always leave an assumptions file for the destination PR (even when empty).
    assumptions_path.parent.mkdir(parents=True, exist_ok=True)
    if not assumptions_path.is_file():
        assumptions_path.write_text(
            "# Migration assumptions\n\n"
            "Placeholders applied during OPA mechanical remediations are listed below.\n"
            "Operators must replace them before apply.\n",
            encoding="utf-8",
        )

    for gid, items in by_group.items():
        group_dir = groups_root / gid
        if not group_dir.is_dir():
            skipped += len(items)
            continue
        tf_files = sorted(group_dir.glob("*.tf"))
        if not tf_files:
            skipped += len(items)
            continue

        # Prefer variables.tf / main.tf for defaults; patch all files for resources.
        file_texts = {p: p.read_text(encoding="utf-8") for p in tf_files}
        label_updates: dict[str, str] = {}

        for item in items:
            action = str(item.get("action") or "")
            key = str(item.get("key") or "")
            address = str(item.get("resource_address") or "")
            if action in ("set_label", "set_tag", "set_var_default") and key:
                value, _assumed = resolve_label_value(
                    key, cloud=cloud, aws_tags=aws_tags, assumptions_path=assumptions_path
                )
                label_updates[key] = value
                if address and action in ("set_label", "set_tag"):
                    # Ensure resource references the map.
                    for path, text in list(file_texts.items()):
                        new_text, n = ensure_resource_labels_line(text, address)
                        if n:
                            file_texts[path] = new_text
                            applied += n
            elif action == "set_attr" and key and address:
                literal = TLS_ATTR_DEFAULTS.get(key) or str(
                    item.get("suggested_value") or "true"
                )
                if not re.match(r'^(".+"|true|false|[0-9]+)$', literal):
                    literal = json.dumps(literal)
                for path, text in list(file_texts.items()):
                    new_text, n = ensure_tls_attr(text, address, key, literal)
                    if n:
                        file_texts[path] = new_text
                        applied += n
                        break
                else:
                    skipped += 1
            else:
                skipped += 1

        if label_updates:
            # Patch defaults in variables.tf preferentially.
            prefer = sorted(
                file_texts.keys(),
                key=lambda p: (0 if p.name == "variables.tf" else 1, p.name),
            )
            patched = False
            for path in prefer:
                new_text, n = patch_labels_default_map(file_texts[path], label_updates)
                if n:
                    file_texts[path] = new_text
                    applied += n
                    patched = True
                    break
            if not patched:
                skipped += len(label_updates)

        for path, text in file_texts.items():
            path.write_text(text, encoding="utf-8")

    return {
        "schema": "nile-opa-mechanical-fixes/v1",
        "cloud": cloud,
        "applied": applied,
        "skipped": skipped,
        "remediation_count": len(remediations),
        "assumptions_path": str(assumptions_path),
        "generated_at": utc_now(),
    }


def remediations_from_findings(findings: list[dict[str, Any]], cloud: str) -> list[dict[str, Any]]:
    """Fallback when governance-opa-remediations.json is missing."""
    from governance_opa_check import finding_to_remediation

    return [finding_to_remediation(item, cloud=cloud) for item in findings]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-root", required=True)
    parser.add_argument("--cloud", required=True, choices=("azure", "gcp"))
    args = parser.parse_args(argv)
    work_root = Path(args.work_root).resolve()
    cloud = args.cloud
    artifacts = work_root / cloud / "artifacts"
    rem_path = artifacts / "governance-opa-remediations.json"
    payload = load_json(rem_path)
    remediations: list[dict[str, Any]] = []
    if isinstance(payload, dict):
        remediations = list(payload.get("remediations") or [])
    elif isinstance(payload, list):
        remediations = payload
    if not remediations:
        findings_payload = load_json(artifacts / "governance-opa-findings.json") or {}
        findings = list(findings_payload.get("findings") or [])
        remediations = remediations_from_findings(findings, cloud)

    result = apply_remediations(work_root, cloud, remediations)
    out = artifacts / "governance-opa-mechanical-fixes.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
