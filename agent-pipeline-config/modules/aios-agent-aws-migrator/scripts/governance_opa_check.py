#!/usr/bin/env python3
"""Run Nile-Factory Rego packs against Terraform plan JSON for generated IaC.

Plans each destination group (tofu plan -refresh=false), evaluates every
rules/*/policy.rego pack with OPA, and emits actionable findings for the
governance-conform agent to reason about and fix HCL at the correct layer.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from governance_conform import authenticated_clone_url, git_output, utc_now

DEFAULT_RULES_REPO = "https://github.com/Walmart-StackGen/Nile-Factory.git"
DEFAULT_RULES_REF = "main"
CONTROL_ID_RE = re.compile(r"^([A-Z]{2,5}-\d{3})(?::|\s)")

# google_* types with no labels attribute (keep in sync with TAG-002 / PRG-002 Rego).
GCP_LABEL_INCAPABLE_TYPES = frozenset(
    {
        "google_compute_network",
        "google_compute_subnetwork",
        "google_compute_firewall",
        "google_compute_route",
        "google_compute_router",
        "google_compute_router_nat",
        "google_compute_global_address",
        "google_compute_address",
        "google_compute_forwarding_rule",
        "google_compute_global_forwarding_rule",
        "google_compute_target_http_proxy",
        "google_compute_target_https_proxy",
        "google_compute_url_map",
        "google_compute_backend_service",
        "google_compute_health_check",
        "google_compute_firewall_policy",
        "google_compute_firewall_policy_rule",
        "google_service_account",
        "google_service_account_iam_member",
        "google_service_account_iam_binding",
        "google_project_iam_member",
        "google_project_iam_binding",
        "google_project_iam_custom_role",
        "google_project_service",
        # These expose no supported labels field; Cloud SQL is handled through
        # settings.user_labels by the governance policies and remediation tool.
        "google_logging_project_bucket_config",
        "google_bigtable_table",
    }
)


class RulesUnavailable(RuntimeError):
    """Raised when Nile-Factory rules cannot be fetched."""


class OpaUnavailable(RuntimeError):
    """Raised when the opa binary is missing."""


def resolve_bin(name: str, env_key: str) -> str:
    override = os.environ.get(env_key, "").strip()
    if override:
        return override
    found = shutil.which(name)
    if not found:
        raise OpaUnavailable(f"{name} not found on PATH (set {env_key} to override)")
    return found


def refresh_rules(work_root: Path, repo_url: str, ref: str, *, rules_dir: Path | None = None) -> dict[str, Any]:
    """Clone or reuse Nile-Factory rules/ tree."""
    dest = work_root / "rules-src"
    token = os.environ.get("GIT_TOKEN") or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""

    if rules_dir is not None:
        src = rules_dir.resolve()
        rules_root = src if (src / "governance").is_dir() else src / "rules"
        if not rules_root.is_dir():
            raise RulesUnavailable(f"rules dir missing governance packs: {src}")
        sha = "local-fixture"
    else:
        clone_url = authenticated_clone_url(repo_url, token)
        if dest.exists():
            shutil.rmtree(dest, ignore_errors=True)
        dest.mkdir(parents=True, exist_ok=True)
        git_output(["clone", "--depth", "1", "--branch", ref, "--single-branch", clone_url, str(dest)])
        sha = git_output(["rev-parse", "HEAD"], cwd=dest)
        rules_root = dest / "rules"
        if not rules_root.is_dir():
            raise RulesUnavailable(f"cloned repo has no rules/: {repo_url}@{ref}")

    packs = sorted(rules_root.glob("governance/*/policy.rego"))
    packs.extend(sorted(rules_root.glob("architecture/*/policy.rego")))
    if not packs:
        raise RulesUnavailable(f"no policy.rego packs under {rules_root}")

    return {
        "schema": "nile-governance-opa-source/v1",
        "repo": repo_url,
        "ref": ref,
        "commit_sha": sha,
        "rules_root": str(rules_root),
        "pack_count": len(packs),
        "fetched_at": utc_now(),
    }


def list_policy_packs(rules_root: Path) -> list[Path]:
    packs = sorted(rules_root.glob("governance/*/policy.rego"))
    packs.extend(sorted(rules_root.glob("architecture/*/policy.rego")))
    return packs


def group_has_resources(group_dir: Path) -> bool:
    for tf in group_dir.rglob("*.tf"):
        if tf.is_file() and tf.read_text(encoding="utf-8", errors="ignore").strip():
            return True
    return False


_CREDENTIAL_HINTS = (
    "no valid credentials",
    "could not find default credentials",
    "google: could not find default credentials",
    "attempted credentials",
    "authentication failed",
    "error getting credentials",
    "adc",
    "unable to detect region",
    "no credentials loaded",
)


def is_credential_plan_error(message: str) -> bool:
    """True when tofu plan failed for missing cloud credentials (not HCL errors)."""
    lower = (message or "").lower()
    return any(hint in lower for hint in _CREDENTIAL_HINTS)


def diagnose_plan_failure(message: str) -> dict[str, Any]:
    """Classify deterministic provider diagnostics without guessing at fixes."""
    text = str(message or "")
    resource = re.search(r'in resource "([A-Za-z_][A-Za-z0-9_]*)" "([A-Za-z0-9_-]+)"', text)
    unsupported = re.search(r'An argument named "([A-Za-z_][A-Za-z0-9_]*)" is not expected here', text, re.I)
    missing = re.search(r'The argument "([A-Za-z_][A-Za-z0-9_]*)" is required, but no definition was found', text, re.I)
    if unsupported:
        kind, attr = "unsupported_argument", unsupported.group(1)
        action = "remove_rejected_argument_and_recheck"
    elif missing:
        kind, attr = "missing_required_argument", missing.group(1)
        action = "derive_required_value_from_provider_schema_and_source"
    elif is_credential_plan_error(text):
        kind, attr, action = "missing_credentials", "", "restore_credentials_and_retry_plan"
    else:
        kind, attr, action = "unclassified_plan_error", "", "inspect_full_plan_error_before_editing"
    return {
        "kind": kind,
        "resource_type": resource.group(1) if resource else "",
        "resource_name": resource.group(2) if resource else "",
        "attribute": attr,
        "recommended_action": action,
        "diagnostic": text[:1600],
    }


def summarize_failure_classes(findings: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Collapse repeated plan failures to actionable root-cause classes."""
    grouped: dict[tuple[str, str, str], dict[str, Any]] = {}
    for finding in findings:
        if str(finding.get("control_id") or "") != "PLAN_FAILED":
            continue
        diag = diagnose_plan_failure(finding.get("message", ""))
        key = (diag["kind"], diag["resource_type"], diag["attribute"])
        item = grouped.setdefault(key, {**diag, "groups": []})
        gid = str(finding.get("group_id") or "")
        if gid and gid not in item["groups"]:
            item["groups"].append(gid)
    return sorted(grouped.values(), key=lambda item: (item["kind"], item["resource_type"], item["attribute"]))


