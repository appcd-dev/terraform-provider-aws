#!/usr/bin/env python3
"""Build a durable AWS discovery report from Cloud2Code's scan log and tfstate.

The report deliberately omits resource IDs and raw error text. It groups denied
reads by Terraform type, API phase, classified reason, and AWS action, while
making unclassified/missing detail explicit rather than guessing.
"""
from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

COUNTER_RE = re.compile(r"\b(listed|imported|import_state_skipped|read_skipped|read_failed|throttled_types)=(\d+)\b")
API_OPERATION_RE = re.compile(r"operation error\s+([^:,]+):\s*([A-Za-z][A-Za-z0-9*]+)", re.IGNORECASE)
DENIED_ACTION_RE = re.compile(r"(?:not authorized to perform|perform):\s*([a-z0-9-]+:[A-Za-z0-9*]+)", re.IGNORECASE)
TYPE_RE = re.compile(r"\baws_[a-z0-9_]+\b", re.IGNORECASE)
ACTION_RE = re.compile(r"\b([a-z][a-z0-9-]*:[A-Za-z][A-Za-z0-9*]+)\b", re.IGNORECASE)
TYPE_SUMMARY_RE = re.compile(
    r"Scanning\s+(aws_[a-z0-9_]+)\s+\[\d+/(\d+)\]\s+Done!\s+"
    r"\(imported=(\d+)\s+skipped=(\d+)\s+permission_skipped=(\d+)\s+"
    r"filtered=(\d+)\s+nil_state=(\d+)\s+read_failed=(\d+)\)", re.IGNORECASE
)
PERMISSION_TOTALS_RE = re.compile(r"permission skips:\s+ImportState=(\d+)\s+Resources=(\d+)\s+Read=(\d+)", re.IGNORECASE)


def _read_json(path: str | None) -> dict[str, Any]:
    if not path:
        return {}
    try:
        result = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return result if isinstance(result, dict) else {}


def _state_inventory(path: str | None) -> tuple[bool, dict[str, int]]:
    if not path:
        return False, {}
    try:
        state = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False, {}
    if not isinstance(state, dict) or not isinstance(state.get("resources"), list):
        return False, {}
    counts: Counter[str] = Counter()
    for resource in state.get("resources", []):
        if not isinstance(resource, dict) or resource.get("mode", "managed") != "managed":
            continue
        resource_type = resource.get("type")
        if not isinstance(resource_type, str) or not resource_type.startswith("aws_"):
            continue
        instances = resource.get("instances", [])
        counts[resource_type] += len(instances) if isinstance(instances, list) else 0
    return True, dict(sorted(counts.items()))


def _api_actions(message: str) -> list[str]:
    actions = set(DENIED_ACTION_RE.findall(message))
    if not actions:
        for service, operation in API_OPERATION_RE.findall(message):
            actions.add(f"{service.lower()}:{operation}")
    if not actions:
        known_services = {"iam", "s3", "ec2", "rds", "lambda", "sns", "sqs", "elasticloadbalancing", "cloudfront", "efs", "kafka", "glue", "mq", "mediastore"}
        for action in ACTION_RE.findall(message):
            service, operation = action.split(":", 1)
            if service.lower() in known_services:
                actions.add(f"{service.lower()}:{operation}")
    return sorted(actions)


def _classify_reason(message: str) -> str:
    lower = message.lower()
    if "accessdenied" in lower or "access denied" in lower or "not authorized" in lower or "unauthorized" in lower:
        return "AWS authorization/permission denied"
    if "forbidden" in lower:
        return "AWS API returned Forbidden"
    if "throttl" in lower or "rate exceeded" in lower or "ratelimit" in lower:
        return "AWS API throttling/rate limit"
    if "unsupported" in lower or "not supported" in lower:
        return "Cloud2Code does not support this resource type/operation"
    return "Cloud2Code reported a skipped/failed read; exact cause not classified"


