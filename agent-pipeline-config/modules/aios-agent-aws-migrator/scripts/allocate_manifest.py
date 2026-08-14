#!/usr/bin/env python3
"""Deterministic monolith tfstate → logical_group_manifest + per-group state shards.

Designed for brownfield splits where each group must `tofu plan` with no unexpected
changes: dependency-connected partitioning, shared-hub isolation, tag boundaries only
when the subgraph is tag-disconnected, and physical state slices under groups/<id>/.
"""
from __future__ import annotations

import json
import os
import re
import sys
from collections import defaultdict, deque
from typing import Dict, Iterable, List, Optional, Set, Tuple

# Preferred tag keys for grouping seeds. No vendor/product prefixes — operators
# override via env (same knobs as tfstate_monolith_decomposer) when their org
# uses custom keys. Matching in seed_key is case-insensitive.
DEFAULT_SEED_TAG_KEYS = (
    # application / ownership (highest signal for logical groups)
    "app",
    "application",
    "service",
    "team",
    "project",
    "workload",
    "system",
    "owner",
    # environment (secondary — often shared across apps)
    "environment",
    "env",
    "stage",
    "tier",
    # weak org signals
    "cost-center",
    "costcenter",
    "business-unit",
)


def resolve_seed_tag_keys() -> Tuple[str, ...]:
    """Resolve preferred tag keys for grouping seeds without hardcoding org brands.

    Order of preference:
    1. ``TFSTATE_ALLOCATE_SEED_TAG_KEYS`` — allocate-specific override
    2. ``TFSTATE_DECOMPOSER_LAYER3_TAG_KEYS`` then ``TFSTATE_DECOMPOSER_ENV_TAG_KEYS``
       — same workflow inputs the monolith decomposer already accepts
    3. ``DEFAULT_SEED_TAG_KEYS`` — generic industry synonyms
    """
    for env_name in (
        "TFSTATE_ALLOCATE_SEED_TAG_KEYS",
        "TFSTATE_DECOMPOSER_LAYER3_TAG_KEYS",
    ):
        raw = (os.environ.get(env_name) or "").strip()
        if raw:
            keys = tuple(k.strip() for k in raw.split(",") if k.strip())
            env_raw = (os.environ.get("TFSTATE_DECOMPOSER_ENV_TAG_KEYS") or "").strip()
            if env_raw:
                keys = keys + tuple(k.strip() for k in env_raw.split(",") if k.strip())
            # de-dupe preserving order
            seen: Set[str] = set()
            out: List[str] = []
            for k in keys:
                lk = k.lower()
                if lk in seen:
                    continue
                seen.add(lk)
                out.append(k)
            return tuple(out)
    return DEFAULT_SEED_TAG_KEYS


def _is_cloud_managed_tag_key(key: str) -> bool:
    """Skip provider/platform noise tags when picking a generic seed fallback."""
    lk = (key or "").lower()
    return (
        lk.startswith("aws:")
        or lk.startswith("kubernetes.io/")
        or lk.startswith("eks:")
        or lk.startswith("ecs:")
        or lk.startswith("lambda:")
        or lk in {"name", "terraform", "tf_module"}  # Name often mirrors resource id
    )


def seed_key(
    tags: dict,
    rtype: str,
    tag_keys: Optional[Iterable[str]] = None,
) -> str:
    """Pick a stable grouping seed from resource tags, then fall back to type.

    Prefer configured/generic synonym keys (case-insensitive). If none match,
    use the first non-cloud-managed tag (sorted) so custom org taxonomies still
    group without code changes. Last resort: Terraform type fragment.
    """
    preferred = list(tag_keys) if tag_keys is not None else list(resolve_seed_tag_keys())
    lower_map = {
        str(k).lower(): (str(k), v)
        for k, v in (tags or {}).items()
        if v is not None and str(v).strip() != ""
    }
    for tk in preferred:
        hit = lower_map.get(str(tk).lower())
        if hit is None:
            continue
        orig_k, v = hit
        return f"tag:{orig_k}={v}"

    for lk in sorted(lower_map.keys()):
        orig_k, v = lower_map[lk]
        if _is_cloud_managed_tag_key(orig_k):
            continue
        return f"tag:{orig_k}={v}"

    parts = rtype.split("_")
    return f"type:{parts[1] if len(parts) > 1 else rtype}"


# Org-wide types often referenced across service boundaries — isolate when fan-in is high.
SHARED_TYPE_MARKERS = (
    "aws_iam_role",
    "aws_iam_policy",
    "aws_iam_instance_profile",
    "aws_kms_key",
    "aws_kms_alias",
    "aws_cloudwatch_log_group",
    "aws_s3_bucket",  # only when high fan-in; type alone is not enough
)

HUB_INDEGREE_THRESHOLD = 10
HUB_MIN_TYPE_FANIN = 5