def _matching_brace_span(text: str, open_idx: int) -> tuple[int, int] | None:
    """Return [open_idx, close_idx] inclusive for a `{` … `}` span, or None."""
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


def _parse_hcl_primitive(raw: str) -> Any:
    text = raw.strip()
    if not text:
        return ""
    if text in ("true", "false"):
        return text == "true"
    if text.startswith('"') and text.endswith('"'):
        return text[1:-1]
    if re.fullmatch(r"-?\d+(\.\d+)?", text):
        return float(text) if "." in text else int(text)
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        if not inner:
            return []
        # Best-effort comma split for simple lists of strings/numbers.
        parts = re.findall(r'"([^"]*)"|(-?\d+(?:\.\d+)?)', inner)
        out: list[Any] = []
        for string_val, num_val in parts:
            if string_val != "" or ('"' in inner and string_val == ""):
                # distinguish empty string match vs number
                if f'"{string_val}"' in inner or string_val:
                    out.append(string_val)
                elif num_val:
                    out.append(float(num_val) if "." in num_val else int(num_val))
            elif num_val:
                out.append(float(num_val) if "." in num_val else int(num_val))
        return out if out else [p.strip().strip('"') for p in inner.split(",") if p.strip()]
    # Unresolved references (var.x, resource.y) stay as strings so OPA still sees a key.
    return text