def _parse_log(path: str | None) -> tuple[dict[str, dict[str, int]], dict[str, Counter[tuple[str, str, tuple[str, ...]]]], dict[str, int], dict[str, int]]:
    type_stats: dict[str, dict[str, int]] = {}
    reason_counts: dict[str, Counter[tuple[str, str, tuple[str, ...]]]] = {}
    aggregate: dict[str, int] = {}
    phase_totals: dict[str, int] = {}
    event_unattributed: Counter[tuple[str, str, tuple[str, ...]]] = Counter()
    if not path:
        return type_stats, reason_counts, aggregate, {}
    try:
        # Terracognita progress updates use CRs and Cloud2Code logs JSONL.
        lines = Path(path).read_text(encoding="utf-8", errors="replace").replace("\r", "\n").splitlines()
    except OSError:
        return type_stats, reason_counts, aggregate, {}

    for line in lines:
        if "scan integrity:" in line:
            aggregate = {key: int(value) for key, value in COUNTER_RE.findall(line)}
            continue
        phase_match = PERMISSION_TOTALS_RE.search(line)
        if phase_match:
            phase_totals = {"import_state": int(phase_match.group(1)), "resources": int(phase_match.group(2)), "read": int(phase_match.group(3))}
            continue
        type_summary = TYPE_SUMMARY_RE.search(line)
        if type_summary:
            resource_type, listed, imported, skipped, permission_skipped, filtered, nil_state, read_failed = type_summary.groups()
            type_stats[resource_type.lower()] = {
                "listed": int(listed), "imported": int(imported), "skipped": int(skipped),
                "permission_skipped": int(permission_skipped), "filtered": int(filtered),
                "nil_state": int(nil_state), "read_failed": int(read_failed),
            }
            continue

        entry: dict[str, Any] = {}
        try:
            parsed = json.loads(line)
            if isinstance(parsed, dict):
                entry = parsed
        except json.JSONDecodeError:
            pass
        lower = line.lower()
        message = " ".join(str(entry.get(k, "")) for k in ("msg", "error", "message")) or line
        is_skip = entry.get("msg") == "permission_skipped" or "permission skips:" in lower
        if not is_skip:
            continue
        resource_type = str(entry.get("resource_type", "")).lower()
        if not resource_type:
            matches = {value.lower() for value in TYPE_RE.findall(line)}
            resource_type = next(iter(matches)) if len(matches) == 1 else ""
        phase = str(entry.get("phase", "unknown"))
        reason = _classify_reason(message)
        actions = tuple(_api_actions(message))
        detail_key = (phase, reason, actions)
        if resource_type:
            reason_counts.setdefault(resource_type, Counter())[detail_key] += 1
        else:
            event_unattributed[detail_key] += 1

    aggregate.update({f"permission_skipped_{phase}": count for phase, count in phase_totals.items()})
    return type_stats, reason_counts, aggregate, dict(event_unattributed)


def _discover_state_path(output_dir: str | None) -> str | None:
    if not output_dir:
        return None
    root = Path(output_dir)
    if root.is_file():
        return str(root)
    candidates = sorted(root.rglob("*.tfstate")) if root.exists() else []
    return str(candidates[0]) if candidates else None