# cap <= 0 means no artificial per-AppStack size limit (connectivity-only partitioning).
UNLIMITED_CAP_SENTINEL = 0


def normalize_cap(cap: int, resource_count: int) -> int:
    """Map operator cap to an effective ceiling used by merge/split helpers."""
    if cap <= UNLIMITED_CAP_SENTINEL:
        return max(resource_count, 1)
    return cap


def cap_label(cap: int) -> str:
    if cap <= UNLIMITED_CAP_SENTINEL:
        return "unlimited"
    return str(cap)


def sanitize_identifier(addr: str) -> str:
    """Derive a StackGen-safe identifier from a Terraform address (playbook step 2)."""
    s = re.sub(r'[\.\[\]"\/\-\s]+', "_", addr.lower())
    s = re.sub(r"_+", "_", s).strip("_")
    s = re.sub(r"^[0-9_]+", "", s)
    if not s:
        return "resource"
    return s


def terraform_type_from_address(addr: str) -> str:
    """Extract Terraform resource type from a canonical address."""
    parts = addr.split(".")
    if len(parts) >= 2:
        return parts[-2]
    if parts:
        return parts[0]
    return "unknown"


def load_identifier_map(work_root: str) -> Dict[str, str]:
    """Load address→identifier overrides from registry_mapping_report or identifier_map."""
    idmap_path = os.path.join(work_root, "identifier_map.json")
    if os.path.isfile(idmap_path):
        with open(idmap_path, encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            return {str(k): str(v) for k, v in data.items()}

    report_path = os.path.join(work_root, "registry_mapping_report.json")
    if not os.path.isfile(report_path):
        return {}
    with open(report_path, encoding="utf-8") as fh:
        report = json.load(fh)
    if isinstance(report, dict):
        if isinstance(report.get("address_to_identifier"), dict):
            return {str(k): str(v) for k, v in report["address_to_identifier"].items()}
        if isinstance(report.get("identifier_map"), dict):
            return {str(k): str(v) for k, v in report["identifier_map"].items()}
    return {}


def build_resources_for_addresses(
    addresses: Iterable[str], id_map: Dict[str, str]
) -> List[dict]:
    """Build deterministic resource payload entries from Terraform addresses."""
    resources: List[dict] = []
    seen_identifiers: Set[str] = set()
    for addr in sorted(addresses):
        identifier = id_map.get(addr) or sanitize_identifier(addr)
        if identifier in seen_identifiers:
            suffix = str(abs(hash(addr)))[-6:]
            identifier = f"{identifier}_{suffix}"
        seen_identifiers.add(identifier)
        resources.append(
            {
                "terraform_address": addr,
                "resource_type": terraform_type_from_address(addr),
                "identifier": identifier,
            }
        )
    return resources


def build_batch_payloads(
    manifest: dict, sample_ids: List[str], id_map: Dict[str, str]
) -> List[dict]:
    """Assemble MCP-ready batch entries with pre-built resources[] per group."""
    payloads: List[dict] = []
    for gid in sample_ids:
        entry = manifest.get(gid) or {}
        addresses = entry.get("resource_addresses") or []
        payloads.append(
            {
                "group_id": gid,
                "cloud_hint": entry.get("cloud_hint") or cloud_hint(
                    terraform_type_from_address(addresses[0]) if addresses else ""
                ),
                "resource_addresses": sorted(addresses),
                "resources": build_resources_for_addresses(addresses, id_map),
                "appstack_name": sanitize_identifier(gid),
            }
        )
    return payloads


def sample_group_ids_from_manifest(manifest: dict, sample_size: int) -> List[str]:
    """Pick the first N group ids in stable sort order (mirrors stage-runner.sh)."""
    keys = sorted(manifest.keys())
    if len(keys) > 40:
        return keys[:sample_size]
    return keys


def cmd_prepare_parallel_artifacts(work_root: str) -> int:
    """Write sample_group_ids.json, batch_payloads.json, identifier_map.json."""
    manifest_path = os.path.join(work_root, "logical_group_manifest.json")
    if not os.path.isfile(manifest_path):
        print("prepare_error=missing_logical_group_manifest", file=sys.stderr)
        return 1

    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)

    group_count = len(manifest)
    sample_size = 20 if group_count > 40 else group_count
    sample_ids = sample_group_ids_from_manifest(manifest, sample_size)

    id_map = load_identifier_map(work_root)
    idmap_path = os.path.join(work_root, "identifier_map.json")
    with open(idmap_path, "w", encoding="utf-8") as fh:
        json.dump(id_map, fh, indent=2, sort_keys=True)

    sample_path = os.path.join(work_root, "sample_group_ids.json")
    with open(sample_path, "w", encoding="utf-8") as fh:
        json.dump(sample_ids, fh, indent=2)

    payloads = build_batch_payloads(manifest, sample_ids, id_map)
    payloads_path = os.path.join(work_root, "batch_payloads.json")
    with open(payloads_path, "w", encoding="utf-8") as fh:
        json.dump(payloads, fh, indent=2)

    print(f"sample_group_ids_path={sample_path}")
    print(f"batch_payloads_path={payloads_path}")
    print(f"identifier_map_path={idmap_path}")
    print(f"large_state_sample_group_ids={json.dumps(sample_ids)}")
    print(f"large_state_sample_mode={'true' if group_count > 40 else 'false'}")
    print(f"large_state_sample_size={sample_size}")
    return 0