def _parse_hcl_body(body: str) -> dict[str, Any]:
    """Parse a flat/nested HCL attribute body into a dict approximating plan `after`."""
    result: dict[str, Any] = {}
    i = 0
    n = len(body)
    while i < n:
        while i < n and body[i].isspace():
            i += 1
        if i >= n:
            break
        # skip comments
        if body.startswith("//", i) or body.startswith("#", i):
            nl = body.find("\n", i)
            i = n if nl < 0 else nl + 1
            continue
        if body.startswith("/*", i):
            end = body.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        # Accept bare identifiers and quoted keys ("apm_id" = "…") used in
        # single-line map defaults from the GCP generator.
        key_match = re.match(r'(?:"([^"]+)"|([A-Za-z_][\w-]*))\s*', body[i:])
        if not key_match:
            i += 1
            continue
        key = key_match.group(1) or key_match.group(2)
        i += key_match.end()
        while i < n and body[i].isspace():
            i += 1
        if i < n and body[i] == "=":
            i += 1
            while i < n and body[i].isspace():
                i += 1
            if i < n and body[i] == "{":
                span = _matching_brace_span(body, i)
                if span is None:
                    break
                nested = _parse_hcl_body(body[span[0] + 1 : span[1]])
                result[key] = nested
                i = span[1] + 1
                continue
            # Read until newline / comma / comment at depth 0 (not inside []/"").
            # Commas matter for single-line maps: { "a" = "1", "b" = "2" }.
            start = i
            depth_br = 0
            in_str = False
            str_ch = ""
            while i < n:
                ch = body[i]
                if in_str:
                    if ch == "\\" and i + 1 < n:
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
                if ch == "[":
                    depth_br += 1
                elif ch == "]":
                    depth_br -= 1
                elif ch in ("\n", "#", ",") and depth_br == 0:
                    break
                elif body.startswith("//", i) and depth_br == 0:
                    break
                i += 1
            result[key] = _parse_hcl_primitive(body[start:i])
            if i < n and body[i] == ",":
                i += 1
            continue
        if i < n and body[i] == "{":
            # nested block → list of objects (terraform plan shape)
            span = _matching_brace_span(body, i)
            if span is None:
                break
            nested = _parse_hcl_body(body[span[0] + 1 : span[1]])
            existing = result.get(key)
            if isinstance(existing, list):
                existing.append(nested)
            elif existing is None:
                result[key] = [nested]
            else:
                result[key] = [existing, nested]
            i = span[1] + 1
            continue
        i += 1
    return result


def _variable_defaults(group_dir: Path) -> dict[str, Any]:
    defaults: dict[str, Any] = {}
    var_re = re.compile(r'variable\s+"([^"]+)"\s*\{', re.M)
    for tf in sorted(group_dir.glob("*.tf")):
        text = tf.read_text(encoding="utf-8", errors="ignore")
        for match in var_re.finditer(text):
            name = match.group(1)
            span = _matching_brace_span(text, match.end() - 1)
            if span is None:
                continue
            body = _parse_hcl_body(text[span[0] + 1 : span[1]])
            if "default" in body:
                defaults[name] = body["default"]
    return defaults