def build_report(region: str, identity_path: str | None, state_path: str | None, log_path: str | None) -> dict[str, Any]:
    identity = _read_json(identity_path)
    state_valid, found = _state_inventory(state_path)
    type_stats, reason_counts, aggregate, unattributed_events = _parse_log(log_path)
    resource_types = sorted(set(type_stats) | set(reason_counts) | set(found))
    skipped: list[dict[str, Any]] = []
    for resource_type in resource_types:
        stats = type_stats.get(resource_type, {})
        details: list[dict[str, Any]] = []
        for (phase, reason, actions), count in sorted(reason_counts.get(resource_type, Counter()).items()):
            details.append({"phase": phase, "count": count, "reason": reason, "aws_api_operations": list(actions)})
        # Per-type skipped counts are Read/ImportState outcomes. A Resources/list
        # permission warning is a separate enumeration issue and must not be
        # subtracted from the per-type skipped count.
        warning_events = sum(
            count for (phase, _reason, _actions), count in reason_counts.get(resource_type, Counter()).items()
            if phase in ("Read", "ImportState")
        )
        unreported_permission_events = max(0, stats.get("permission_skipped", 0) - warning_events)
        if unreported_permission_events:
            details.append({"phase": "unknown", "count": unreported_permission_events, "reason": "Per-type summary confirms permission-skipped reads, but individual warning records do not provide their specific action/reason", "aws_api_operations": []})
        if stats.get("read_failed", 0):
            details.append({"phase": "Read", "count": stats["read_failed"], "reason": "Cloud2Code counted non-permission read failures; individual cause is unavailable in the retained log", "aws_api_operations": []})
        if stats.get("filtered", 0):
            details.append({"phase": "Read", "count": stats["filtered"], "reason": "Cloud2Code counted filtered resources (for example tag/filter rules); not an AWS permission denial", "aws_api_operations": []})
        if stats.get("nil_state", 0):
            details.append({"phase": "ImportState", "count": stats["nil_state"], "reason": "Cloud2Code returned no importable state for the listed resource", "aws_api_operations": []})
        if stats.get("skipped", 0) and not stats.get("permission_skipped", 0) and not stats.get("filtered", 0) and not stats.get("nil_state", 0) and not details:
            details.append({"phase": "ImportState/Read", "count": stats["skipped"], "reason": "Cloud2Code reported skipped IDs without enough detail to identify the cause", "aws_api_operations": []})
        if details:
            skipped.append({
                "resource_type": resource_type,
                "listed": stats.get("listed"),
                "imported": stats.get("imported", found.get(resource_type, 0)),
                "permission_skipped": stats.get("permission_skipped", 0),
                "skipped": stats.get("skipped", 0),
                "filtered": stats.get("filtered", 0),
                "nil_state": stats.get("nil_state", 0),
                "read_failed": stats.get("read_failed", 0),
                "warning_details_logged": warning_events,
                "reasons": details,
            })

    per_type = list(type_stats.values())
    type_totals = {
        "listed": sum(item.get("listed", 0) for item in per_type),
        "imported": sum(item.get("imported", 0) for item in per_type),
        "permission_skipped": sum(item.get("permission_skipped", 0) for item in per_type),
        "read_failed": sum(item.get("read_failed", 0) for item in per_type),
    }
    aggregate_permission_skips = sum(aggregate.get(k, 0) for k in ("import_state_skipped", "read_skipped"))
    permission_warning_events_by_phase: Counter[str] = Counter()
    for counts in reason_counts.values():
        for (phase, _reason, _actions), count in counts.items():
            permission_warning_events_by_phase[phase] += count
    # The aggregate read_skipped/import_state_skipped counters cover per-ID
    # read/importstate denials. Resources/list warnings are a separate plane.
    individual_read_permission_events = (
        permission_warning_events_by_phase.get("Read", 0)
        + permission_warning_events_by_phase.get("ImportState", 0)
    )
    individual_resources_permission_events = permission_warning_events_by_phase.get("Resources", 0)
    checks: dict[str, str] = {}
    for field in ("listed", "imported"):
        expected = aggregate.get(field)
        observed = type_totals[field]
        checks[f"per_type_{field}_matches_aggregate"] = (
            "unknown" if expected is None or not type_stats else "pass" if expected == observed else "mismatch"
        )
    checks["state_imported_count_matches_aggregate"] = (
        "unknown" if aggregate.get("imported") is None or not state_valid
        else "pass" if sum(found.values()) == aggregate["imported"] else "mismatch"
    )
    checks["per_type_permission_skips_match_aggregate"] = (
        "unknown" if aggregate_permission_skips == 0 or not type_stats
        else "pass" if type_totals["permission_skipped"] == aggregate_permission_skips else "mismatch"
    )
    checks["individual_resources_denials_match_resources_counter"] = (
        "unknown" if not aggregate else
        "pass" if individual_resources_permission_events == aggregate.get("permission_skipped_resources", 0) else "mismatch"
    )
    if type_stats:
        per_type_accounted = sum(
            item.get("imported", 0) + item.get("permission_skipped", 0)
            + item.get("filtered", 0) + item.get("nil_state", 0) + item.get("read_failed", 0)
            for item in per_type
        )
        # Terracognita's `skipped` is a progress/display field which may
        # duplicate permission_skipped; don't add it a second time.
        checks["per_type_listed_outcomes_reconcile"] = (
            "pass" if per_type_accounted == type_totals["listed"] else "mismatch"
        )
    else:
        checks["per_type_listed_outcomes_reconcile"] = "unknown"
    exact_warning_coverage = round(100 * individual_read_permission_events / aggregate_permission_skips, 1) if aggregate_permission_skips else None
    evidence_warnings = []
    if not identity.get("Account"):
        evidence_warnings.append("AWS account identity was not available; account is unknown.")
    if not region:
        evidence_warnings.append("AWS region was not available; region is unknown.")
    if not log_path or not Path(log_path).is_file():
        evidence_warnings.append("Cloud2Code log is missing; skip reasons and type-level log summaries cannot be verified.")
    if not aggregate:
        evidence_warnings.append("Cloud2Code aggregate integrity counters are missing; scan completeness is unknown, not complete.")
    if not type_stats:
        evidence_warnings.append("Per-resource-type summary lines are missing; type-level inventory is unavailable.")
    if not state_path or not Path(state_path).is_file():
        evidence_warnings.append("Terraform state is missing; found-resource counts are unknown.")
    elif not state_valid:
        evidence_warnings.append("Terraform state could not be parsed as a resources inventory; found-resource counts are unknown.")
    if aggregate_permission_skips and exact_warning_coverage is not None and exact_warning_coverage < 100:
        evidence_warnings.append(
            f"Individual Read/ImportState warning details cover {individual_read_permission_events} of {aggregate_permission_skips} aggregate permission skips "
            f"({exact_warning_coverage}%). The remaining {aggregate_permission_skips - individual_read_permission_events} have no specific action/reason in the retained log."
        )
    resources_phase_total = aggregate.get("permission_skipped_resources", 0)
    if aggregate and individual_resources_permission_events != resources_phase_total:
        evidence_warnings.append(
            f"Observed {individual_resources_permission_events} individual Resources/list permission-denial warning records, while Cloud2Code's permission summary reports "
            f"Resources={resources_phase_total}; these counters do not reconcile and the list-phase impact is not fully quantified."
        )
    mismatches = [key for key, value in checks.items() if value == "mismatch"]
    if mismatches:
        evidence_warnings.append("Evidence counters disagree: " + ", ".join(mismatches) + ". Treat the inventory as unresolved until reconciled.")
    if not aggregate:
        completeness = "unknown — aggregate scan counters unavailable"
    elif mismatches:
        completeness = "unresolved — evidence counters disagree"
    elif any(aggregate.get(k, 0) for k in ("import_state_skipped", "read_skipped", "read_failed", "throttled_types")) or individual_read_permission_events or individual_resources_permission_events:
        completeness = "partial — Cloud2Code reported omissions or permission-denial evidence"
    elif aggregate.get("listed", 0) > aggregate.get("imported", 0):
        completeness = "unresolved — listed/imported counts differ without omission details"
        evidence_warnings.append("Listed resources exceed imported resources, but no skip/failure counter explains the difference. Do not assume complete coverage.")
    else:
        completeness = "no omissions reported by available Cloud2Code counters; not independently verified complete"

    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "state_path_available": bool(state_path and Path(state_path).is_file()),
        "state_file_valid": state_valid,
        "aws_account_id": identity.get("Account", "unknown"),
        "aws_caller_arn": identity.get("Arn", "unknown"),
        "aws_region": region or "unknown",
        "completeness": completeness,
        "scan_integrity": aggregate,
        "aggregate_permission_skips": aggregate_permission_skips,
        "per_type_totals": type_totals,
        "verification_checks": checks,
        "individual_permission_warning_events_by_phase": dict(sorted(permission_warning_events_by_phase.items())),
        "individual_read_permission_warning_events": individual_read_permission_events,
        "individual_resources_permission_warning_events": individual_resources_permission_events,
        "permission_warning_detail_coverage_percent": exact_warning_coverage,
        "resource_types_found": [
            {"resource_type": resource_type, "resource_count": count}
            for resource_type, count in sorted(found.items())
        ],
        "resource_types_scanned": [
            {"resource_type": resource_type, **type_stats[resource_type]}
            for resource_type in sorted(type_stats)
        ],
        "permission_skip_totals": {
            phase: aggregate.get(f"permission_skipped_{phase}", 0)
            for phase in ("import_state", "resources", "read")
        },
        "resource_types_skipped": skipped,
        "unattributed_skipped_events": [
            {"phase": phase, "count": count, "reason": reason, "aws_api_operations": list(actions)}
            for (phase, reason, actions), count in sorted(unattributed_events.items())
        ],
        "evidence_warnings": evidence_warnings,
        "limitations": [
            "Resource types found are counted from imported managed resources in generated Terraform state; this is not a claim that AWS inventory is complete.",
            "Exact skipped reasons/actions are reported only when present in retained Cloud2Code warning records; aggregate/type counters do not establish individual causes.",
            "Resource IDs and raw error strings are intentionally omitted from this report.",
        ],
    }