def cloud_hint(rtype: str) -> str:
    if rtype.startswith("aws_"):
        return "aws"
    if rtype.startswith("azurerm_") or rtype.startswith("azapi_"):
        return "azure"
    if rtype.startswith("google_"):
        return "gcp"
    return "unknown"


def instance_address(res: dict, inst: dict) -> str:
    if inst.get("address"):
        return inst["address"]
    if res.get("address"):
        base = res["address"]
        idx = inst.get("index_key")
        if idx is None:
            return base
        if isinstance(idx, int):
            return f"{base}[{idx}]"
        return f'{base}["{idx}"]'
    module = (res.get("module") or "").strip()
    base = f"{res['type']}.{res['name']}"
    if module:
        base = f"{module}.{base}"
    idx = inst.get("index_key")
    if idx is None:
        return base
    if isinstance(idx, int):
        return f"{base}[{idx}]"
    return f'{base}["{idx}"]'


def iter_managed_instances(state: dict) -> Iterable[Tuple[dict, dict, str]]:
    """Yield (resource_block, instance, canonical_address) for each managed instance."""
    for res in state.get("resources") or []:
        if res.get("mode") != "managed":
            continue
        insts = res.get("instances") or []
        if not insts:
            addr = res.get("address") or f"{res.get('type', 'unknown')}.{res.get('name', 'x')}"
            yield res, {}, addr
            continue
        for inst in insts:
            if inst.get("deposed"):
                continue
            status = inst.get("status")
            if status and status not in ("", "ready", "tainted"):
                continue
            yield res, inst, instance_address(res, inst)


def extract_tags(res: dict, inst: dict) -> dict:
    attrs = inst.get("attributes") or {}
    for key in ("tags", "tags_all", "default_tags"):
        val = attrs.get(key)
        if isinstance(val, dict) and val:
            return val
    for inst2 in res.get("instances") or [inst]:
        attrs = inst2.get("attributes") or {}
        for key in ("tags", "tags_all", "default_tags"):
            val = attrs.get(key)
            if isinstance(val, dict) and val:
                return val
    return {}


def extract_dependencies(inst: dict) -> Set[str]:
    return set(inst.get("dependencies") or [])


def build_adjacency(addresses: Set[str], deps_map: Dict[str, Set[str]]) -> Dict[str, Set[str]]:
    """Build undirected adjacency for addresses, ignoring deps outside the vertex set."""
    adj = {a: set() for a in addresses}
    for addr, deps in deps_map.items():
        if addr not in adj:
            continue
        for d in deps:
            if d not in adj:
                continue
            adj[addr].add(d)
            adj[d].add(addr)
    return adj


def compute_indegree(addresses: Set[str], deps_map: Dict[str, Set[str]]) -> Dict[str, int]:
    indegree: Dict[str, int] = defaultdict(int)
    for addr, deps in deps_map.items():
        if addr not in addresses:
            continue
        for d in deps:
            if d in addresses:
                indegree[d] += 1
    return indegree


def is_shared_hub(addr: str, meta: dict, indegree: int) -> bool:
    rtype = meta[addr]["type"]
    if indegree >= HUB_INDEGREE_THRESHOLD:
        return True
    if rtype in SHARED_TYPE_MARKERS and indegree >= HUB_MIN_TYPE_FANIN:
        return True
    if rtype == "aws_s3_bucket" and indegree >= HUB_INDEGREE_THRESHOLD:
        return True
    return False


def connected_components(vertices: Set[str], adj: Dict[str, Set[str]]) -> List[Set[str]]:
    seen: Set[str] = set()
    out: List[Set[str]] = []
    for v in sorted(vertices):
        if v in seen:
            continue
        stack = [v]
        comp: Set[str] = set()
        while stack:
            n = stack.pop()
            if n in seen:
                continue
            seen.add(n)
            comp.add(n)
            for nb in adj.get(n, ()):
                if nb not in seen:
                    stack.append(nb)
        out.append(comp)
    return out


def can_tag_subdivide(component: Set[str], seed_keys: Dict[str, str], adj: Dict[str, Set[str]]) -> bool:
    """Only subdivide by tag when no dependency edge crosses tag boundaries."""
    tags_present = {seed_keys[a] for a in component}
    if len(tags_present) <= 1:
        return False
    for a in component:
        for nb in adj.get(a, ()):
            if nb in component and seed_keys[a] != seed_keys[nb]:
                return False
    return True


