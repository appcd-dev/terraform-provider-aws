#!/usr/bin/env python3
"""Deterministic lint/security autofix for destination Azure/GCP review-candidate roots.

Runs as the azure-iac-harden / gcp-iac-harden stage (parallel with validate).
Only applies mechanical, reversible fixes — never invents IAM translations or
network topology. Residual findings are reported for human review in the same PR.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


RESOURCE_RE = re.compile(
    r'resource\s+"([^"]+)"\s+"([^"]+)"\s*\{',
    re.MULTILINE,
)


def _ensure_attr_in_block(text: str, resource_type: str, attr: str, value_hcl: str) -> tuple[str, bool]:
    """Insert attr = value into matching resource blocks when the attr is absent."""
    changed = False
    out: list[str] = []
    i = 0
    while i < len(text):
        m = RESOURCE_RE.search(text, i)
        if not m:
            out.append(text[i:])
            break
        out.append(text[i : m.start()])
        typ, _name = m.group(1), m.group(2)
        # Find matching closing brace for this resource (naive brace count).
        start = m.start()
        brace = text.find("{", m.end() - 1)
        if brace < 0:
            out.append(text[m.start() :])
            break
        depth = 0
        j = brace
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        block = text[start:j]
        if typ == resource_type and not re.search(rf"(?m)^\s*{re.escape(attr)}\s*=", block):
            # Insert before final closing brace of the block.
            insert_at = block.rfind("}")
            indent = "  "
            block = block[:insert_at] + f"{indent}{attr} = {value_hcl}\n" + block[insert_at:]
            changed = True
        out.append(block)
        i = j
    return "".join(out), changed


def _strip_plaintext_passwords(text: str) -> tuple[str, list[dict[str, str]]]:
    findings: list[dict[str, str]] = []
    pattern = re.compile(
        r'(?m)^(\s*)(admin_password|password|administrator_login_password)\s*=\s*"[^"]+"\s*$'
    )

    def repl(m: re.Match[str]) -> str:
        findings.append(
            {
                "severity": "high",
                "code": "plaintext_password_removed",
                "message": f"Removed plaintext `{m.group(2)}` from generated HCL",
            }
        )
        return (
            f"{m.group(1)}# HARDEN: plaintext {m.group(2)} removed — set via Key Vault / secret ref\n"
            f"{m.group(1)}# {m.group(2)} = \"\""
        )

    return pattern.sub(repl, text), findings


def _flag_open_ingress(text: str) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    if re.search(r'0\.0\.0\.0/0', text) and re.search(
        r'(destination_port_range|ports)\s*=\s*"(22|3389|\*)"', text
    ):
        findings.append(
            {
                "severity": "high",
                "code": "open_management_ingress",
                "message": "Found 0.0.0.0/0 allowing SSH/RDP/* — review NSG/firewall before apply",
                "autofixed": "false",
            }
        )
    elif "0.0.0.0/0" in text:
        findings.append(
            {
                "severity": "medium",
                "code": "open_cidr",
                "message": "Found 0.0.0.0/0 — confirm intended public exposure",
                "autofixed": "false",
            }
        )
    return findings


AZURE_ENSURE: list[tuple[str, str, str]] = [
    ("azurerm_storage_account", "min_tls_version", '"TLS1_2"'),
    ("azurerm_storage_account", "https_traffic_only_enabled", "true"),
    ("azurerm_linux_function_app", "https_only", "true"),
    ("azurerm_windows_function_app", "https_only", "true"),
    ("azurerm_linux_web_app", "https_only", "true"),
    ("azurerm_windows_web_app", "https_only", "true"),
    ("azurerm_mssql_server", "minimum_tls_version", '"1.2"'),
]

GCP_ENSURE: list[tuple[str, str, str]] = [
    ("google_storage_bucket", "uniform_bucket_level_access", "true"),
    ("google_compute_instance", "can_ip_forward", "false"),
]


def harden_group(group_dir: Path, cloud: str) -> dict[str, Any]:
    group_id = group_dir.name
    result: dict[str, Any] = {
        "group_id": group_id,
        "cloud": cloud,
        "files_touched": [],
        "fixes": [],
        "findings": [],
        "skipped": False,
    }
    tf_files = sorted(group_dir.glob("*.tf"))
    if not tf_files:
        result["skipped"] = True
        result["skip_reason"] = "no_tf_files"
        return result

    ensure = AZURE_ENSURE if cloud == "azure" else GCP_ENSURE
    for tf_path in tf_files:
        original = tf_path.read_text(encoding="utf-8", errors="replace")
        text = original
        file_fixes: list[str] = []

        new_text, pw_findings = _strip_plaintext_passwords(text)
        if pw_findings:
            text = new_text
            for f in pw_findings:
                f["autofixed"] = "true"
                f["file"] = tf_path.name
                result["findings"].append(f)
                file_fixes.append(f["code"])

        for typ, attr, value in ensure:
            text2, changed = _ensure_attr_in_block(text, typ, attr, value)
            if changed:
                text = text2
                code = f"ensure_{typ}_{attr}"
                file_fixes.append(code)
                result["findings"].append(
                    {
                        "severity": "medium",
                        "code": code,
                        "message": f"Inserted `{attr} = {value}` on `{typ}`",
                        "autofixed": "true",
                        "file": tf_path.name,
                    }
                )

        for finding in _flag_open_ingress(text):
            finding["file"] = tf_path.name
            result["findings"].append(finding)

        if text != original:
            tf_path.write_text(text, encoding="utf-8")
            result["files_touched"].append(tf_path.name)
            result["fixes"].extend(file_fixes)

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cloud", choices=("azure", "gcp"), required=True)
    parser.add_argument("--group-dir", type=Path, required=True)
    parser.add_argument("--json-out", type=Path, help="Optional per-group JSON path")
    args = parser.parse_args()

    if not args.group_dir.is_dir():
        print(f"harden_fail=missing_group_dir path={args.group_dir}", file=sys.stderr)
        return 2

    result = harden_group(args.group_dir.resolve(), args.cloud)
    line = (
        f"harden_ok group={result['group_id']} "
        f"fixes={len(result['fixes'])} findings={len(result['findings'])} "
        f"touched={len(result['files_touched'])}"
    )
    print(line)
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