def render_markdown(report: dict[str, Any]) -> str:
    integrity = report.get("scan_integrity") or {}
    completeness = report.get("completeness", "unknown")
    lines = [
        "## AWS scan inventory", "",
        f"- **Account:** `{report.get('aws_account_id', 'unknown')}`",
        f"- **Caller ARN:** `{report.get('aws_caller_arn', 'unknown')}`",
        f"- **Region:** `{report.get('aws_region', 'unknown')}`",
        f"- **Completeness:** **{completeness}**",
        "- **Evidence status:** Observed values below are from the retained Cloud2Code log and generated state; an unknown is not treated as zero or success.", "",
        "### Scan totals (Cloud2Code aggregate log counters)", "",
        "| Listed | Imported | Import-state skipped | Read skipped | Read failed | Throttled types |",
        "| ---: | ---: | ---: | ---: | ---: | ---: |",
        f"| {integrity.get('listed', 'unknown')} | {integrity.get('imported', 'unknown')} | {integrity.get('import_state_skipped', 'unknown')} | {integrity.get('read_skipped', 'unknown')} | {integrity.get('read_failed', 'unknown')} | {integrity.get('throttled_types', 'unknown')} |", "",
        f"Permission skips by phase (Cloud2Code summary): ImportState={report.get('permission_skip_totals', {}).get('import_state', 0)}, Resources/list={report.get('permission_skip_totals', {}).get('resources', 0)}, Read={report.get('permission_skip_totals', {}).get('read', 0)}.", "",
        "### Evidence cross-checks", "",
        "| Check | Result |",
        "| --- | --- |",
    ]
    for check, result in report.get("verification_checks", {}).items():
        lines.append(f"| `{check}` | **{result}** |")
    lines.extend([
        "",
        f"Individual Read/ImportState permission-warning detail: **{report.get('individual_read_permission_warning_events', 0)}** warning records for **{report.get('aggregate_permission_skips', 0)}** aggregate Read/ImportState skips; coverage **{report.get('permission_warning_detail_coverage_percent', 'unknown')}%**.",
        f"Individual Resources/list permission-denial warnings: **{report.get('individual_resources_permission_warning_events', 0)}**; Cloud2Code phase summary: **{report.get('permission_skip_totals', {}).get('resources', 'unknown')}**.",
        "",
        "### Resource types found in Terraform state (observed)", "",
        "| Resource type | Imported resources |", "| --- | ---: |",
    ])
    found = report.get("resource_types_found") or []
    lines.extend([f"| `{item['resource_type']}` | {item['resource_count']} |" for item in found] or ["| _No resource counts available_ | unknown |"])
    if not report.get("state_file_valid"):
        lines.append("State is missing or invalid; the table above is not evidence of an empty AWS account.")
    lines.extend([
        "",
        "### Resource types scanned (Cloud2Code per-type summary)", "",
        "| Resource type | Listed | Imported | Permission skipped | Other skipped | Filtered | Nil state | Read failed |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    scanned = report.get("resource_types_scanned") or []
    lines.extend([
        f"| `{item['resource_type']}` | {item.get('listed', 'unknown')} | {item.get('imported', 'unknown')} | {item.get('permission_skipped', 'unknown')} | {item.get('skipped', 'unknown')} | {item.get('filtered', 'unknown')} | {item.get('nil_state', 'unknown')} | {item.get('read_failed', 'unknown')} |"
        for item in scanned
    ] or ["| _No per-type summary lines available_ | unknown | unknown | unknown | unknown | unknown | unknown | unknown |"])
    lines.extend(["", "### Skips: observed causes vs. unknown causes", ""])
    skipped = report.get("resource_types_skipped") or []
    if skipped:
        lines.extend(["| Resource type | Phase | Warning records observed (not total skipped count) | Evidence-based reason | AWS API action |", "| --- | --- | ---: | --- | --- |"])
        for item in skipped:
            for detail in item.get("reasons", []):
                lines.append(f"| `{item['resource_type']}` | {detail.get('phase', 'unknown')} | {detail.get('count', 'unknown')} | {detail.get('reason', 'Unknown')} | {', '.join(f'`{a}`' for a in detail.get('aws_api_operations', [])) or 'Not present in retained log'} |")
    else:
        lines.append("No per-type skips were identified in the retained log; this is not proof that none occurred unless aggregate counters are present and zero.")
    if report.get("evidence_warnings"):
        lines.extend(["", "### Transparency notes", ""])
        lines.extend(f"- {warning}" for warning in report["evidence_warnings"])
    if report.get("unattributed_skipped_events"):
        lines.extend(["", "Unattributed skip warning events:"])
        for detail in report["unattributed_skipped_events"]:
            actions = ", ".join(f"`{a}`" for a in detail["aws_api_operations"]) or "no action identified"
            lines.append(f"- {detail['count']} event(s), phase `{detail['phase']}`: {detail['reason']} ({actions})")
    lines.extend([
        "",
        "> **Interpretation:** ‘Imported’ means present in this generated state, not all resources in AWS. ‘No omissions reported’ means only that the available Cloud2Code counters reported zero; it does not prove permissions or AWS inventory completeness. Mismatched or missing evidence requires human follow-up.",
        "",
        "Machine-readable evidence and limitations: [`cloud2code-scan-report.json`](cloud2code-scan-report.json).",
        "",
    ])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--region", required=True)
    parser.add_argument("--identity")
    parser.add_argument("--state", help="Terraform state file, or Cloud2Code output directory")
    parser.add_argument("--log")
    parser.add_argument("--json-out", required=True)
    parser.add_argument("--markdown-out", required=True)
    args = parser.parse_args()
    state_path = _discover_state_path(args.state)
    report = build_report(args.region, args.identity, state_path, args.log)
    Path(args.json_out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.json_out).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    Path(args.markdown_out).write_text(render_markdown(report), encoding="utf-8")
    print(f"aws_discovery_scan_report_json={args.json_out}")
    print(f"aws_discovery_scan_report_markdown={args.markdown_out}")
    print(f"aws_account_id={report['aws_account_id']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