def tag_subdivide(component: Set[str], seed_keys: Dict[str, str]) -> List[Set[str]]:
    buckets: Dict[str, Set[str]] = defaultdict(set)
    for addr in component:
        buckets[seed_keys[addr]].add(addr)
    return [set(v) for v in buckets.values()]


def merge_small_by_seed(
    work_sets: List[Set[str]],
    cap: int,
    seed_keys: Dict[str, str],
) -> List[Set[str]]:
    """Merge small (<= cap) work sets into seed-key buckets without splitting connectivity.

    - Work sets larger than *cap* pass through unchanged (handled by cap_split_bfs).
    - Multi-seed connected components (e.g. vpc + subnet) stay intact.
    - Single-seed components at or under *cap* are bin-packed across disconnected
      components that share the same seed key.
    """
    large: List[Set[str]] = [ws for ws in work_sets if len(ws) > cap]
    small_sets = [ws for ws in work_sets if len(ws) <= cap]

    keep_intact: List[Set[str]] = []
    by_seed: Dict[str, List[Set[str]]] = defaultdict(list)

    for ws in small_sets:
        seeds = {seed_keys[a] for a in ws}
        if len(seeds) == 1:
            by_seed[next(iter(seeds))].append(ws)
            continue
        keep_intact.append(ws)

    merged: List[Set[str]] = list(large) + keep_intact
    for sk in sorted(by_seed.keys()):
        addrs: List[str] = []
        for ws in by_seed[sk]:
            addrs.extend(sorted(ws))
        for i in range(0, len(addrs), cap):
            merged.append(set(addrs[i : i + cap]))
    return merged


def cap_split_bfs(
    component: Set[str],
    adj: Dict[str, Set[str]],
    cap: int,
    seed_keys: Dict[str, str],
) -> List[Set[str]]:
    if len(component) <= cap:
        return [set(component)]
    remaining = set(component)
    chunks: List[Set[str]] = []

    def degree(a: str) -> int:
        return len(adj.get(a, set()) & remaining)

    while remaining:
        if len(remaining) <= cap:
            chunks.append(set(remaining))
            break
        seed = max(remaining, key=lambda a: (degree(a), a))
        target_sk = seed_keys.get(seed, "")
        chunk: Set[str] = set()
        q: deque[str] = deque([seed])
        while q and len(chunk) < cap:
            n = q.popleft()
            if n not in remaining or n in chunk:
                continue
            chunk.add(n)
            neighbors = sorted(
                adj.get(n, set()) & remaining - chunk,
                key=lambda x: (seed_keys.get(x, "") != target_sk, -degree(x), x),
            )
            q.extend(neighbors)
        remaining -= chunk
        chunks.append(chunk)
    return chunks


def type_chunk_split(addresses: List[str], cap: int, meta: Dict[str, dict]) -> List[Set[str]]:
    ordered = sorted(addresses, key=lambda a: (meta[a]["type"], a))
    return [set(ordered[i : i + cap]) for i in range(0, len(ordered), cap)]


def load_state_index(state_path: str) -> Tuple[dict, Dict[str, dict], Dict[str, Set[str]], Dict[str, dict]]:
    with open(state_path, encoding="utf-8") as fh:
        state = json.load(fh)

    meta: Dict[str, dict] = {}
    deps_map: Dict[str, Set[str]] = {}
    inst_index: Dict[str, dict] = {}  # address -> {res, inst}

    for res, inst, addr in iter_managed_instances(state):
        rtype = res.get("type") or ""
        tags = extract_tags(res, inst)
        sk = seed_key(tags, rtype)
        cloud = cloud_hint(rtype)
        meta[addr] = {
            "type": rtype,
            "cloud": cloud,
            "seed_key": sk,
            "tags": tags,
            "module": res.get("module") or "",
        }
        deps_map[addr] = extract_dependencies(inst)
        inst_index[addr] = {"res": res, "inst": inst}

    return state, meta, deps_map, inst_index


