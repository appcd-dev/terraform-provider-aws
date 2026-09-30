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
    listed = aggregate.get("listed")
    imported = aggregate.get("imported")
    coverage_percent = round(100 * imported / listed, 1) if listed and imported is not None else None
    scan_partial = bool(aggregate) and any(aggregate.get(key, 0) for key in (
        "import_state_skipped", "read_skipped", "read_failed", "throttled_types"
    ))
    evidence_gaps: list[dict[str, Any]] = []
    if not identity.get("Account"):
        evidence_gaps.append({"code": "aws_account_identity_missing", "observed": None})
    if not region:
        evidence_gaps.append({"code": "aws_region_missing", "observed": None})
    if not log_path or not Path(log_path).is_file():
        evidence_gaps.append({"code": "cloud2code_log_missing", "observed": None})
    if not aggregate:
        evidence_gaps.append({"code": "aggregate_integrity_counters_missing", "observed": None})
    if not type_stats:
        evidence_gaps.append({"code": "per_type_summaries_missing", "observed": None})
    if not state_path or not Path(state_path).is_file():
        evidence_gaps.append({"code": "terraform_state_missing", "observed": None})
    elif not state_valid:
        evidence_gaps.append({"code": "terraform_state_invalid", "observed": state_path})
    if aggregate_permission_skips and exact_warning_coverage is not None and exact_warning_coverage < 100:
        evidence_gaps.append({
            "code": "permission_warning_detail_incomplete",
            "aggregate_read_importstate_skips": aggregate_permission_skips,
            "individual_warning_records": individual_read_permission_events,
            "warning_detail_coverage_percent": exact_warning_coverage,
            "skips_without_individual_reason": aggregate_permission_skips - individual_read_permission_events,
        })
    resources_phase_total = aggregate.get("permission_skipped_resources", 0)
    if aggregate and individual_resources_permission_events != resources_phase_total:
        evidence_gaps.append({
            "code": "resources_phase_warning_counter_mismatch",
            "individual_warning_records": individual_resources_permission_events,
            "cloud2code_summary_count": resources_phase_total,
        })
    mismatches = [key for key, value in checks.items() if value == "mismatch"]
    if mismatches:
        evidence_gaps.append({"code": "evidence_counter_mismatch", "checks": mismatches})
    if aggregate and aggregate.get("listed", 0) > aggregate.get("imported", 0) and not any(
        aggregate.get(k, 0) for k in ("import_state_skipped", "read_skipped", "read_failed")
    ):
        evidence_gaps.append({"code": "listed_imported_delta_unaccounted", "listed": aggregate["listed"], "imported": aggregate["imported"]})

    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "state_path_available": bool(state_path and Path(state_path).is_file()),
        "state_file_valid": state_valid,
        "aws_account_id": identity.get("Account", "unknown"),
        "aws_caller_arn": identity.get("Arn", "unknown"),
        "aws_region": region or "unknown",
        "scan_integrity": aggregate,
        "scan_partial": scan_partial,
        "coverage_percent": coverage_percent,
        "partial_scan_failure_accepted": bool(_read_json(str(Path(log_path).parent.parent / "notes.json")).get("cloud2code_partial_failure_accepted") == "true") if log_path else False,
        "partial_scan_min_coverage_percent": _read_json(str(Path(log_path).parent.parent / "notes.json")).get("cloud2code_min_coverage_percent", "90") if log_path else "90",
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
        "evidence_gaps": evidence_gaps,
        "data_sources": {
            "resource_types_found": "managed resources in the generated Terraform state",
            "scan_integrity": "Cloud2Code aggregate log counter",
            "resource_types_scanned": "Cloud2Code per-type progress summaries",
            "permission_warning_events": "individual structured permission_skipped log records",
        },
    }


def render_markdown(report: dict[str, Any]) -> str:
    integrity = report.get("scan_integrity") or {}
    lines = [
        "## AWS scan inventory", "",
        f"- **Account:** `{report.get('aws_account_id', 'unknown')}`",
        f"- **Caller ARN:** `{report.get('aws_caller_arn', 'unknown')}`",
        f"- **Region:** `{report.get('aws_region', 'unknown')}`",
        "",
        "### Scan totals (Cloud2Code aggregate log counters)", "",
        f"- **Coverage:** {report.get('coverage_percent', 'unknown')}% imported/listed",
        f"- **Partial scan:** {'yes' if report.get('scan_partial') else 'no/unknown'}",
        f"- **Partial failure accepted for continuation:** {'yes' if report.get('partial_scan_failure_accepted') else 'no'} (minimum coverage: {report.get('partial_scan_min_coverage_percent', 'unknown')}%)",
        "",
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
        f"Read/ImportState permission-skip counters: {report.get('aggregate_permission_skips', 0)}; individual warning records: {report.get('individual_read_permission_warning_events', 0)}; warning-record/skip-counter ratio: {report.get('permission_warning_detail_coverage_percent', 'unknown')}%.",
        f"Resources/list permission-warning records: {report.get('individual_resources_permission_warning_events', 0)}; Cloud2Code Resources phase counter: {report.get('permission_skip_totals', {}).get('resources', 'unknown')}.",
        "",
        "### Resource types found in Terraform state (observed)", "",
        "| Resource type | Imported resources |", "| --- | ---: |",
    ])
    found = report.get("resource_types_found") or []
    lines.extend([f"| `{item['resource_type']}` | {item['resource_count']} |" for item in found] or ["| _No resource counts available_ | unknown |"])
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
    lines.extend(["", "### Permission warning records", ""])
    skipped = report.get("resource_types_skipped") or []
    if skipped:
        lines.extend(["| Resource type | Phase | Warning records observed (not total skipped count) | Evidence-based reason | AWS API action |", "| --- | --- | ---: | --- | --- |"])
        for item in skipped:
            for detail in item.get("reasons", []):
                lines.append(f"| `{item['resource_type']}` | {detail.get('phase', 'unknown')} | {detail.get('count', 'unknown')} | {detail.get('reason', 'Unknown')} | {', '.join(f'`{a}`' for a in detail.get('aws_api_operations', [])) or 'Not present in retained log'} |")
    else:
        lines.append("No per-type permission warning records were parsed from the retained log.")
    if report.get("partial_scan_failure_accepted"):
        lines.extend(["", "> **Partial scan:** Cloud2Code exited nonzero due to read failures, but a validated state met the configured coverage floor. Review missing resources before using this state as complete inventory."])
    if report.get("evidence_gaps"):
        lines.extend(["", "### Evidence gaps / counter differences", "", "```json", json.dumps(report["evidence_gaps"], indent=2, sort_keys=True), "```"])
    if report.get("unattributed_skipped_events"):
        lines.extend(["", "Unattributed skip warning events:"])
        for detail in report["unattributed_skipped_events"]:
            actions = ", ".join(f"`{a}`" for a in detail["aws_api_operations"]) or "no action identified"
            lines.append(f"- {detail['count']} event(s), phase `{detail['phase']}`: {detail['reason']} ({actions})")
    lines.extend(["", "Machine-readable report: [`cloud2code-scan-report.json`](cloud2code-scan-report.json).", ""])
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