def _resolve_after(after: dict[str, Any], defaults: dict[str, Any]) -> dict[str, Any]:
    """Replace simple `var.NAME` string refs with variable defaults when present."""

    def resolve(value: Any) -> Any:
        if isinstance(value, str):
            m = re.fullmatch(r"var\.([A-Za-z_][\w-]*)", value.strip())
            if m and m.group(1) in defaults:
                return defaults[m.group(1)]
            return value
        if isinstance(value, list):
            return [resolve(v) for v in value]
        if isinstance(value, dict):
            return {k: resolve(v) for k, v in value.items()}
        return value

    return resolve(after)


def synthesize_plan_from_hcl(group_dir: Path) -> dict[str, Any] | None:
    """Build a tofu-plan-shaped JSON from HCL when live plan needs cloud credentials.

    Nile Rego packs read `input.resource_changes[].change.after`. Without ADC,
    `tofu plan` fails before emitting that JSON; synthesizing from `.tf` keeps
    OPA governance evaluable for label/tag/org-policy denies.
    """
    defaults = _variable_defaults(group_dir)
    resource_re = re.compile(r'resource\s+"([^"]+)"\s+"([^"]+)"\s*\{', re.M)
    changes: list[dict[str, Any]] = []
    for tf in sorted(group_dir.rglob("*.tf")):
        text = tf.read_text(encoding="utf-8", errors="ignore")
        for match in resource_re.finditer(text):
            rtype, rname = match.group(1), match.group(2)
            span = _matching_brace_span(text, match.end() - 1)
            if span is None:
                continue
            after = _resolve_after(_parse_hcl_body(text[span[0] + 1 : span[1]]), defaults)
            changes.append(
                {
                    "address": f"{rtype}.{rname}",
                    "mode": "managed",
                    "type": rtype,
                    "name": rname,
                    "change": {"actions": ["create"], "after": after},
                }
            )
    if not changes:
        return None
    return {
        "format_version": "1.2",
        "resource_changes": changes,
        "synthetic": True,
        "synthetic_reason": "credentials_unavailable",
    }


def plan_group(group_dir: Path, tofu_bin: str) -> tuple[dict[str, Any] | None, str]:
    """Return (plan_json, error). plan_json is None on failure."""
    init = subprocess.run(
        [tofu_bin, "init", "-backend=false", "-input=false", "-no-color"],
        cwd=str(group_dir),
        capture_output=True,
        text=True,
    )
    if init.returncode != 0:
        # init can also fail without providers/creds; still try HCL synthesis
        synth = synthesize_plan_from_hcl(group_dir)
        if synth is not None:
            return synth, ""
        return None, (init.stderr or init.stdout or "tofu init failed").strip()[:500]

    plan_file = group_dir / "opa-check.tfplan"
    plan = subprocess.run(
        [tofu_bin, "plan", "-refresh=false", "-input=false", "-lock=false", "-no-color", "-out=opa-check.tfplan"],
        cwd=str(group_dir),
        capture_output=True,
        text=True,
    )
    if plan.returncode != 0:
        plan_file.unlink(missing_ok=True)
        err = (plan.stderr or plan.stdout or "tofu plan failed").strip()[:500]
        if is_credential_plan_error(err):
            synth = synthesize_plan_from_hcl(group_dir)
            if synth is not None:
                return synth, ""
        return None, err

    show = subprocess.run(
        [tofu_bin, "show", "-json", str(plan_file.name)],
        cwd=str(group_dir),
        capture_output=True,
        text=True,
    )
    plan_file.unlink(missing_ok=True)
    if show.returncode != 0:
        return None, (show.stderr or show.stdout or "tofu show -json failed").strip()[:500]

    try:
        return json.loads(show.stdout), ""
    except json.JSONDecodeError as exc:
        return None, f"invalid plan json: {exc}"