def allocate(state_path: str, strategy: str, cap: int) -> Tuple[dict, dict, dict]:
    state, meta, deps_map, _inst_index = load_state_index(state_path)
    all_addrs = set(meta.keys())
    eff_cap = normalize_cap(cap, len(all_addrs))
    seed_keys = {a: meta[a]["seed_key"] for a in all_addrs}
    by_cloud: Dict[str, Set[str]] = defaultdict(set)
    for addr, m in meta.items():
        by_cloud[m["cloud"]].add(addr)

    manifest: dict = {}
    group_idx = 0

    def next_gid(cloud: str, label: str = "group") -> str:
        nonlocal group_idx
        group_idx += 1
        return f"{cloud}-{label}-{group_idx:03d}"

    if strategy == "type_chunk":
        for cloud in ("aws", "azure", "gcp", "unknown"):
            addrs = sorted(by_cloud[cloud])
            if not addrs:
                continue
            for chunk in type_chunk_split(addrs, eff_cap, meta):
                gid = next_gid(cloud, "chunk")
                manifest[gid] = {
                    "cloud_hint": cloud,
                    "resource_addresses": sorted(chunk),
                    "notes": {"grouping": strategy, "partition": "greedy-chunk"},
                }
        per_group = {gid: len(v["resource_addresses"]) for gid, v in manifest.items()}
        return manifest, per_group, {"monolith_resource_count": len(all_addrs)}

    use_tag_seed = strategy in ("tag_seeded_connectivity_capped", "tag_seeded_connectivity")

    for cloud in ("aws", "azure", "gcp", "unknown"):
        vertices = set(by_cloud[cloud])
        if not vertices:
            continue

        indegree = compute_indegree(vertices, deps_map)
        shared: Set[str] = {a for a in vertices if is_shared_hub(a, meta, indegree.get(a, 0))}
        workload = vertices - shared

        if shared:
            gid = next_gid(cloud, "shared")
            manifest[gid] = {
                "cloud_hint": cloud,
                "resource_addresses": sorted(shared),
                "notes": {
                    "grouping": strategy,
                    "partition": "shared-hub",
                    "role": "org-wide dependencies — hydrate and plan this group before workload shards",
                },
            }

        if not workload:
            continue

        adj = build_adjacency(workload, deps_map)
        components = connected_components(workload, adj)
        work_sets: List[Set[str]] = []

        for comp in components:
            if (
                use_tag_seed
                and cap > UNLIMITED_CAP_SENTINEL
                and len(comp) > eff_cap
                and can_tag_subdivide(comp, seed_keys, adj)
            ):
                work_sets.extend(tag_subdivide(comp, seed_keys))
            else:
                work_sets.append(comp)

        if use_tag_seed:
            work_sets = merge_small_by_seed(work_sets, eff_cap, seed_keys)

        for comp in work_sets:
            if len(comp) <= eff_cap:
                gid = next_gid(cloud, "group")
                notes = {"grouping": strategy, "partition": "connectivity-component"}
                external = sorted(
                    {d for a in comp for d in deps_map.get(a, set()) if d in shared}
                )
                if external:
                    notes["cross_shard_refs"] = external[:30]
                manifest[gid] = {
                    "cloud_hint": cloud,
                    "resource_addresses": sorted(comp),
                    "notes": notes,
                }
                continue

            for chunk in cap_split_bfs(comp, adj, eff_cap, seed_keys):
                gid = next_gid(cloud, "shard")
                notes: dict = {"grouping": strategy, "partition": "bfs-cap-split"}
                cut_hubs = sorted(
                    a for a in chunk if len(adj.get(a, set()) - chunk) > 0
                )
                if cut_hubs:
                    notes["cross_shard_refs"] = cut_hubs[:30]
                external = sorted(
                    {d for a in chunk for d in deps_map.get(a, set()) if d in shared}
                )
                if external:
                    notes["shared_refs"] = external[:30]
                manifest[gid] = {
                    "cloud_hint": cloud,
                    "resource_addresses": sorted(chunk),
                    "notes": notes,
                }

    per_group = {gid: len(v["resource_addresses"]) for gid, v in manifest.items()}
    return manifest, per_group, {"monolith_resource_count": len(all_addrs)}


def reconcile(state_path: str, manifest: dict) -> dict:
    _, meta, _, _ = load_state_index(state_path)
    all_addrs = set(meta.keys())
    allocated: List[str] = []
    for entry in manifest.values():
        allocated.extend(entry.get("resource_addresses") or [])
    allocated_set = set(allocated)
    dupes = len(allocated) - len(allocated_set)
    unallocated = sorted(all_addrs - allocated_set)
    extra = sorted(set(allocated) - all_addrs)
    monolith_count = len(all_addrs)
    aggregate = len(allocated_set & all_addrs)
    ok = dupes == 0 and len(unallocated) == 0 and len(extra) == 0
    return {
        "count_reconciliation_ok": ok,
        "monolith_resource_count": monolith_count,
        "aggregate_group_resource_count": aggregate,
        "duplicate_address_count": dupes,
        "unallocated_resource_count": len(unallocated),
        "unknown_address_count": len(extra),
        "unallocated_sample": unallocated[:10],
    }


def _resource_key(res: dict) -> str:
    module = res.get("module") or ""
    return f"{module}|{res.get('type')}|{res.get('name')}|{res.get('provider')}"


