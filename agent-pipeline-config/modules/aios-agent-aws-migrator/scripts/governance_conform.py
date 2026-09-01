#!/usr/bin/env python3
"""Harness for Nile living-governance conformance.

This module does **not** encode Nile Priority-1 controls. Each run:

1. Refreshes Governance-and-Policy into ``$WORK_ROOT/governance/`` (or accepts
   a local tree for tests).
2. Inventories Terraform resources under ``azure|gcp/groups``.
3. Seeds an empty validator scaffold if the agent has not authored one.
4. Executes the agent-authored validator and normalizes findings/report JSON.

Authority for which checks apply lives in the refreshed markdown. The SOP
teaches the agent how to rebuild a decision tree from those docs.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse, urlunparse

DEFAULT_GOVERNANCE_REPO = "https://github.com/Walmart-StackGen/Governance-and-Policy.git"
DEFAULT_GOVERNANCE_REF = "main"
SCAFFOLD_MARKER = "NILE_GOVERNANCE_VALIDATOR_SCAFFOLD"
RESOURCE_RE = re.compile(r'^\s*resource\s+"([^"]+)"\s+"([^"]+)"', re.MULTILINE)

REQUIRED_DOC_PATHS = (
    "governance/policy-catalog.md",
    "governance/control-matrix.md",
    "governance/tagging-labeling-standard.md",
    "governance/priority-controls.md",
    "governance/production-readiness-gates.md",
    "governance/evidence-schema.md",
)

OPTIONAL_DOC_PATHS = (
    "governance/exception-management.md",
    "governance/exception-authority-model.md",
    "governance/approval-authority-model.md",
    "architecture/nile-overview.md",
    "architecture/factory-lifecycle.md",
    "architecture/platform-roles.md",
)

VALIDATOR_SCAFFOLD = '''#!/usr/bin/env python3
# NILE_GOVERNANCE_VALIDATOR_SCAFFOLD
"""Replace this scaffold with a validator derived from this run's governance-decision-tree.json.

Do not copy a frozen Nile control list. Read $WORK_ROOT/governance/ (this run's
SHA in governance-source.json), walk each resource in resource-inventory.json
through the tree, and emit findings. Validation evidence is not human approval.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-root", required=True)
    parser.add_argument("--cloud", required=True, choices=("azure", "gcp"))
    args = parser.parse_args()
    artifacts = Path(args.work_root) / args.cloud / "artifacts"
    artifacts.mkdir(parents=True, exist_ok=True)
    inventory = json.loads((artifacts / "resource-inventory.json").read_text(encoding="utf-8"))
    findings = {
        "schema": "nile-governance-findings/v1",
        "cloud": args.cloud,
        "resources": [],
        "findings": [
            {
                "resource_address": "",
                "resource_type": "",
                "file": "",
                "decision_path": ["validator_not_authored"],
                "control_id": "validator_not_authored",
                "nile_priority": 1,
                "blocks_commit": True,
                "autofixed": False,
                "severity": "blocker",
                "message": "Author governance-validator.py from this run's decision tree before claiming conformance.",
            }
        ],
        "authored": False,
    }
    for item in inventory.get("resources") or []:
        findings["resources"].append(
            {
                "address": item.get("address"),
                "type": item.get("type"),
                "conformance_ok": False,
            }
        )
    (artifacts / "governance-findings.json").write_text(
        json.dumps(findings, indent=2) + "\\n", encoding="utf-8"
    )
    print(json.dumps(findings))
    return 0


if __name__ == "__main__":
    sys.exit(main())