def eval_pack_query(opa_bin: str, policy_file: Path, plan: dict[str, Any], rule: str) -> tuple[list[Any], str]:
    """Evaluate one policy output; Rego owns both denies and remediation direction."""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as handle:
        json.dump(plan, handle)
        plan_path = handle.name
    try:
        result = subprocess.run(
            [opa_bin, "eval", "-f", "json", "-i", plan_path, "-d", str(policy_file), rule],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            err = (result.stderr or result.stdout or "opa eval failed").strip()
            return [], f"OPA_ERROR: {policy_file.parent.name}: {err[:300]}"
        try:
            envelope = json.loads(result.stdout or "{}")
        except json.JSONDecodeError:
            return [], f"OPA_PARSE: {policy_file.parent.name}: {(result.stdout or '')[:300]}"
        results = envelope.get("result") or []
        if not results:
            return [], ""
        expressions = results[0].get("expressions") or []
        if not expressions:
            return [], ""
        value = expressions[0].get("value")
        if value is None:
            return [], ""
        if isinstance(value, (list, set)):
            return list(value), ""
        return [value], ""
    finally:
        Path(plan_path).unlink(missing_ok=True)


def eval_pack_denies(opa_bin: str, policy_file: Path, plan: dict[str, Any]) -> list[str]:
    values, error = eval_pack_query(opa_bin, policy_file, plan, "data.policy.deny")
    if error:
        return [error]
    return [str(item) for item in values]


def eval_pack_remediation(opa_bin: str, policy_file: Path, plan: dict[str, Any]) -> list[dict[str, Any]]:
    """Return remediation guidance authored by this policy pack; never synthesize fixes here."""
    values, error = eval_pack_query(opa_bin, policy_file, plan, "data.policy.remediation")
    if error:
        return [{"evaluation_error": error, "policy_pack": policy_file.parent.name}]
    return [item for item in values if isinstance(item, dict)]


def parse_control_id(message: str) -> str:
    match = CONTROL_ID_RE.match(message.strip())
    if match:
        return match.group(1)
    return "OPA_DENY"


def parse_resource_address(message: str, plan: dict[str, Any]) -> str:
    """Best-effort: match type.name from deny message to plan addresses."""
    for rc in plan.get("resource_changes") or []:
        rc_type = rc.get("type") or ""
        rc_name = rc.get("name") or ""
        if rc_type and rc_name and f"{rc_type}.{rc_name}" in message:
            return rc.get("address") or f"{rc_type}.{rc_name}"
    for rc in plan.get("resource_changes") or []:
        addr = rc.get("address") or ""
        if addr and addr in message:
            return addr
    return ""


def deny_to_finding(
    *,
    message: str,
    pack_dir: Path,
    group_id: str,
    plan: dict[str, Any],
) -> dict[str, Any]:
    control_id = parse_control_id(message)
    address = parse_resource_address(message, plan)
    return {
        "resource_address": address,
        "resource_type": "",
        "file": "",
        "group_id": group_id,
        "pack_dir": pack_dir.name,
        "decision_path": ["opa", pack_dir.name],
        "control_id": control_id,
        "nile_priority": 1,
        "blocks_commit": True,
        "autofixed": False,
        "severity": "blocker",
        "message": message,
        "evidence_gap": False,
    }


def merge_plan_resource_changes(plans: list[dict[str, Any]]) -> dict[str, Any]:
    merged: list[Any] = []
    for plan in plans:
        merged.extend(plan.get("resource_changes") or [])
    return {"format_version": "1.2", "resource_changes": merged}


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="OPA governance check on Terraform plan JSON.")
    parser.add_argument("--work-root", required=True)
    parser.add_argument("--cloud", required=True, choices=("azure", "gcp"))
    parser.add_argument("--repo", default=os.environ.get("NILE_RULES_REPO", DEFAULT_RULES_REPO))
    parser.add_argument("--ref", default=os.environ.get("NILE_RULES_REF", DEFAULT_RULES_REF))
    parser.add_argument("--rules-dir", default="", help="Use local rules tree (tests / offline).")
    parser.add_argument(
        "--max-groups",
        type=int,
        default=int(os.environ.get("GOVERNANCE_OPA_MAX_GROUPS", "0")),
        help="Max groups to plan+OPA (0 = all). Set GOVERNANCE_OPA_MAX_GROUPS to sample under time pressure.",
    )
    return parser.parse_args(argv)