def extract_group_states(state_path: str, work_root: str, manifest: dict) -> dict:
    """Write groups/<group_id>/terraform.tfstate for isolated per-group plan."""
    with open(state_path, encoding="utf-8") as fh:
        state = json.load(fh)

    addr_to_group: Dict[str, str] = {}
    for gid, entry in manifest.items():
        for addr in entry.get("resource_addresses") or []:
            addr_to_group[addr] = gid

    # group_key -> list of (res_template, instance)
    buckets: Dict[str, Dict[str, List[dict]]] = defaultdict(lambda: defaultdict(list))

    for res, inst, addr in iter_managed_instances(state):
        gid = addr_to_group.get(addr)
        if not gid:
            continue
        buckets[gid][_resource_key(res)].append((res, inst))

    paths: Dict[str, str] = {}
    base_meta = {
        k: state.get(k)
        for k in ("version", "terraform_version", "serial", "lineage")
        if k in state
    }

    for gid, res_map in buckets.items():
        out_resources: List[dict] = []
        for _rkey, pairs in res_map.items():
            template = pairs[0][0]
            new_res = {
                k: template[k]
                for k in ("module", "mode", "type", "name", "provider")
                if k in template
            }
            if "address" in template and len(pairs) == 1:
                new_res["address"] = pairs[0][1].get("address") or template.get("address")
            new_res["instances"] = [p[1] for p in pairs if p[1]]
            if new_res["instances"]:
                out_resources.append(new_res)

        shard = {**base_meta, "outputs": {}, "resources": out_resources}
        out_dir = os.path.join(work_root, "groups", gid)
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, "terraform.tfstate")
        with open(out_path, "w", encoding="utf-8") as fh:
            json.dump(shard, fh, indent=2)
        paths[gid] = out_path

    index_path = os.path.join(work_root, "group_state_paths.json")
    with open(index_path, "w", encoding="utf-8") as fh:
        json.dump(paths, fh, indent=2, sort_keys=True)
    return paths


def write_inventory(state_path: str, work_root: str) -> Tuple[str, str, int]:
    """Emit anchor inventory + seeds for discover stage handoff."""
    state, meta, _, _ = load_state_index(state_path)
    seeds_path = os.path.join(work_root, "logical_group_seeds.json")
    inventory_path = os.path.join(work_root, "db_anchor_inventory.json")

    seeds = [
        {"address": a, "type": m["type"], "group_key": m["seed_key"]}
        for a, m in sorted(meta.items())
    ]
    db_re = re.compile(
        r"aws_db_instance|aws_rds_cluster|aws_dynamodb_table|"
        r"aws_elasticache_cluster|aws_dms_replication_instance|"
        r"azurerm_mssql|azurerm_postgresql|google_sql"
    )
    inventory = [s for s in seeds if db_re.search(s["type"])]

    with open(seeds_path, "w", encoding="utf-8") as fh:
        json.dump(seeds, fh, indent=2)
    with open(inventory_path, "w", encoding="utf-8") as fh:
        json.dump(inventory, fh, indent=2)
    return seeds_path, inventory_path, len(seeds)


def parse_provider_block(provider_str: str) -> Tuple[str, str]:
    """Return (local_name, source) from a tfstate provider string."""
    m = re.search(r"registry\.terraform\.io/([^/\"]+)/([^\"]+)", provider_str or "")
    if not m:
        return "aws", "hashicorp/aws"
    namespace, ptype = m.group(1), m.group(2)
    return ptype, f"{namespace}/{ptype}"


def import_id_from_instance(inst: dict) -> Optional[str]:
    """Best-effort import id from instance attributes."""
    attrs = inst.get("attributes") or {}
    for key in (
        "id",
        "arn",
        "name",
        "self_link",
        "unique_id",
        "bucket",
        "cluster_id",
        "function_name",
    ):
        val = attrs.get(key)
        if val is not None and str(val).strip() != "":
            return str(val)
    return None


def infer_aws_region_from_state(state: dict) -> str:
    """Pick the most common AWS region from shard state attributes (fallback us-east-1)."""
    counts: Dict[str, int] = defaultdict(int)
    for res in state.get("resources") or []:
        if res.get("mode") != "managed":
            continue
        provider = str(res.get("provider") or "")
        if "aws" not in provider:
            continue
        for inst in res.get("instances") or []:
            if inst.get("deposed"):
                continue
            attrs = inst.get("attributes") or {}
            region = attrs.get("region")
            if region:
                counts[str(region)] += 1
                continue
            az = attrs.get("availability_zone") or attrs.get("availability_zone_id")
            if az:
                match = re.match(r"^([a-z]{2}-(?:gov-)?[a-z]+-\d+)", str(az))
                if match:
                    counts[match.group(1)] += 1
    if not counts:
        return "us-east-1"
    return max(counts.items(), key=lambda item: item[1])[0]


def infer_google_project_from_state(state: dict) -> str:
    for res in state.get("resources") or []:
        if res.get("mode") != "managed":
            continue
        if "google" not in str(res.get("provider") or ""):
            continue
        for inst in res.get("instances") or []:
            if inst.get("deposed"):
                continue
            project = (inst.get("attributes") or {}).get("project")
            if project:
                return str(project)
    return "change-me"


