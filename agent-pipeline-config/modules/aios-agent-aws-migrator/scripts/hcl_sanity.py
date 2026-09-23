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
        "partition",
        "zone_id",  # often computed on route53; keep if present as optional later
    }
)

# Writable attrs that hold secrets — emit agent-controlled placeholders for plan.
SECRET_ATTR_KEYS = frozenset(
    {
        "password",
        "master_password",
        "password_wo",
        "secret_string",
        "secret_binary",
        "private_key",
        "private_key_pem",
        "access_key",
        "secret_key",
        "secret_access_key",
        "token",
        "auth_token",
        "api_key",
        "api_token",
        "client_secret",
        "connection_string",
        "primary_connection_string",
        "secondary_connection_string",
    }
)
SECRET_ATTR_SUFFIXES = (
    "_password",
    "_secret",
    "_token",
    "_api_key",
    "_private_key",
)
STUB_SECRET_STRING = "***STUB_SECRET***"
STUB_SECRET_NUMBER = 0
STUB_SECRET_BOOL = False

VARIABLE_BLOCK_RE = re.compile(
    r'variable\s+"([^"]+)"\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}',
    re.MULTILINE | re.DOTALL,
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
        "parent_id",
        "rest_api_id",
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


def _render_nested_object_blocks(
    items: Any,
    block_name: str,
    *,
    indent: int = 2,
    skip_empty_keys: frozenset[str] | None = None,
) -> str:
    """Render a state list-of-objects as repeated nested blocks (not attr = [ {...} ])."""
    if not isinstance(items, list):
        return ""
    pad = " " * indent
    skip_empty_keys = skip_empty_keys or frozenset()
    chunks: list[str] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        body: list[str] = []
        for key in sorted(item.keys()):
            value = item[key]
            if value is None or value == "" or value == [] or value == {}:
                continue
            if key in skip_empty_keys and value in ("", None):
                continue
            # Nested block attrs use bare identifiers, not JSON-quoted keys.
            body.append(f"{pad}  {key} = {_render_value(value, indent + 2)}")
        if not body:
            continue
        chunks.append(f"{pad}{block_name} {{")
        chunks.extend(body)
        chunks.append(f"{pad}}}")
    return "\n".join(chunks)


def _render_route_blocks(routes: Any, indent: int = 2) -> str:
    """Render state route list as nested route { } blocks for aws_route_table."""
    skip_empty = frozenset(
        {
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
    )
    return _render_nested_object_blocks(
        routes, "route", indent=indent, skip_empty_keys=skip_empty
    )


# Resource attrs stored as list-of-objects in state that must emit as nested blocks.
_NESTED_BLOCK_LIST_ATTRS: dict[str, tuple[str, ...]] = {
    "aws_autoscaling_group": ("tag",),
    "aws_ecs_task_definition": ("runtime_platform",),
    "aws_ecs_service": ("runtime_platform",),
    "aws_security_group": ("ingress", "egress"),
    "aws_lb_listener": ("default_action",),
    "aws_lb_target_group": ("health_check",),
}


def _is_secret_attr(key: str) -> bool:
    lower = key.lower()
    if lower in SECRET_ATTR_KEYS:
        return True
    return any(lower.endswith(suf) for suf in SECRET_ATTR_SUFFIXES)


def _stub_secret_value(value: Any) -> Any:
    if isinstance(value, bool):
        return STUB_SECRET_BOOL
    if isinstance(value, (int, float)):
        return STUB_SECRET_NUMBER
    if isinstance(value, list):
        return [STUB_SECRET_STRING]
    if isinstance(value, dict):
        return {k: STUB_SECRET_STRING for k in value}
    return STUB_SECRET_STRING


def _attrs_for_resource(attrs: dict[str, Any], *, resource_type: str = "") -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in attrs.items():
        if _should_skip_attr(key, value):
            continue
        if _is_secret_attr(key):
            out[key] = _stub_secret_value(value)
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
        # Prefer truthy parent_id; empty/null means AWS root — skip in emit_from_state.
        if "parent_id" in attrs and attrs["parent_id"] not in (None, ""):
            out["parent_id"] = attrs["parent_id"]
        elif "parent_id" in out and out["parent_id"] in (None, ""):
            out.pop("parent_id", None)
        if "rest_api_id" in attrs and attrs["rest_api_id"] not in (None, ""):
            out["rest_api_id"] = attrs["rest_api_id"]
    if resource_type == "aws_route_table":
        # Handled as nested blocks in emit_from_state.
        out.pop("route", None)
    for block_attr in _NESTED_BLOCK_LIST_ATTRS.get(resource_type, ()):
        out.pop(block_attr, None)
    return out


def _is_api_gateway_root_without_parent(attrs: dict[str, Any]) -> bool:
    path_part = attrs.get("path_part")
    parent_id = attrs.get("parent_id")
    if path_part not in ("", "/", None):
        return False
    return parent_id in (None, "")


def _strip_import_address(imports_tf: Path, address: str) -> None:
    """Remove import blocks targeting address so skipped roots do not fail parity."""
    if not imports_tf.is_file():
        return
    text = imports_tf.read_text(encoding="utf-8", errors="replace")
    # import {\n  to = TYPE.NAME\n  id = "..."\n}
    pattern = re.compile(
        rf"import\s*\{{[^{{}}]*?\bto\s*=\s*{re.escape(address)}\s*\n[^{{}}]*?\}}",
        re.M,
    )
    new_text, n = pattern.subn("", text)
    if n:
        imports_tf.write_text(new_text, encoding="utf-8")
        print(f"emit_strip_import address={address} removed={n}")


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
    skipped_root: list[str] = []
    for addr in targets:
        attrs = state_map.get(addr)
        if attrs is None:
            missing_state.append(addr)
            continue
        typ, _, name = addr.partition(".")
        if typ == "aws_api_gateway_resource" and _is_api_gateway_root_without_parent(attrs):
            # Root REST API resources have empty parent_id in AWS; provider still
            # requires parent_id. Skip emit + strip import (children keep string ids).
            skipped_root.append(addr)
            _strip_import_address(imports_tf, addr)
            print(
                f"emit_skip=api_gateway_root_without_parent_id address={addr} "
                f"group={group_dir.name}"
            )
            continue
        cleaned = _attrs_for_resource(attrs, resource_type=typ)
        lines = [
            f'resource "{typ}" "{name}" {{',
            "  # Emitted from terraform.tfstate (hydrate fallback when live generate-config-out fails).",
        ]
        for key in sorted(cleaned):
            rendered = _render_value(cleaned[key], 2)
            lines.append(f"  {key} = {rendered}")
        if typ == "aws_route_table" and isinstance(attrs.get("route"), list):
            route_hcl = _render_route_blocks(attrs.get("route"), 2)
            if route_hcl:
                lines.append(route_hcl)
        for block_attr in _NESTED_BLOCK_LIST_ATTRS.get(typ, ()):
            raw = attrs.get(block_attr)
            # State sometimes stores a single object instead of a one-element list.
            if isinstance(raw, dict):
                raw = [raw]
            if isinstance(raw, list):
                scrubbed: list[Any] = []
                for item in raw:
                    if isinstance(item, dict):
                        scrubbed.append(
                            {
                                k: (
                                    _stub_secret_value(v)
                                    if _is_secret_attr(str(k))
                                    else v
                                )
                                for k, v in item.items()
                            }
                        )
                    else:
                        scrubbed.append(item)
                raw = scrubbed
            nested = _render_nested_object_blocks(raw, block_attr, indent=2)
            if nested:
                lines.append(nested)
        lines.append("}")
        lines.append("")
        blocks.append("\n".join(lines))

    if missing_state and not blocks and not skipped_root:
        print(
            f"emit_fail=no_state_attrs group={group_dir.name} missing={len(missing_state)}",
            file=sys.stderr,
        )
        for addr in missing_state[:20]:
            print(f"  missing_state={addr}", file=sys.stderr)
        return 1

    if not blocks:
        print(
            f"emit_ok=noop group={group_dir.name} have={len(have)} "
            f"skipped_root={len(skipped_root)}"
        )
        return 0

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
        f"missing_state={len(missing_state)} skipped_root={len(skipped_root)} path={gen_tf}"
    )
    return 0


def _rewrite_hint_for_target(*, suggestion: str, kind: str, excerpt: str, attr: str) -> str:
    if suggestion == "repair_broken_resource_block":
        if "runtime_platform" in excerpt or re.search(r"\{\s*\"?cpu_architecture", excerpt):
            return (
                "rewrite orphan object/list as runtime_platform { cpu_architecture=... "
                "operating_system_family=... }; remove stray ]"
            )
        if re.search(r"tag\s*=\s*\[", excerpt) or (
            "capacity_distribution" in excerpt and "{" in excerpt
        ):
            return (
                "rewrite list-of-objects as nested blocks (e.g. tag { key=... value=... "
                "propagate_at_launch=... }); remove orphan { ... }, and stray ]"
            )
        return (
            "resource body has orphan { ... }, or ] from list-of-objects emit; "
            "rewrite as nested blocks or drop the malformed list"
        )
    if suggestion == "add_required_attribute" and attr:
        return f"add required argument {attr}=... using sibling/import context in the same file"
    if suggestion == "rewrite_list_as_nested_blocks":
        return "rewrite attr = [ { ... } ] as repeated nested blocks"
    return ""


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
            # Error text is "An argument or block definition is required" — the
            # word "definition" is not an attribute name (session e210eccd).
            if attr in {"definition", "block", "argument"}:
                attr = ""
        elif "unconfigurable attribute" in kind_l:
            suggestion = "drop_computed_attribute" if attr else "drop_computed_attributes"
        elif "resource has no configuration" in kind_l:
            suggestion = "emit_or_restore_resource_block"

        excerpt = " ".join(chunk.split())[:280]
        hint = _rewrite_hint_for_target(
            suggestion=suggestion, kind=kind, excerpt=excerpt, attr=attr
        )
        targets.append(
            {
                "group_id": group_id,
                "address": addr,
                "attribute": attr,
                "error": kind,
                "suggestion": suggestion,
                "log_path": log_path,
                "excerpt": excerpt,
                "rewrite_hint": hint,
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


def _parse_variable_blocks(text: str) -> list[dict[str, Any]]:
    """Return [{name, type, has_default, sensitive}] for variable blocks in HCL."""
    found: list[dict[str, Any]] = []
    for match in VARIABLE_BLOCK_RE.finditer(text):
        name = match.group(1)
        body = match.group(2)
        typ = "string"
        type_m = re.search(r"\btype\s*=\s*([^\n#]+)", body)
        if type_m:
            typ = type_m.group(1).strip()
        has_default = bool(re.search(r"\bdefault\s*=", body))
        sensitive = bool(re.search(r"\bsensitive\s*=\s*true\b", body))
        found.append(
            {
                "name": name,
                "type": typ,
                "has_default": has_default,
                "sensitive": sensitive,
            }
        )
    return found


def _stub_value_for_variable_type(type_expr: str, *, sensitive: bool) -> str:
    """Render an HCL literal suitable for agent.auto.tfvars."""
    t = type_expr.strip().lower().replace(" ", "")
    if sensitive or "string" in t or t in ("", "any"):
        if "list" in t or "set" in t:
            return f'["{STUB_SECRET_STRING}"]' if sensitive else '["stub"]'
        if "map" in t or "object" in t:
            return (
                f'{{ key = "{STUB_SECRET_STRING}" }}'
                if sensitive
                else '{ key = "stub" }'
            )
        return f'"{STUB_SECRET_STRING}"' if sensitive else '"stub-agent-value"'
    if t.startswith("bool") or t == "bool":
        return "false"
    if t.startswith("number") or t == "number":
        return "0"
    if t.startswith("list") or t.startswith("set"):
        if "string" in t:
            return '["stub"]'
        if "number" in t:
            return "[0]"
        if "bool" in t:
            return "[false]"
        return '["stub"]'
    if t.startswith("map") or t.startswith("object"):
        return '{ key = "stub" }'
    return f'"{STUB_SECRET_STRING}"' if sensitive else '"stub-agent-value"'


def write_agent_stub_tfvars(group_dir: Path) -> int:
    """Write agent.auto.tfvars with type-correct stubs for declared variables.

    Always stubs sensitive variables. Non-sensitive variables without defaults
    also get stubs so ``tofu plan -input=false`` can compile. Returns the number
    of variables written.
    """
    group_dir = group_dir.resolve()
    variables: list[dict[str, Any]] = []
    for tf_path in sorted(group_dir.glob("*.tf")):
        if tf_path.name.endswith(".tfvars") or "override" in tf_path.name:
            continue
        text = tf_path.read_text(encoding="utf-8", errors="replace")
        variables.extend(_parse_variable_blocks(text))

    # De-dupe by name (last wins).
    by_name: dict[str, dict[str, Any]] = {}
    for var in variables:
        by_name[var["name"]] = var

    lines = [
        "# GENERATED — agent-controlled stubs for tofu plan (never apply).",
        f'# Secrets use "{STUB_SECRET_STRING}".',
        "",
    ]
    written = 0
    for name, var in sorted(by_name.items()):
        if var["has_default"] and not var["sensitive"]:
            continue
        literal = _stub_value_for_variable_type(
            str(var["type"]), sensitive=bool(var["sensitive"])
        )
        lines.append(f"{name} = {literal}")
        written += 1

    out = group_dir / "agent.auto.tfvars"
    if written == 0:
        # Still write an empty marker so hydrate can prove the stub pass ran.
        out.write_text(
            "# GENERATED — no required variables; stub pass complete.\n",
            encoding="utf-8",
        )
        print(f"stub_tfvars group={group_dir.name} variables=0 path={out}")
        return 0

    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"stub_tfvars group={group_dir.name} variables={written} path={out}")
    return written


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

    stub = sub.add_parser(
        "write-stub-tfvars",
        help="Write agent.auto.tfvars with type-correct stubs for declared variables",
    )
    stub.add_argument("group_dir", type=Path)

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
    if args.command == "write-stub-tfvars":
        write_agent_stub_tfvars(args.group_dir)
        return 0
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
