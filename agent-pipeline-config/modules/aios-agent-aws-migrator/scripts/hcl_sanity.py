#!/usr/bin/env python3
"""HCL sanity gates for AWS hydrate and destination validate stages.

Source groups must have every imports.tf `to = TYPE.NAME` address present as a
`resource "TYPE" "NAME"` block (typically in generated.tf). Destination groups
must contain at least one resource block before init/validate/plan can pass.

When ``tofu plan -generate-config-out`` cannot reach live AWS (deleted objects)
or OpenTofu refuses to emit config for in-state resources, ``emit-from-state``
writes review-candidate resource stubs from terraform.tfstate so hydrate can
still prove import↔resource parity and ``plan -refresh=false`` zero-diff.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

IMPORT_TO_RE = re.compile(r"^\s*to\s*=\s*([A-Za-z0-9_.-]+)\s*$", re.MULTILINE)
RESOURCE_RE = re.compile(
    r'^\s*resource\s+"([^"]+)"\s+"([^"]+)"\s*\{',
    re.MULTILINE,
)

# Attributes that are always provider-computed / identity and must not be set.
ALWAYS_SKIP_ATTRS = frozenset(
    {
        "id",
        "arn",
        "unique_id",
        "owner_id",
        "primary_network_interface_id",
        "default_network_acl_id",
        "default_route_table_id",
        "default_security_group_id",
        "main_route_table_id",
        "owner_id",
        "partition",
        "zone_id",  # often computed on route53; keep if present as optional later
    }
)


def import_addresses(imports_tf: Path) -> set[str]:
    text = imports_tf.read_text(encoding="utf-8", errors="replace")
    return set(IMPORT_TO_RE.findall(text))


def resource_addresses(group_dir: Path) -> set[str]:
    addrs: set[str] = set()
    for tf_path in sorted(group_dir.glob("*.tf")):
        text = tf_path.read_text(encoding="utf-8", errors="replace")
        for typ, name in RESOURCE_RE.findall(text):
            addrs.add(f"{typ}.{name}")
    return addrs


def check_source_parity(group_dir: Path) -> int:
    group_dir = group_dir.resolve()
    imports_tf = group_dir / "imports.tf"
    if not imports_tf.is_file():
        print(f"parity_fail=missing_imports group={group_dir.name}", file=sys.stderr)
        return 1

    expected = import_addresses(imports_tf)
    if not expected:
        print(f"parity_ok=empty_imports group={group_dir.name}")
        return 0

    generated = group_dir / "generated.tf"
    if not generated.is_file():
        print(
            f"parity_fail=missing_generated_tf group={group_dir.name} imports={len(expected)}",
            file=sys.stderr,
        )
        return 1

    have = resource_addresses(group_dir)
    missing = sorted(expected - have)
    if missing:
        print(
            f"parity_fail=missing_resources group={group_dir.name} "
            f"missing={len(missing)} imports={len(expected)} resources={len(have)}",
            file=sys.stderr,
        )
        for addr in missing[:25]:
            print(f"  missing={addr}", file=sys.stderr)
        return 1

    print(
        f"parity_ok group={group_dir.name} imports={len(expected)} resources={len(have)}"
    )
    return 0


def check_destination_resources(group_dir: Path) -> int:
    group_dir = group_dir.resolve()
    have = resource_addresses(group_dir)
    if not have:
        print(f"destination_fail=no_resources group={group_dir.name}", file=sys.stderr)
        return 1
    print(f"destination_ok group={group_dir.name} resources={len(have)}")
    return 0


def _hcl_escape(value: str) -> str:
    return json.dumps(value)


def _render_value(value: Any, indent: int) -> str:
    pad = " " * indent
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, str):
        return _hcl_escape(value)
    if isinstance(value, list):
        if not value:
            return "[]"
        # Keep lists of scalars inline-ish; nested objects as multi-line.
        if all(not isinstance(x, (dict, list)) for x in value):
            inner = ", ".join(_render_value(x, indent) for x in value)
            return f"[{inner}]"
        lines = ["["]
        for item in value:
            lines.append(f"{pad}  {_render_value(item, indent + 2)},")
        lines.append(f"{pad}]")
        return "\n".join(lines)
    if isinstance(value, dict):
        if not value:
            return "{}"
        lines = ["{"]
        for key in sorted(value.keys()):
            lines.append(
                f'{pad}  {_hcl_escape(str(key))} = {_render_value(value[key], indent + 2)}'
            )
        lines.append(f"{pad}}}")
        return "\n".join(lines)
    return _hcl_escape(str(value))


def _should_skip_attr(key: str, value: Any) -> bool:
    if key in ALWAYS_SKIP_ATTRS:
        return True
    if key.endswith("_id") and key not in {
        "vpc_id",
        "subnet_id",
        "route_table_id",
        "network_interface_id",
        "security_group_id",
        "iam_instance_profile_id",
        "role_id",
        "policy_id",
        "allocation_id",
        "association_id",
        "hosted_zone_id",
        "instance_id",
        "volume_id",
        "snapshot_id",
        "key_pair_id",
        "launch_template_id",
        "target_group_arn",
    }:
        # Many *_id fields are computed; keep common relational ones.
        if key in {"account_id", "user_id", "caller_id"}:
            return True
    if value is None:
        return True
    if value == "" or value == [] or value == {}:
        return True
    # Provider rejects simultaneous name + name_prefix; prefer name.
    return False


def _render_route_blocks(routes: Any, indent: int = 2) -> str:
    """Render state route list as nested route { } blocks for aws_route_table."""
    if not isinstance(routes, list):
        return ""
    pad = " " * indent
    skip_empty = {
        "carrier_gateway_id",
        "core_network_arn",
        "destination_prefix_list_id",
        "egress_only_gateway_id",
        "gateway_id",
        "ipv6_cidr_block",
        "local_gateway_id",
        "nat_gateway_id",
        "network_interface_id",
        "odb_network_arn",
        "outpost_arn",
        "transit_gateway_id",
        "vpc_endpoint_id",
        "vpc_peering_connection_id",
    }
    chunks: list[str] = []
    for item in routes:
        if not isinstance(item, dict):
            continue
        body: list[str] = []
        for key in sorted(item.keys()):
            value = item[key]
            if value is None or value == "" or value == [] or value == {}:
                continue
            if key in skip_empty and value in ("", None):
                continue
            body.append(f"{pad}  {key} = {_render_value(value, indent + 2)}")
        if not body:
            continue
        chunks.append(f"{pad}route {{")
        chunks.extend(body)
        chunks.append(f"{pad}}}")
    return "\n".join(chunks)


def _attrs_for_resource(attrs: dict[str, Any], *, resource_type: str = "") -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in attrs.items():
        if _should_skip_attr(key, value):
            continue
        out[key] = value
    if "name" in out and "name_prefix" in out:
        out.pop("name_prefix", None)
    if resource_type == "aws_api_gateway_resource":
        # path is computed; parent_id + path_part + rest_api_id are required.
        # path_part may be "" for the root resource — still emit it.
        out.pop("path", None)
        if "path_part" in attrs:
            out["path_part"] = attrs["path_part"] if attrs["path_part"] is not None else ""
        if attrs.get("parent_id"):
            out["parent_id"] = attrs["parent_id"]
        if attrs.get("rest_api_id"):
            out["rest_api_id"] = attrs["rest_api_id"]
    if resource_type == "aws_route_table":
        # Handled as nested blocks in emit_from_state.
        out.pop("route", None)
    return out


def _load_state_resources(state_path: Path) -> dict[str, dict[str, Any]]:
    """Return map address -> attributes for managed resources."""
    state = json.loads(state_path.read_text(encoding="utf-8"))
    out: dict[str, dict[str, Any]] = {}
    for resource in state.get("resources") or []:
        if resource.get("mode") != "managed":
            continue
        rtype = str(resource.get("type") or "")
        name = str(resource.get("name") or "")
        if not rtype or not name:
            continue
        instances = resource.get("instances") or []
        if not instances:
            continue
        attrs = instances[0].get("attributes") or {}
        if not isinstance(attrs, dict):
            continue
        out[f"{rtype}.{name}"] = attrs
    return out


def emit_from_state(group_dir: Path, *, only_missing: bool = True) -> int:
    """Write/merge generated.tf resource stubs from terraform.tfstate."""
    group_dir = group_dir.resolve()
    state_path = group_dir / "terraform.tfstate"
    imports_tf = group_dir / "imports.tf"
    gen_tf = group_dir / "generated.tf"

    if not state_path.is_file():
        print(f"emit_fail=missing_state group={group_dir.name}", file=sys.stderr)
        return 1

    expected = import_addresses(imports_tf) if imports_tf.is_file() else set()
    have = resource_addresses(group_dir)
    state_map = _load_state_resources(state_path)

    targets = sorted(expected) if expected else sorted(state_map)
    if only_missing and expected:
        targets = [addr for addr in targets if addr not in have]
    if not targets:
        print(f"emit_ok=noop group={group_dir.name} have={len(have)}")
        return 0

    blocks: list[str] = []
    missing_state: list[str] = []
    for addr in targets:
        attrs = state_map.get(addr)
        if attrs is None:
            missing_state.append(addr)
            continue
        typ, _, name = addr.partition(".")
        cleaned = _attrs_for_resource(attrs, resource_type=typ)
        lines = [
            f'resource "{typ}" "{name}" {{',
            "  # Emitted from terraform.tfstate (hydrate fallback when live generate-config-out fails).",
        ]
        for key in sorted(cleaned):
            rendered = _render_value(cleaned[key], 2)
            if "\n" in rendered:
                lines.append(f"  {key} = {rendered}")
            else:
                lines.append(f"  {key} = {rendered}")
        if typ == "aws_route_table" and isinstance(attrs.get("route"), list):
            route_hcl = _render_route_blocks(attrs.get("route"), 2)
            if route_hcl:
                lines.append(route_hcl)
        lines.append("}")
        lines.append("")
        blocks.append("\n".join(lines))

    if missing_state and not blocks:
        print(
            f"emit_fail=no_state_attrs group={group_dir.name} missing={len(missing_state)}",
            file=sys.stderr,
        )
        for addr in missing_state[:20]:
            print(f"  missing_state={addr}", file=sys.stderr)
        return 1

    header = (
        "# GENERATED — review-candidate reverse IaC from group terraform.tfstate\n"
        "# Source: hydrate emit-from-state fallback (deleted remotes / tofu generate gaps)\n\n"
    )
    existing = ""
    if gen_tf.is_file() and only_missing:
        existing = gen_tf.read_text(encoding="utf-8", errors="replace")
        if existing and not existing.endswith("\n"):
            existing += "\n"
        if not existing.lstrip().startswith("#"):
            existing = header + existing
        gen_tf.write_text(existing + "\n".join(blocks), encoding="utf-8")
    else:
        gen_tf.write_text(header + "\n".join(blocks), encoding="utf-8")

    print(
        f"emit_ok group={group_dir.name} wrote={len(blocks)} "
        f"missing_state={len(missing_state)} path={gen_tf}"
    )
    return 0


def parse_tofu_errors(log_text: str, *, group_id: str = "", log_path: str = "") -> list[dict[str, Any]]:
    """Parse OpenTofu init/validate/plan errors into surgical fix targets.

    Each target names a resource address (when present), attribute, error kind,
    and a short suggested action the agent or pack can take.
    """
    targets: list[dict[str, Any]] = []
    # Split on blank-line-bounded Error: blocks when possible.
    chunks = re.split(r"(?=^Error:)", log_text, flags=re.M)
    for chunk in chunks:
        chunk = chunk.strip()
        if not chunk.startswith("Error:"):
            continue
        kind_match = re.match(r"Error:\s*([^\n]+)", chunk)
        kind = (kind_match.group(1).strip() if kind_match else "unknown")[:120]
        addr = ""
        with_m = re.search(r"\bwith\s+([A-Za-z0-9_]+\.[A-Za-z0-9_-]+)", chunk)
        if with_m:
            addr = with_m.group(1)
        else:
            on_m = re.search(
                r'in resource\s+"([^"]+)"\s+"([^"]+)"',
                chunk,
            )
            if on_m:
                addr = f"{on_m.group(1)}.{on_m.group(2)}"
        attr = ""
        attr_m = re.search(
            r'(?:An argument named|Unsupported argument|"?)([A-Za-z0-9_]+)"?'
            r"(?:\":)?\s*(?:is not expected|conflicts with|is required)",
            chunk,
            re.I,
        )
        if attr_m:
            attr = attr_m.group(1)
        else:
            quoted = re.search(r'"([A-Za-z0-9_]+)":\s*conflicts with', chunk)
            if quoted:
                attr = quoted.group(1)
            else:
                # Line form:   12:   path_part = "x"
                line_attr = re.search(r"^\s*\d+:\s*([A-Za-z0-9_]+)\s*=", chunk, re.M)
                if line_attr:
                    attr = line_attr.group(1)

        suggestion = "inspect_resource_block"
        kind_l = kind.lower()
        if "target generated file already exists" in kind_l:
            suggestion = "rename_or_remove_generated_tf_then_regenerate"
        elif "unsupported argument" in kind_l or "not expected here" in chunk.lower():
            suggestion = "drop_attribute" if attr else "fix_hcl_structure"
        elif "invalid argument name" in kind_l:
            suggestion = "drop_list_attribute_or_rewrite_as_block" if attr else "rewrite_list_as_nested_blocks"
        elif "conflicts with" in kind_l or "conflicting configuration" in kind_l:
            suggestion = "drop_conflicting_attribute" if attr else "resolve_conflict"
        elif "missing required argument" in kind_l:
            suggestion = "add_required_attribute"
        elif "incorrect attribute value type" in kind_l:
            suggestion = "rewrite_attribute_as_block_or_object"
        elif "argument or block definition required" in kind_l:
            suggestion = "repair_broken_resource_block"
        elif "unconfigurable attribute" in kind_l:
            suggestion = "drop_computed_attribute" if attr else "drop_computed_attributes"
        elif "resource has no configuration" in kind_l:
            suggestion = "emit_or_restore_resource_block"

        targets.append(
            {
                "group_id": group_id,
                "address": addr,
                "attribute": attr,
                "error": kind,
                "suggestion": suggestion,
                "log_path": log_path,
                "excerpt": " ".join(chunk.split())[:280],
            }
        )
    return targets


def apply_surgical_fixes(group_dir: Path, targets: list[dict[str, Any]]) -> int:
    """Drop attributes called out by parse_tofu_errors when suggestion is drop_*.

    Returns the number of attribute lines removed. Structural repairs
    (broken blocks, wrong types) stay for the agent.
    """
    group_dir = group_dir.resolve()
    gen_tf = group_dir / "generated.tf"
    if not gen_tf.is_file() or not targets:
        return 0

    droppable = {
        "drop_attribute",
        "drop_conflicting_attribute",
        "drop_computed_attribute",
    }
    # address -> set of attrs to drop (empty attr means skip)
    by_addr: dict[str, set[str]] = {}
    global_attrs: set[str] = set()
    for t in targets:
        if t.get("suggestion") not in droppable:
            continue
        attr = str(t.get("attribute") or "").strip()
        if not attr:
            continue
        addr = str(t.get("address") or "").strip()
        if addr:
            by_addr.setdefault(addr, set()).add(attr)
        else:
            global_attrs.add(attr)

    if not by_addr and not global_attrs:
        return 0

    text = gen_tf.read_text(encoding="utf-8")
    parts = re.split(r'(?=resource\s+"[^"]+"\s+"[^"]+"\s*\{)', text)
    removed = 0
    out: list[str] = []
    for part in parts:
        m = re.match(r'resource\s+"([^"]+)"\s+"([^"]+)"\s*\{', part)
        if not m:
            out.append(part)
            continue
        addr = f"{m.group(1)}.{m.group(2)}"
        attrs = set(by_addr.get(addr, set())) | global_attrs
        if not attrs:
            out.append(part)
            continue
        new_part = part
        for attr in attrs:
            new_part, n = re.subn(
                rf"^\s*{re.escape(attr)}\s*=.*\n",
                "",
                new_part,
                flags=re.M,
            )
            removed += n
        out.append(new_part)
    if removed:
        gen_tf.write_text("".join(out), encoding="utf-8")
    print(f"surgical_fixes group={group_dir.name} removed_attrs={removed}")
    return removed


def write_fix_report(
    report_path: Path,
    targets: list[dict[str, Any]],
    *,
    group_id: str = "",
) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema": "nile-hcl-fix-targets/v1",
        "group_id": group_id,
        "target_count": len(targets),
        "targets": targets,
    }
    report_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    source = sub.add_parser("source-parity", help="Import ↔ resource parity for AWS groups")
    source.add_argument("group_dir", type=Path)

    dest = sub.add_parser(
        "destination-resources",
        help="Require at least one resource block in a destination group",
    )
    dest.add_argument("group_dir", type=Path)

    emit = sub.add_parser(
        "emit-from-state",
        help="Write generated.tf stubs from terraform.tfstate for missing imports",
    )
    emit.add_argument("group_dir", type=Path)
    emit.add_argument(
        "--replace",
        action="store_true",
        help="Replace generated.tf entirely instead of appending missing addresses",
    )

    parse = sub.add_parser(
        "parse-tofu-errors",
        help="Parse tofu init/validate logs into surgical fix targets JSON",
    )
    parse.add_argument("log_file", type=Path)
    parse.add_argument("--group-id", default="")
    parse.add_argument("--out", type=Path, default=None)

    fix = sub.add_parser(
        "apply-surgical-fixes",
        help="Drop droppable attributes named in a fix-targets JSON file",
    )
    fix.add_argument("group_dir", type=Path)
    fix.add_argument("targets_json", type=Path)

    args = parser.parse_args(argv)
    if args.command == "source-parity":
        return check_source_parity(args.group_dir)
    if args.command == "destination-resources":
        return check_destination_resources(args.group_dir)
    if args.command == "emit-from-state":
        return emit_from_state(args.group_dir, only_missing=not args.replace)
    if args.command == "parse-tofu-errors":
        text = args.log_file.read_text(encoding="utf-8", errors="replace")
        targets = parse_tofu_errors(
            text, group_id=args.group_id, log_path=str(args.log_file)
        )
        if args.out:
            write_fix_report(args.out, targets, group_id=args.group_id)
        print(json.dumps(targets))
        return 0 if targets else 1
    if args.command == "apply-surgical-fixes":
        payload = json.loads(args.targets_json.read_text(encoding="utf-8"))
        targets = payload.get("targets") if isinstance(payload, dict) else payload
        if not isinstance(targets, list):
            print("surgical_fail=bad_targets_json", file=sys.stderr)
            return 1
        removed = apply_surgical_fixes(args.group_dir, targets)
        return 0 if removed >= 0 else 1
    parser.error(f"unknown command {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