def infer_google_region_from_state(state: dict) -> str:
    for res in state.get("resources") or []:
        if res.get("mode") != "managed":
            continue
        if "google" not in str(res.get("provider") or ""):
            continue
        for inst in res.get("instances") or []:
            if inst.get("deposed"):
                continue
            region = (inst.get("attributes") or {}).get("region")
            if region:
                return str(region)
    return "us-central1"


def scaffold_group_dir(group_dir: str, group_id: str, state_path: str) -> dict:
    """Write versions.tf, providers.tf, imports.tf for one logical group shard."""
    with open(state_path, encoding="utf-8") as fh:
        state = json.load(fh)

    providers: Dict[str, str] = {}
    import_blocks: List[str] = []
    orphan_addrs: List[str] = []

    for res in state.get("resources") or []:
        if res.get("mode") != "managed":
            continue
        local, source = parse_provider_block(res.get("provider") or "")
        providers[local] = source
        insts = res.get("instances") or [{}]
        for inst in insts:
            if inst.get("deposed"):
                continue
            addr = instance_address(res, inst)
            imp_id = import_id_from_instance(inst)
            if not imp_id:
                orphan_addrs.append(addr)
                continue
            safe_id = imp_id.replace("\\", "\\\\").replace('"', '\\"')
            import_blocks.append(
                f"import {{\n  to = {addr}\n  id = \"{safe_id}\"\n}}\n"
            )

    os.makedirs(group_dir, exist_ok=True)

    versions = 'terraform {\n  required_version = ">= 1.5.0"\n  required_providers {\n'
    for local, source in sorted(providers.items()):
        versions += f'    {local} = {{\n      source = "{source}"\n    }}\n'
    versions += "  }\n}\n"

    prov_tf = ""
    aws_region = infer_aws_region_from_state(state)
    google_project = infer_google_project_from_state(state)
    google_region = infer_google_region_from_state(state)
    for local in sorted(providers.keys()):
        if local == "aws":
            prov_tf += f'provider "aws" {{\n  region = "{aws_region}"\n}}\n\n'
        if local == "azurerm":
            prov_tf += 'provider "azurerm" {\n  features {}\n}\n\n'
        if local == "google":
            prov_tf += (
                f'provider "google" {{\n  project = "{google_project}"\n  region  = "{google_region}"\n}}\n\n'
            )

    imports_path = os.path.join(group_dir, "imports.tf")
    with open(os.path.join(group_dir, "versions.tf"), "w", encoding="utf-8") as fh:
        fh.write(versions)
    with open(os.path.join(group_dir, "providers.tf"), "w", encoding="utf-8") as fh:
        fh.write(prov_tf)
    with open(imports_path, "w", encoding="utf-8") as fh:
        fh.write(f"# Group {group_id} — import blocks from monolith state shard\n\n")
        fh.write("".join(import_blocks))

    return {
        "group_id": group_id,
        "imports_path": imports_path,
        "import_count": len(import_blocks),
        "orphan_count": len(orphan_addrs),
        "orphan_addresses": orphan_addrs,
    }


def cmd_scaffold_registry(work_root: str) -> int:
    """Generate per-group HCL scaffold (versions/providers/imports) under groups/<id>/."""
    manifest_path = os.path.join(work_root, "logical_group_manifest.json")
    if not os.path.isfile(manifest_path):
        print("scaffold_error=missing_logical_group_manifest", file=sys.stderr)
        return 1

    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)

    paths_path = os.path.join(work_root, "group_state_paths.json")
    group_paths: Dict[str, str] = {}
    if os.path.isfile(paths_path):
        with open(paths_path, encoding="utf-8") as fh:
            group_paths = json.load(fh)

    summary: List[dict] = []
    orphans_bundle: List[dict] = []
    total_imports = 0

    for gid in sorted(manifest.keys()):
        state_path = group_paths.get(gid) or os.path.join(
            work_root, "groups", gid, "terraform.tfstate"
        )
        if not os.path.isfile(state_path):
            print(f"scaffold_warning=missing_state group_id={gid}", file=sys.stderr)
            continue
        group_dir = os.path.join(work_root, "groups", gid)
        result = scaffold_group_dir(group_dir, gid, state_path)
        summary.append(result)
        total_imports += result["import_count"]
        for addr in result.get("orphan_addresses") or []:
            orphans_bundle.append(
                {"address": addr, "group_id": gid, "reason": "no_import_id_in_state"}
            )

    report_path = os.path.join(work_root, "registry_mapping_report.json")
    orphans_path = os.path.join(work_root, "orphans_bundle.json")
    reverse_summary = {
        "files_created": len(summary) * 3,
        "groups_scaffolded": len(summary),
        "imports_pending": total_imports,
        "scaffold_paths_per_group": {
            row["group_id"]: row["imports_path"] for row in summary
        },
    }
    with open(report_path, "w", encoding="utf-8") as fh:
        json.dump(reverse_summary, fh, indent=2)
    with open(orphans_path, "w", encoding="utf-8") as fh:
        json.dump(orphans_bundle, fh, indent=2)

    print(f"registry_scaffold_groups={len(summary)}")
    print(f"registry_import_blocks={total_imports}")
    print(f"registry_mapping_report={report_path}")
    print(f"orphans_bundle={orphans_path}")
    print(f"reverse_iac_summary={json.dumps(reverse_summary)}")
    return 0