def run(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    work_root = Path(args.work_root).resolve()
    cloud = args.cloud
    groups_root = work_root / cloud / "groups"
    artifacts = work_root / cloud / "artifacts"
    artifacts.mkdir(parents=True, exist_ok=True)

    if not groups_root.is_dir():
        write_json(
            artifacts / "governance-opa-report.json",
            {"schema": "nile-governance-opa-report/v1", "cloud": cloud, "opa_ok": False, "blocked": "generation_missing"},
        )
        return 2

    try:
        opa_bin = resolve_bin("opa", "OPA_BIN")
        tofu_bin = resolve_bin("tofu", "TOFU_BIN")
        if not shutil.which("terraform") and tofu_bin.endswith("tofu"):
            pass
        rules_dir = Path(args.rules_dir).resolve() if args.rules_dir else None
        source = refresh_rules(work_root, args.repo, args.ref, rules_dir=rules_dir)
    except (RulesUnavailable, OpaUnavailable) as exc:
        write_json(
            artifacts / "governance-opa-report.json",
            {
                "schema": "nile-governance-opa-report/v1",
                "cloud": cloud,
                "opa_ok": False,
                "blocked": str(exc),
                "generated_at": utc_now(),
            },
        )
        return 2

    rules_root = Path(source["rules_root"])
    packs = list_policy_packs(rules_root)
    all_group_dirs = sorted(p for p in groups_root.iterdir() if p.is_dir())
    groups_discovered = len(all_group_dirs)
    group_dirs = all_group_dirs
    if args.max_groups > 0:
        group_dirs = group_dirs[: args.max_groups]

    findings: list[dict[str, Any]] = []
    group_results: list[dict[str, Any]] = []
    plan_failures = 0
    merged_plans: list[dict[str, Any]] = []

    for group_dir in group_dirs:
        group_id = group_dir.name
        if not group_has_resources(group_dir):
            group_results.append({"group_id": group_id, "status": "skipped:empty_scaffold", "deny_count": 0})
            continue

        plan, plan_err = plan_group(group_dir, tofu_bin)
        if plan is None:
            plan_failures += 1
            findings.append(
                {
                    "resource_address": "",
                    "resource_type": "",
                    "file": "",
                    "group_id": group_id,
                    "decision_path": ["opa", "plan"],
                    "control_id": "PLAN_FAILED",
                    "nile_priority": 1,
                    "blocks_commit": True,
                    "autofixed": False,
                    "severity": "blocker",
                    "message": f"PLAN_FAILED: {group_id}: {plan_err}",
                    "evidence_gap": False,
                }
            )
            group_results.append({"group_id": group_id, "status": "plan_failed", "deny_count": 0, "error": plan_err})
            continue

        merged_plans.append(plan)
        group_denies: list[str] = []
        group_guidance: list[dict[str, Any]] = []
        for policy in packs:
            denies = eval_pack_denies(opa_bin, policy, plan)
            policy_guidance = eval_pack_remediation(opa_bin, policy, plan)
            for guidance in policy_guidance:
                if guidance.get("evaluation_error"):
                    continue
                group_guidance.append({**guidance, "policy_pack": policy.parent.name})
            for msg in denies:
                group_denies.append(msg)
                finding = deny_to_finding(message=msg, pack_dir=policy.parent, group_id=group_id, plan=plan)
                control_id = finding["control_id"]
                address = finding["resource_address"]
                matching_guidance = [
                    item for item in group_guidance
                    if item.get("control_id") == control_id
                    and item.get("resource_address") == address
                ]
                finding["remediation_guidance"] = matching_guidance
                findings.append(finding)

        group_results.append(
            {
                "group_id": group_id,
                "status": "fail" if group_denies else "pass",
                "deny_count": len(group_denies),
            }
        )

    merged_plan_path = artifacts / "governance-opa-merged-plan.json"
    if merged_plans:
        write_json(merged_plan_path, merge_plan_resource_changes(merged_plans))

    opa_ok = len(findings) == 0
    failure_classes = summarize_failure_classes(findings)
    report = {
        "schema": "nile-governance-opa-report/v1",
        "cloud": cloud,
        "rules_repo": source.get("repo"),
        "rules_ref": source.get("ref"),
        "rules_commit_sha": source.get("commit_sha"),
        "pack_count": len(packs),
        "groups_discovered": groups_discovered,
        "groups_checked": len(group_results),
        "max_groups_limit": args.max_groups,
        "plan_failures": plan_failures,
        "failure_classes": failure_classes,
        "deny_count": len(findings),
        "opa_ok": opa_ok,
        "blocked": "",
        "groups": group_results,
        "generated_at": utc_now(),
    }
    write_json(artifacts / "governance-opa-report.json", report)
    write_json(
        artifacts / "governance-opa-findings.json",
        {
            "schema": "nile-governance-opa-findings/v1",
            "cloud": cloud,
            "findings": findings,
            "deny_count": len(findings),
        },
    )
    # Guidance is emitted by Rego packs and merely collected here. Python does
    # not infer values, choose edits, or mutate generated Terraform.
    rego_guidance = [
        {**item, "policy_pack": finding.get("pack_dir", "")}
        for finding in findings
        for item in finding.get("remediation_guidance", [])
    ]
    write_json(
        artifacts / "governance-opa-guidance.json",
        {
            "schema": "nile-governance-opa-guidance/v1",
            "cloud": cloud,
            "guidance_source": "rules/*/policy.rego:data.policy.remediation",
            "guidance_count": len(rego_guidance),
            "guidance": rego_guidance,
            "generated_at": utc_now(),
        },
    )

    # Human-readable guidance for the agent
    lines = [
        "# OPA governance findings and Rego-authored remediation direction",
        "",
        "Rego guidance describes desired direction and provider-schema path. The migration agent owns diagnosis, source-value selection, HCL edits, assumptions, and re-verification; this checker never patches Terraform.",
        "",
        f"Rules SHA: `{source.get('commit_sha')}`",
        "",
        "Root-cause plan failure classes (deduplicated):",
        "",
        *(
            f"- `{item['kind']}` on `{item['resource_type']}` attribute `{item['attribute']}` "
            f"in {len(item['groups'])} group(s): {item['recommended_action']}"
            for item in failure_classes
        ),
        "" if failure_classes else "- None.",
        "",
        "Structured Rego-authored guidance: `governance-opa-guidance.json`.",
        "",
    ]
    if not findings:
        lines.append("_No OPA denies — IaC matches codified Rego packs._")
    else:
        for item in findings[:200]:
            gid = item.get("group_id") or "?"
            lines.append(f"- **{gid}** `{item.get('control_id')}`: {item.get('message')}")
            if item.get("guidance_gap"):
                lines.append(f"  - **Policy authoring gap:** {item['guidance_gap']}")
            for direction in item.get("remediation_guidance") or []:
                lines.append(
                    f"  - Rego direction: `{direction.get('operation')}` at `"
                    f"{direction.get('target_path')}`; desired: {direction.get('desired_state')}. "
                    f"Value source: {direction.get('value_source')}"
                )
        if len(findings) > 200:
            lines.append(f"- … and {len(findings) - 200} more")
    lines.append("")
    (artifacts / "governance-opa-fix-hints.md").write_text("\n".join(lines), encoding="utf-8")

    print(json.dumps(report))
    return 0 if opa_ok else 1


if __name__ == "__main__":
    sys.exit(run())