'''


class GovernanceDocsUnavailable(RuntimeError):
    """Raised when the living governance tree cannot be refreshed."""


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def authenticated_clone_url(repo_url: str, token: str) -> str:
    """Rewrite a GitHub HTTPS URL with a token without logging the token."""
    if not token or not repo_url.startswith("https://github.com/"):
        return repo_url
    parsed = urlparse(repo_url)
    netloc = f"x-access-token:{token}@{parsed.hostname}"
    if parsed.port:
        netloc = f"{netloc}:{parsed.port}"
    return urlunparse((parsed.scheme, netloc, parsed.path, parsed.params, parsed.query, parsed.fragment))


def git_output(args: list[str], cwd: Path | None = None) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=str(cwd) if cwd else None,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise GovernanceDocsUnavailable(result.stderr.strip() or result.stdout.strip() or "git failed")
    return result.stdout.strip()


def suggested_category(resource_type: str) -> str:
    """Heuristic inventory hint only — the agent must remap from current docs."""
    t = resource_type.lower()
    if any(k in t for k in ("storage", "blob", "bucket", "disk", "volume", "filestore", "backup")):
        return "storage"
    if any(k in t for k in ("sql", "database", "cosmos", "spanner", "bigquery", "redis", "cache", "key_vault", "kms", "secret")):
        return "data"
    if any(k in t for k in ("virtual_network", "subnet", "nsg", "firewall", "lb", "load_balancer", "gateway", "vpc", "router", "dns", "private_endpoint")):
        return "networking"
    if any(k in t for k in ("iam", "role", "identity", "service_account", "managed_identity", "policy")):
        return "identity"
    if any(k in t for k in ("kubernetes", "aks", "gke", "container_cluster", "helm")):
        return "kubernetes"
    if any(k in t for k in ("linux_virtual_machine", "windows_virtual_machine", "compute", "instance", "vmss", "function", "app_service", "cloud_run")):
        return "compute"
    return "other"


def existing_paths(root: Path, relative: tuple[str, ...]) -> list[str]:
    found: list[str] = []
    for rel in relative:
        if (root / rel).is_file():
            found.append(rel)
    return found


def refresh_governance(
    work_root: Path,
    repo_url: str,
    ref: str,
    *,
    source_dir: Path | None = None,
) -> dict[str, Any]:
    """Clone or fetch living governance docs into work_root/governance.

    When source_dir is set (tests / already-fetched tree), skip the network and
    copy or reuse that tree. Fail closed if required docs are missing.
    """
    dest = work_root / "governance"
    dest.parent.mkdir(parents=True, exist_ok=True)
    token = os.environ.get("GIT_TOKEN") or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""

    if source_dir is not None:
        src = source_dir.resolve()
        if not src.is_dir():
            raise GovernanceDocsUnavailable(f"governance source dir missing: {src}")
        if dest.resolve() != src:
            if dest.exists():
                subprocess.run(["rm", "-rf", str(dest)], check=False)
            subprocess.run(["cp", "-a", str(src), str(dest)], check=True)
        sha = "local-fixture"
        try:
            sha = git_output(["rev-parse", "HEAD"], cwd=src)
        except GovernanceDocsUnavailable:
            sha = "local-fixture"
    else:
        clone_url = authenticated_clone_url(repo_url, token)
        try:
            if (dest / ".git").is_dir():
                git_output(["fetch", "--depth", "1", "origin", ref], cwd=dest)
                git_output(["checkout", "--force", "FETCH_HEAD"], cwd=dest)
            else:
                if dest.exists():
                    subprocess.run(["rm", "-rf", str(dest)], check=False)
                git_output(["clone", "--depth", "1", "--branch", ref, clone_url, str(dest)])
            sha = git_output(["rev-parse", "HEAD"], cwd=dest)
        except GovernanceDocsUnavailable as exc:
            raise GovernanceDocsUnavailable(f"refresh failed: {exc}") from exc

    required = existing_paths(dest, REQUIRED_DOC_PATHS)
    missing = [p for p in REQUIRED_DOC_PATHS if p not in required]
    if missing:
        raise GovernanceDocsUnavailable(f"required governance docs missing: {','.join(missing)}")

    source = {
        "schema": "nile-governance-source/v1",
        "repo": repo_url,
        "ref": ref,
        "commit_sha": sha,
        "fetched_at": utc_now(),
        "work_path": str(dest),
        "paths_read": required + existing_paths(dest, OPTIONAL_DOC_PATHS),
        "required_missing": [],
    }
    return source


def inventory_resources(groups_dir: Path, cloud: str) -> dict[str, Any]:
    resources: list[dict[str, Any]] = []
    if not groups_dir.is_dir():
        return {
            "schema": "nile-resource-inventory/v1",
            "cloud": cloud,
            "groups_dir": str(groups_dir),
            "resources": [],
        }
    for tf_file in sorted(groups_dir.rglob("*.tf")):
        text = tf_file.read_text(encoding="utf-8", errors="replace")
        rel = str(tf_file)
        for match in RESOURCE_RE.finditer(text):
            rtype, name = match.group(1), match.group(2)
            resources.append(
                {
                    "address": f"{rtype}.{name}",
                    "type": rtype,
                    "name": name,
                    "file": rel,
                    "suggested_category": suggested_category(rtype),
                }
            )
    return {
        "schema": "nile-resource-inventory/v1",
        "cloud": cloud,
        "groups_dir": str(groups_dir),
        "resource_count": len(resources),
        "resources": resources,
    }


def seed_validator_scaffold(artifacts_dir: Path) -> Path:
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    path = artifacts_dir / "governance-validator.py"
    if path.is_file() and SCAFFOLD_MARKER not in path.read_text(encoding="utf-8", errors="replace"):
        return path
    path.write_text(VALIDATOR_SCAFFOLD, encoding="utf-8")
    path.chmod(0o755)
    return path


def validator_is_authored(path: Path) -> bool:
    if not path.is_file():
        return False
    text = path.read_text(encoding="utf-8", errors="replace")
    return SCAFFOLD_MARKER not in text


def _as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes")
    return bool(value)


def normalize_findings(raw: Any, cloud: str) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raw = {"findings": raw if isinstance(raw, list) else []}
    findings_in = raw.get("findings")
    if not isinstance(findings_in, list):
        findings_in = []
    normalized: list[dict[str, Any]] = []
    for item in findings_in:
        if not isinstance(item, dict):
            continue
        priority = item.get("nile_priority", item.get("priority", 1))
        try:
            priority_num = int(priority)
        except (TypeError, ValueError):
            priority_num = 1 if str(priority).lower() in ("priority-1", "p1", "1") else 0
        evidence_gap = _as_bool(item.get("evidence_gap")) or str(item.get("severity") or "").lower() == "evidence_gap"
        if "blocks_commit" in item:
            blocks = _as_bool(item.get("blocks_commit"))
        else:
            blocks = priority_num == 1 and not evidence_gap
        normalized.append(
            {
                "resource_address": item.get("resource_address") or item.get("address") or "",
                "resource_type": item.get("resource_type") or item.get("type") or "",
                "file": item.get("file") or "",
                "decision_path": item.get("decision_path") or [],
                "control_id": item.get("control_id") or item.get("code") or "",
                "nile_priority": priority_num,
                "blocks_commit": blocks,
                "autofixed": _as_bool(item.get("autofixed")),
                "severity": item.get("severity") or ("blocker" if blocks else "info"),
                "message": item.get("message") or "",
                "evidence_gap": evidence_gap,
            }
        )
    return {
        "schema": "nile-governance-findings/v1",
        "cloud": cloud,
        "authored": _as_bool(raw.get("authored", True)),
        "resources": raw.get("resources") or [],
        "findings": normalized,
    }


def load_validator_payload(artifacts_dir: Path, stdout: str) -> Any:
    findings_path = artifacts_dir / "governance-findings.json"
    if findings_path.is_file():
        return json.loads(findings_path.read_text(encoding="utf-8"))
    stdout = stdout.strip()
    if stdout:
        return json.loads(stdout)
    return {"findings": []}


def run_validator(validator: Path, work_root: Path, cloud: str) -> dict[str, Any]:
    artifacts = work_root / cloud / "artifacts"
    proc = subprocess.run(
        [sys.executable, str(validator), "--work-root", str(work_root), "--cloud", cloud],
        cwd=str(work_root),
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return normalize_findings(
            {
                "authored": True,
                "findings": [
                    {
                        "control_id": "validator_exec_failed",
                        "nile_priority": 1,
                        "blocks_commit": True,
                        "message": (proc.stderr or proc.stdout or "validator exited non-zero")[:2000],
                    }
                ],
            },
            cloud,
        )
    try:
        payload = load_validator_payload(artifacts, proc.stdout)
    except json.JSONDecodeError as exc:
        return normalize_findings(
            {
                "authored": True,
                "findings": [
                    {
                        "control_id": "validator_output_invalid",
                        "nile_priority": 1,
                        "blocks_commit": True,
                        "message": f"validator JSON invalid: {exc}",
                    }
                ],
            },
            cloud,
        )
    findings = normalize_findings(payload, cloud)
    if not validator_is_authored(validator):
        findings["authored"] = False
        if not any(f.get("control_id") == "validator_not_authored" for f in findings["findings"]):
            findings["findings"].append(
                {
                    "resource_address": "",
                    "resource_type": "",
                    "file": str(validator),
                    "decision_path": ["validator_not_authored"],
                    "control_id": "validator_not_authored",
                    "nile_priority": 1,
                    "blocks_commit": True,
                    "autofixed": False,
                    "severity": "blocker",
                    "message": "Validator is still the harness scaffold; author checks from this-run docs.",
                    "evidence_gap": False,
                }
            )
    return findings


def write_exceptions_md(path: Path, findings: dict[str, Any], sha: str) -> None:
    residuals = [f for f in findings.get("findings") or [] if f.get("blocks_commit") and not f.get("autofixed")]
    lines = [
        "# Governance exceptions (residuals)",
        "",
        f"Governance SHA: `{sha}`",
        "",
        "Validation evidence is **not** human approval (PRR Gate 11 / Evidence Schema).",
        "",
    ]
    if not residuals:
        lines.append("_No blocking residuals._")
        lines.append("")
    else:
        for item in residuals:
            lines.append(
                f"- `{item.get('control_id')}` `{item.get('resource_address')}`: {item.get('message')}"
            )
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def build_report(
    *,
    cloud: str,
    source: dict[str, Any],
    inventory: dict[str, Any],
    findings: dict[str, Any],
    iteration: int,
    validator_path: str,
    blocked: str,
) -> dict[str, Any]:
    blocking = [f for f in findings.get("findings") or [] if f.get("blocks_commit")]
    authored = _as_bool(findings.get("authored"))
    conformance_ok = blocked == "" and authored and not blocking
    return {
        "schema": "nile-governance-conformance-report/v1",
        "cloud": cloud,
        "governance_repo": source.get("repo"),
        "governance_ref": source.get("ref"),
        "governance_commit_sha": source.get("commit_sha"),
        "iteration": iteration,
        "validator_path": validator_path,
        "resource_count": inventory.get("resource_count") or len(inventory.get("resources") or []),
        "finding_count": len(findings.get("findings") or []),
        "blocking_count": len(blocking),
        "authored": authored,
        "conformance_ok": conformance_ok,
        "blocked": blocked,
        "generated_at": utc_now(),
    }


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def next_iteration(report_path: Path) -> int:
    if not report_path.is_file():
        return 1
    try:
        prev = json.loads(report_path.read_text(encoding="utf-8"))
        return int(prev.get("iteration") or 0) + 1
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        return 1


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Nile living-governance harness (no frozen control catalog).")
    parser.add_argument("--work-root", required=True)
    parser.add_argument("--cloud", required=True, choices=("azure", "gcp"))
    parser.add_argument("--refresh", action="store_true", help="Clone/fetch living governance docs.")
    parser.add_argument("--inventory", action="store_true", help="Write resource-inventory.json.")
    parser.add_argument("--seed-scaffold", action="store_true", help="Write validator scaffold if missing.")
    parser.add_argument("--run-validator", action="store_true", help="Execute the agent-authored validator.")
    parser.add_argument(
        "--all",
        action="store_true",
        help="refresh + inventory + seed-if-missing + run validator if present.",
    )
    parser.add_argument("--repo", default=os.environ.get("NILE_GOVERNANCE_REPO", DEFAULT_GOVERNANCE_REPO))
    parser.add_argument("--ref", default=os.environ.get("NILE_GOVERNANCE_REF", DEFAULT_GOVERNANCE_REF))
    parser.add_argument(
        "--governance-dir",
        default="",
        help="Use an already-fetched tree instead of cloning (tests / offline).",
    )
    parser.add_argument(
        "--validator",
        default="",
        help="Path to governance-validator.py (default: {cloud}/artifacts/governance-validator.py).",
    )
    return parser.parse_args(argv)


def run(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    work_root = Path(args.work_root).resolve()
    cloud = args.cloud
    artifacts = work_root / cloud / "artifacts"
    artifacts.mkdir(parents=True, exist_ok=True)
    do_refresh = args.all or args.refresh
    do_inventory = args.all or args.inventory
    do_seed = args.all or args.seed_scaffold
    do_run = args.all or args.run_validator

    blocked = ""
    source: dict[str, Any] = {}
    if do_refresh:
        try:
            source_dir = Path(args.governance_dir).resolve() if args.governance_dir else None
            source = refresh_governance(work_root, args.repo, args.ref, source_dir=source_dir)
        except GovernanceDocsUnavailable as exc:
            blocked = "governance_docs_unavailable"
            source = {
                "schema": "nile-governance-source/v1",
                "repo": args.repo,
                "ref": args.ref,
                "commit_sha": "",
                "fetched_at": utc_now(),
                "error": str(exc),
            }
        write_json(artifacts / "governance-source.json", source)

    inventory = {"schema": "nile-resource-inventory/v1", "cloud": cloud, "resources": []}
    if do_inventory:
        inventory = inventory_resources(work_root / cloud / "groups", cloud)
        write_json(artifacts / "resource-inventory.json", inventory)

    validator_path = Path(args.validator) if args.validator else artifacts / "governance-validator.py"
    if do_seed:
        validator_path = seed_validator_scaffold(artifacts)

    findings = {
        "schema": "nile-governance-findings/v1",
        "cloud": cloud,
        "authored": False,
        "findings": [],
        "resources": [],
    }
    if do_run and blocked == "":
        if not validator_path.is_file():
            validator_path = seed_validator_scaffold(artifacts)
        findings = run_validator(validator_path, work_root, cloud)
        write_json(artifacts / "governance-findings.json", findings)

    report_path = artifacts / "governance-conformance-report.json"
    iteration = next_iteration(report_path)
    report = build_report(
        cloud=cloud,
        source=source or {"commit_sha": "", "repo": args.repo, "ref": args.ref},
        inventory=inventory,
        findings=findings,
        iteration=iteration,
        validator_path=str(validator_path),
        blocked=blocked,
    )
    write_json(report_path, report)
    write_exceptions_md(
        artifacts / "governance-exceptions.md",
        findings,
        str((source or {}).get("commit_sha") or ""),
    )
    print(json.dumps(report))
    if blocked:
        return 2
    if not report.get("conformance_ok"):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(run())