def cmd_allocate(work_root: str, state_path: str, strategy: str, cap: int) -> int:
    manifest, per_group, stats = allocate(state_path, strategy, cap)
    manifest_path = os.path.join(work_root, "logical_group_manifest.json")
    counts_path = os.path.join(work_root, "per_group_resource_counts.json")
    shard_path = os.path.join(work_root, "shard_manifest.json")

    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
    with open(shard_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
    with open(counts_path, "w", encoding="utf-8") as fh:
        json.dump(per_group, fh, indent=2, sort_keys=True)

    print(f"logical_group_manifest_path={manifest_path}")
    print(f"group_count={len(manifest)}")
    print(f"aggregate_group_resource_count={sum(per_group.values())}")
    print(f"monolith_resource_count={stats['monolith_resource_count']}")
    print(f"grouping_strategy={strategy}")
    print(f"max_resources_per_appstack={cap_label(cap)}")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: allocate_manifest.py <allocate|reconcile|extract-states|split|inventory|scaffold-registry|prepare-parallel-artifacts> ...",
            file=sys.stderr,
        )
        return 2

    cmd = sys.argv[1]
    if cmd == "allocate":
        work_root, state_path, strategy, cap_s = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
        try:
            cap = int(cap_s) if cap_s else UNLIMITED_CAP_SENTINEL
        except ValueError:
            cap = UNLIMITED_CAP_SENTINEL
        return cmd_allocate(work_root, state_path, strategy, cap)

    if cmd == "reconcile":
        state_path, manifest_path = sys.argv[2], sys.argv[3]
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
        result = reconcile(state_path, manifest)
        print(json.dumps(result))
        return 0 if result["count_reconciliation_ok"] else 1

    if cmd == "extract-states":
        state_path, work_root, manifest_path = sys.argv[2], sys.argv[3], sys.argv[4]
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
        paths = extract_group_states(state_path, work_root, manifest)
        print(f"group_state_count={len(paths)}")
        print(f"group_state_paths={os.path.join(work_root, 'group_state_paths.json')}")
        return 0

    if cmd == "inventory":
        state_path, work_root = sys.argv[2], sys.argv[3]
        seeds, inv, n = write_inventory(state_path, work_root)
        print(f"logical_group_seeds_path={seeds}")
        print(f"db_anchor_inventory_path={inv}")
        print(f"anchor_seeds_extracted={n}")
        return 0

    if cmd == "scaffold-registry":
        work_root = sys.argv[2]
        return cmd_scaffold_registry(work_root)

    if cmd == "prepare-parallel-artifacts":
        work_root = sys.argv[2]
        return cmd_prepare_parallel_artifacts(work_root)

    if cmd == "split":
        work_root, state_path = sys.argv[2], sys.argv[3]
        strategy = sys.argv[4] if len(sys.argv) > 4 else "tag_seeded_connectivity_capped"
        cap_s = sys.argv[5] if len(sys.argv) > 5 else str(UNLIMITED_CAP_SENTINEL)
        try:
            cap = int(cap_s)
        except ValueError:
            cap = UNLIMITED_CAP_SENTINEL
        write_inventory(state_path, work_root)
        manifest, per_group, stats = allocate(state_path, strategy, cap)
        manifest_path = os.path.join(work_root, "logical_group_manifest.json")
        with open(manifest_path, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, sort_keys=True)
        with open(os.path.join(work_root, "shard_manifest.json"), "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, sort_keys=True)
        with open(os.path.join(work_root, "per_group_resource_counts.json"), "w", encoding="utf-8") as fh:
            json.dump(per_group, fh, indent=2, sort_keys=True)
        extract_group_states(state_path, work_root, manifest)
        result = reconcile(state_path, manifest)
        result_path = os.path.join(work_root, "reconcile_result.json")
        with open(result_path, "w", encoding="utf-8") as fh:
            json.dump(result, fh, indent=2)
        print(f"logical_group_manifest_path={manifest_path}")
        print(f"group_count={len(manifest)}")
        print(f"aggregate_group_resource_count={sum(per_group.values())}")
        print(f"monolith_resource_count={stats['monolith_resource_count']}")
        print(f"grouping_strategy={strategy}")
        print(f"max_resources_per_appstack={cap_label(cap)}")
        print(f"reconcile_result_path={result_path}")
        print(f"count_reconciliation_ok={str(result['count_reconciliation_ok']).lower()}")
        return 0 if result["count_reconciliation_ok"] else 1

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
