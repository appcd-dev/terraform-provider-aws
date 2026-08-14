#!/usr/bin/env python3
"""Layered three-tier tfstate → logical_group_manifest + per-group state shards.

New partitioning philosophy: resources are classified into Foundation (L1), Platform (L2),
and Application (L3) layers. A dependency edge that crosses a layer boundary is NOT a merge
signal — it becomes a terraform_remote_state reference wired in upstream.tf. This inverts
the central assumption of the connectivity-first allocate_manifest.py strategy.

This file is a **deliberate full clone** of allocate_manifest.py so allocate_manifest.py
stays 100% untouched as the demo fallback. Duplication is accepted; de-dup is a later
follow-up once the layered allocator is proven.

CLI (drop-in compatible with allocate_manifest.py):
  python3 tfstate_monolith_decomposer.py split <work_root> <state_path> [cap] [--overrides <path>]
  python3 tfstate_monolith_decomposer.py reconcile <state_path> <manifest_path>
  python3 tfstate_monolith_decomposer.py extract-states <state_path> <work_root> <manifest_path>
  python3 tfstate_monolith_decomposer.py scaffold-registry <work_root>
  python3 tfstate_monolith_decomposer.py inventory <state_path> <work_root>
  python3 tfstate_monolith_decomposer.py prepare-parallel-artifacts <work_root>
"""
from __future__ import annotations

import json
import os
import re
import sys
from collections import Counter, defaultdict, deque
from typing import Dict, Iterable, List, Optional, Set, Tuple

# ---------------------------------------------------------------------------
# Section 1: Type Range Taxonomy
# ---------------------------------------------------------------------------
# (ceiling, floor) — ceiling is the highest (lowest-numbered) layer the type
# can sit at; floor is the most-specific (highest-numbered) layer it can sit at.
# Unambiguous types: ceiling == floor. Ambiguous types have a range resolved by
# the classification cascade.

LAYER_TYPE_RULES: Dict[str, Tuple[int, int]] = {
    # ── Layer 1 definite (1,1) — Foundation ──
    "aws_vpc":                               (1, 1),
    "aws_subnet":                            (1, 1),
    "aws_route_table":                       (1, 1),
    "aws_route_table_association":           (1, 1),
    "aws_internet_gateway":                  (1, 1),
    "aws_nat_gateway":                       (1, 1),
    "aws_eip":                               (1, 1),
    "aws_vpn_gateway":                       (1, 1),
    "aws_customer_gateway":                  (1, 1),
    "aws_vpn_connection":                    (1, 1),
    "aws_transit_gateway":                   (1, 1),
    "aws_transit_gateway_attachment":        (1, 1),
    "aws_transit_gateway_route_table":       (1, 1),
    "aws_transit_gateway_vpc_attachment":    (1, 1),
    "aws_network_acl":                       (1, 1),
    "aws_network_acl_rule":                  (1, 1),
    "aws_vpc_dhcp_options":                  (1, 1),
    "aws_vpc_dhcp_options_association":      (1, 1),
    "aws_flow_log":                          (1, 1),
    "aws_vpc_endpoint":                      (1, 1),
    "aws_vpc_endpoint_service":              (1, 1),
    "aws_vpc_peering_connection":            (1, 1),
    "aws_vpc_peering_connection_accepter":   (1, 1),
    "aws_dx_connection":                     (1, 1),
    "aws_dx_hosted_connection":              (1, 1),
    "aws_dx_gateway":                        (1, 1),
    "aws_dx_gateway_association":            (1, 1),
    "aws_route53_zone":                      (1, 1),
    "aws_route53_resolver_endpoint":         (1, 1),
    "aws_route53_resolver_rule":             (1, 1),
    "aws_route53_resolver_rule_association": (1, 1),
    # Azure L1
    "azurerm_virtual_network":               (1, 1),
    "azurerm_subnet":                        (1, 1),
    "azurerm_route_table":                   (1, 1),
    "azurerm_route_table_association":       (1, 1),
    "azurerm_public_ip":                     (1, 1),
    "azurerm_dns_zone":                      (1, 1),
    "azurerm_private_dns_zone":              (1, 1),
    "azurerm_nat_gateway":                   (1, 1),
    "azurerm_express_route_circuit":         (1, 1),
    "azurerm_virtual_network_gateway":       (1, 1),
    "azurerm_network_watcher":               (1, 1),
    # GCP L1
    "google_compute_network":                (1, 1),
    "google_compute_subnetwork":             (1, 1),
    "google_compute_router":                 (1, 1),
    "google_compute_router_nat":             (1, 1),
    "google_compute_firewall":               (1, 1),
    "google_compute_vpn_gateway":            (1, 1),
    "google_compute_vpn_tunnel":             (1, 1),
    "google_dns_managed_zone":               (1, 1),

    # ── Layer 2 definite (2,2) — Shared Platform ──
    "aws_eks_cluster":                       (2, 2),
    "aws_eks_node_group":                    (2, 2),
    "aws_eks_addon":                         (2, 2),
    "aws_eks_fargate_profile":               (2, 2),
    "aws_ecs_cluster":                       (2, 2),
    "aws_ecs_capacity_provider":             (2, 2),
    "aws_rds_cluster":                       (2, 2),
    "aws_rds_cluster_instance":              (2, 2),
    "aws_rds_cluster_parameter_group":       (2, 2),
    "aws_rds_subnet_group":                  (2, 2),
    "aws_elasticache_cluster":               (2, 2),
    "aws_elasticache_replication_group":     (2, 2),
    "aws_elasticache_subnet_group":          (2, 2),
    "aws_elasticache_parameter_group":       (2, 2),
    "aws_msk_cluster":                       (2, 2),
    "aws_msk_configuration":                 (2, 2),
    "aws_redshift_cluster":                  (2, 2),
    "aws_redshift_subnet_group":             (2, 2),
    "aws_ecr_repository":                    (2, 2),
    "aws_ecr_lifecycle_policy":              (2, 2),
    # Azure L2
    "azurerm_kubernetes_cluster":            (2, 2),
    "azurerm_kubernetes_cluster_node_pool":  (2, 2),
    "azurerm_mssql_server":                  (2, 2),
    "azurerm_mssql_database":                (2, 2),
    "azurerm_postgresql_server":             (2, 2),
    "azurerm_redis_cache":                   (2, 2),
    "azurerm_container_registry":            (2, 2),
    "azurerm_eventhub_namespace":            (2, 2),
    "azurerm_service_bus_namespace":         (2, 2),
    # GCP L2
    "google_container_cluster":              (2, 2),
    "google_container_node_pool":            (2, 2),
    "google_sql_database_instance":          (2, 2),
    "google_sql_database":                   (2, 2),
    "google_redis_instance":                 (2, 2),
    "google_pubsub_topic":                   (2, 2),
    "google_pubsub_subscription":            (2, 2),

    # ── Layer 3 definite (3,3) — Application ──
    "aws_lambda_function":                   (3, 3),
    "aws_lambda_alias":                      (3, 3),
    "aws_lambda_event_source_mapping":       (3, 3),
    "aws_lambda_permission":                 (3, 3),
    "aws_sqs_queue":                         (3, 3),
    "aws_sqs_queue_policy":                  (3, 3),
    "aws_sns_topic":                         (3, 3),
    "aws_sns_topic_subscription":            (3, 3),
    "aws_sns_topic_policy":                  (3, 3),
    "aws_dynamodb_table":                    (3, 3),
    "aws_api_gateway_rest_api":              (3, 3),
    "aws_api_gateway_stage":                 (3, 3),
    "aws_api_gateway_deployment":            (3, 3),
    "aws_apigatewayv2_api":                  (3, 3),
    "aws_apigatewayv2_stage":                (3, 3),
    "aws_step_functions_state_machine":      (3, 3),
    "aws_ecs_task_definition":               (3, 3),
    "aws_ecs_service":                       (3, 3),
    "aws_cloudfront_distribution":           (3, 3),
    "aws_elastic_beanstalk_application":     (3, 3),
    "aws_elastic_beanstalk_environment":     (3, 3),

    # ── Ambiguous: ranges ──
    "aws_security_group":                    (1, 3),   # VPC default→L1; app SG→L3
    "aws_security_group_rule":               (1, 3),
    "aws_vpc_security_group_ingress_rule":   (1, 3),
    "aws_vpc_security_group_egress_rule":    (1, 3),
    "aws_iam_role":                          (1, 3),   # org role→L1; app exec role→L3
    "aws_iam_role_policy":                   (1, 3),
    "aws_iam_role_policy_attachment":        (1, 3),
    "aws_iam_policy":                        (1, 3),
    "aws_iam_policy_attachment":             (1, 3),
    "aws_iam_instance_profile":              (2, 3),
    "aws_iam_user":                          (1, 3),
    "aws_iam_group":                         (1, 2),
    "aws_iam_openid_connect_provider":       (1, 2),
    "aws_s3_bucket":                         (2, 3),   # shared data lake→L2; app bucket→L3
    "aws_s3_bucket_policy":                  (2, 3),
    "aws_s3_bucket_acl":                     (2, 3),
    "aws_s3_bucket_versioning":              (2, 3),
    "aws_s3_bucket_lifecycle_configuration": (2, 3),
    "aws_s3_bucket_notification":            (2, 3),
    "aws_s3_bucket_public_access_block":     (2, 3),
    "aws_kms_key":                           (1, 3),   # org encryption→L1; app key→L3
    "aws_kms_alias":                         (1, 3),
    "aws_kms_grant":                         (1, 3),
    "aws_cloudwatch_log_group":              (2, 3),
    "aws_cloudwatch_metric_alarm":           (2, 3),
    "aws_rds_instance":                      (2, 3),   # shared DB→L2; app DB→L3
    "aws_db_instance":                       (2, 3),
    "aws_db_subnet_group":                   (1, 2),
    "aws_db_parameter_group":                (2, 3),
    "aws_lb":                                (2, 3),   # shared ALB→L2; app ALB→L3
    "aws_alb":                               (2, 3),
    "aws_lb_listener":                       (2, 3),
    "aws_lb_listener_rule":                  (2, 3),
    "aws_lb_target_group":                   (2, 3),
    "aws_alb_target_group":                  (2, 3),
    "aws_alb_listener":                      (2, 3),
    "aws_acm_certificate":                   (2, 3),
    "aws_acm_certificate_validation":        (2, 3),
    "aws_secretsmanager_secret":             (2, 3),
    "aws_secretsmanager_secret_version":     (2, 3),
    "aws_ssm_parameter":                     (2, 3),
    "aws_ssm_document":                      (2, 3),
    "aws_route53_record":                    (1, 3),
    "aws_autoscaling_group":                 (2, 3),
    "aws_autoscaling_policy":                (2, 3),
    "aws_launch_template":                   (2, 3),
    "aws_instance":                          (2, 3),
    "aws_network_interface":                 (1, 3),
    "aws_cloudwatch_log_subscription_filter": (2, 3),
    "aws_cloudwatch_event_rule":             (2, 3),
    "aws_cloudwatch_event_target":           (2, 3),
    "azurerm_role_assignment":               (1, 3),
    "azurerm_role_definition":               (1, 2),
    "azurerm_key_vault":                     (1, 3),
    "azurerm_key_vault_secret":              (2, 3),
    "azurerm_storage_account":               (2, 3),
    "azurerm_app_service":                   (3, 3),
    "azurerm_app_service_plan":              (2, 3),
    "azurerm_function_app":                  (3, 3),
    "azurerm_application_gateway":           (2, 3),
    "google_storage_bucket":                 (2, 3),
    "google_storage_bucket_iam_binding":     (2, 3),
    "google_kms_key_ring":                   (1, 2),
    "google_kms_crypto_key":                 (1, 3),
    "google_secret_manager_secret":          (2, 3),
    "google_cloudfunctions_function":        (3, 3),
    "google_cloud_run_service":              (3, 3),
    "google_compute_instance":               (2, 3),
    "google_iam_binding":                    (1, 3),
    "google_project_iam_binding":            (1, 2),
    "google_project_iam_member":             (1, 2),
}

LAYER_PREFIXES: Dict[int, List[str]] = {
    1: [
        "aws_vpc_", "aws_subnet_", "aws_route_", "aws_network_",
        "aws_dx_", "aws_transit_gateway_", "aws_internet_gateway",
        "azurerm_virtual_network_", "azurerm_subnet_",
        "google_compute_network_", "google_compute_subnetwork_",
        "google_compute_route_", "google_compute_address_",
    ],
    2: [
        "aws_eks_", "aws_ecs_", "aws_rds_", "aws_elasticache_",
        "aws_msk_", "aws_redshift_", "aws_ecr_",
        "azurerm_kubernetes_", "azurerm_mssql_", "azurerm_redis_",
        "azurerm_eventhub_", "azurerm_service_bus_",
        "google_container_", "google_sql_", "google_pubsub_",
    ],
}


def resolve_unknown_type(rtype: str) -> Optional[Tuple[int, int]]:
    """Prefix heuristic for types not in LAYER_TYPE_RULES."""
    for layer in sorted(LAYER_PREFIXES.keys()):
        for prefix in LAYER_PREFIXES[layer]:
            if rtype.startswith(prefix):
                return (layer, layer)  # treat as definite
    return None  # → dependency cascade or review


# ---------------------------------------------------------------------------
# Cloned helpers from allocate_manifest.py (keep seed-tag logic in sync)
# ---------------------------------------------------------------------------

# Preferred tag keys for grouping seeds. No vendor/product prefixes — operators
# override via env (same knobs as this decomposer) when their org uses custom keys.
DEFAULT_SEED_TAG_KEYS = (
    "app",
    "application",
    "service",
    "team",
    "project",
    "workload",
    "system",
    "owner",
    "environment",
    "env",
    "stage",
    "tier",
    "cost-center",
    "costcenter",
    "business-unit",
)


def resolve_seed_tag_keys() -> Tuple[str, ...]:
    """Resolve preferred tag keys for grouping seeds without hardcoding org brands."""
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
    lk = (key or "").lower()
    return (
        lk.startswith("aws:")
        or lk.startswith("kubernetes.io/")
        or lk.startswith("eks:")
        or lk.startswith("ecs:")
        or lk.startswith("lambda:")
        or lk in {"name", "terraform", "tf_module"}
    )


def seed_key(
    tags: dict,
    rtype: str,
    tag_keys: Optional[Iterable[str]] = None,
) -> str:
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


SHARED_TYPE_MARKERS = (
    "aws_iam_role",
    "aws_iam_policy",
    "aws_iam_instance_profile",
    "aws_kms_key",
    "aws_kms_alias",
    "aws_cloudwatch_log_group",
    "aws_s3_bucket",
)

HUB_INDEGREE_THRESHOLD = 10
HUB_MIN_TYPE_FANIN = 5
UNLIMITED_CAP_SENTINEL = 0


def normalize_cap(cap: int, resource_count: int) -> int:
    if cap <= UNLIMITED_CAP_SENTINEL:
        return max(resource_count, 1)
    return cap


def cap_label(cap: int) -> str:
    if cap <= UNLIMITED_CAP_SENTINEL:
        return "unlimited"
    return str(cap)


def sanitize_identifier(addr: str) -> str:
    s = re.sub(r'[\.\[\]"\/\-\s]+', "_", addr.lower())
    s = re.sub(r"_+", "_", s).strip("_")
    s = re.sub(r"^[0-9_]+", "", s)
    if not s:
        return "resource"
    return s


# Short alias used in grouping (safe for group IDs)
sanitize = sanitize_identifier


def terraform_type_from_address(addr: str) -> str:
    parts = addr.split(".")
    if len(parts) >= 2:
        return parts[-2]
    if parts:
        return parts[0]
    return "unknown"


def load_identifier_map(work_root: str) -> Dict[str, str]:
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


def build_resources_for_addresses(addresses: Iterable[str], id_map: Dict[str, str]) -> List[dict]:
    resources: List[dict] = []
    seen_identifiers: Set[str] = set()
    for addr in sorted(addresses):
        identifier = id_map.get(addr) or sanitize_identifier(addr)
        if identifier in seen_identifiers:
            suffix = str(abs(hash(addr)))[-6:]
            identifier = f"{identifier}_{suffix}"
        seen_identifiers.add(identifier)
        resources.append({
            "terraform_address": addr,
            "resource_type": terraform_type_from_address(addr),
            "identifier": identifier,
        })
    return resources


def build_batch_payloads(manifest: dict, sample_ids: List[str], id_map: Dict[str, str]) -> List[dict]:
    payloads: List[dict] = []
    for gid in sample_ids:
        entry = manifest.get(gid) or {}
        addresses = entry.get("resource_addresses") or []
        payloads.append({
            "group_id": gid,
            "cloud_hint": entry.get("cloud") or cloud_hint(
                terraform_type_from_address(addresses[0]) if addresses else ""
            ),
            "resource_addresses": sorted(addresses),
            "resources": build_resources_for_addresses(addresses, id_map),
            "appstack_name": sanitize_identifier(gid),
        })
    return payloads


def sample_group_ids_from_manifest(manifest: dict, sample_size: int) -> List[str]:
    keys = sorted(manifest.keys())
    if len(keys) > 40:
        return keys[:sample_size]
    return keys


def cmd_prepare_parallel_artifacts(work_root: str) -> int:
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


def merge_small_by_seed(work_sets: List[Set[str]], cap: int, seed_keys: Dict[str, str]) -> List[Set[str]]:
    large = [ws for ws in work_sets if len(ws) > cap]
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
            merged.append(set(addrs[i: i + cap]))
    return merged


def cap_split_bfs(component: Set[str], adj: Dict[str, Set[str]], cap: int, seed_keys: Dict[str, str]) -> List[Set[str]]:
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
        q: deque = deque([seed])
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
    return [set(ordered[i: i + cap]) for i in range(0, len(ordered), cap)]


def load_state_index(state_path: str) -> Tuple[dict, Dict[str, dict], Dict[str, Set[str]], Dict[str, dict]]:
    with open(state_path, encoding="utf-8") as fh:
        state = json.load(fh)

    meta: Dict[str, dict] = {}
    deps_map: Dict[str, Set[str]] = {}
    inst_index: Dict[str, dict] = {}

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
    with open(state_path, encoding="utf-8") as fh:
        state = json.load(fh)

    addr_to_group: Dict[str, str] = {}
    for gid, entry in manifest.items():
        for addr in entry.get("resource_addresses") or []:
            addr_to_group[addr] = gid

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
    m = re.search(r"registry\.terraform\.io/([^/\"]+)/([^\"]+)", provider_str or "")
    if not m:
        return "aws", "hashicorp/aws"
    namespace, ptype = m.group(1), m.group(2)
    return ptype, f"{namespace}/{ptype}"


def import_id_from_instance(inst: dict) -> Optional[str]:
    attrs = inst.get("attributes") or {}
    for key in ("id", "arn", "name", "self_link", "unique_id", "bucket", "cluster_id", "function_name"):
        val = attrs.get(key)
        if val is not None and str(val).strip() != "":
            return str(val)
    return None


def infer_aws_region_from_state(state: dict) -> str:
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
            import_blocks.append(f"import {{\n  to = {addr}\n  id = \"{safe_id}\"\n}}\n")

    os.makedirs(group_dir, exist_ok=True)

    provider_versions = {
        "hashicorp/aws": "~> 6.0",
        "hashicorp/azurerm": "~> 3.117",
        "hashicorp/google": "~> 6.0",
    }
    versions = 'terraform {\n  required_version = ">= 1.5.0"\n  required_providers {\n'
    for local, source in sorted(providers.items()):
        versions += f'    {local} = {{\n      source = "{source}"\n'
        if source in provider_versions:
            versions += f'      version = "{provider_versions[source]}"\n'
        versions += "    }\n"
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
            orphans_bundle.append({"address": addr, "group_id": gid, "reason": "no_import_id_in_state"})

    report_path = os.path.join(work_root, "registry_mapping_report.json")
    orphans_path = os.path.join(work_root, "orphans_bundle.json")
    reverse_summary = {
        "files_created": len(summary) * 3,
        "groups_scaffolded": len(summary),
        "imports_pending": total_imports,
        "scaffold_paths_per_group": {row["group_id"]: row["imports_path"] for row in summary},
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


# ---------------------------------------------------------------------------
# Section 2: Environment Assignment (Stage A)
# ---------------------------------------------------------------------------

DEFAULT_NAMING_PATTERNS = [
    (r"[-_\.]prod[-_\.]|[-_\.]production[-_\.]|^prod[-_]|[-_]prod$|/prod/", "prod"),
    (r"[-_\.]stg[-_\.]|[-_\.]staging[-_\.]|^stg[-_]|[-_]stg$|/staging/", "staging"),
    (r"[-_\.]dev[-_\.]|[-_\.]development[-_\.]|^dev[-_]|[-_]dev$|/dev/", "dev"),
    (r"[-_\.]test[-_\.]|[-_\.]qa[-_\.]|^test[-_]|[-_]test$|/test/|/qa/", "test"),
    (r"[-_\.]uat[-_\.]|^uat[-_]|[-_]uat$", "uat"),
    (r"[-_\.]preprod[-_\.]|^preprod[-_]|[-_]preprod$", "preprod"),
]

_ENV_NORMALIZATIONS = {
    "production": "prod",
    "prd": "prod",
    "staging": "staging",
    "stg": "staging",
    "stage": "staging",
    "development": "dev",
    "testing": "test",
    "qa": "test",
    "quality-assurance": "test",
}


def normalize_env(env: str) -> str:
    e = env.lower().strip()
    return _ENV_NORMALIZATIONS.get(e, e)


def get_env_tag(addr: str, meta: dict, env_tag_keys: List[str]) -> Optional[str]:
    tags = meta.get(addr, {}).get("tags") or {}
    for key in env_tag_keys:
        val = tags.get(key)
        if val and isinstance(val, str) and val.strip():
            return val.strip()
    return None


def get_app_tag(addr: str, meta: dict, layer3_tag_keys: List[str]) -> Optional[str]:
    tags = meta.get(addr, {}).get("tags") or {}
    for key in layer3_tag_keys:
        val = tags.get(key)
        if val and isinstance(val, str) and val.strip():
            return val.strip().lower()
    return None


def build_reverse_deps(all_addrs: Set[str], deps_map: Dict[str, Set[str]]) -> Dict[str, Set[str]]:
    reverse: Dict[str, Set[str]] = defaultdict(set)
    for addr, deps in deps_map.items():
        if addr not in all_addrs:
            continue
        for dep in deps:
            if dep in all_addrs:
                reverse[dep].add(addr)
    return dict(reverse)


def assign_environments(
    meta: dict,
    deps_map: Dict[str, Set[str]],
    env_tag_keys: List[str],
    naming_patterns=None,
) -> Dict[str, Tuple[str, str]]:
    """Assign every resource an environment with provenance tracking.

    Returns {addr: (env_value, source)} where source ∈ {tag, naming, dep_inherit, default}.
    """
    if naming_patterns is None:
        naming_patterns = DEFAULT_NAMING_PATTERNS

    all_addrs = set(meta.keys())
    reverse_deps = build_reverse_deps(all_addrs, deps_map)
    env_map: Dict[str, Tuple[str, str]] = {}

    # Phase 1: Tag-based (highest confidence)
    for addr in meta:
        env = get_env_tag(addr, meta, env_tag_keys)
        if env:
            env_map[addr] = (normalize_env(env), "tag")

    # Phase 2: Naming regex — scan FULL address (module path + resource name)
    for addr in meta:
        if addr in env_map:
            continue
        for pattern, env_val in naming_patterns:
            if re.search(pattern, addr, re.IGNORECASE):
                env_map[addr] = (env_val, "naming")
                break

    # Phase 3: Dependency inheritance (fixpoint)
    changed = True
    while changed:
        changed = False
        for addr in meta:
            if addr in env_map:
                continue
            neighbor_envs: Counter = Counter()
            for dep in deps_map.get(addr, set()):
                if dep in env_map:
                    neighbor_envs[env_map[dep][0]] += 1
            for dep in reverse_deps.get(addr, set()):
                if dep in env_map:
                    neighbor_envs[env_map[dep][0]] += 1
            if len(neighbor_envs) == 1:
                env_val = next(iter(neighbor_envs))
                env_map[addr] = (env_val, "dep_inherit")
                changed = True
            # On disagreement: defer to "default" (handled in Phase 4)

    # Phase 4: Remainder → "default"
    for addr in meta:
        if addr not in env_map:
            env_map[addr] = ("default", "default")

    return env_map


# ---------------------------------------------------------------------------
# Section 3: Layer Classification (Stage B)
# ---------------------------------------------------------------------------

def classify_layers(
    meta: dict,
    deps_map: Dict[str, Set[str]],
    env_map: Dict[str, Tuple[str, str]],
    taxonomy: Dict[str, Tuple[int, int]],
    layer3_tag_keys: List[str],
    overrides: Optional[dict] = None,
    skip_unknown_type_review: bool = False,
) -> Tuple[Dict[str, int], Dict[str, Tuple[str, str]]]:
    """Classify every resource into a layer.

    Returns:
        layer_map:  {addr: layer_int}
        layer_meta: {addr: (source, confidence)}
    where source ∈ {type_rule, prefix, own_app_tag, app_spread, dependency, provisional,
                    agent_override, agent_accept, agent_type_rule}
    and confidence ∈ {definite, high, medium, low}
    """
    all_addrs = set(meta.keys())
    indegree = compute_indegree(all_addrs, deps_map)
    reverse_deps = build_reverse_deps(all_addrs, deps_map)

    overrides = overrides or {}
    resource_overrides = overrides.get("resource_overrides") or {}
    type_rules_overrides = overrides.get("type_rules") or []
    accept_provisional = set(overrides.get("accept_provisional") or [])

    # Build type-rule lookup from type_rules_overrides (supports glob * suffix)
    def match_type_rule(rtype: str) -> Optional[int]:
        for rule in type_rules_overrides:
            pattern = rule.get("match", "")
            layer = rule.get("layer")
            if layer is None:
                continue
            if pattern.endswith("*"):
                if rtype.startswith(pattern[:-1]):
                    return int(layer)
            elif rtype == pattern:
                return int(layer)
        return None

    layer_map: Dict[str, int] = {}
    layer_meta: Dict[str, Tuple[str, str]] = {}
    ambiguous: Dict[str, Tuple[int, int]] = {}
    # Addresses whose type is genuinely unknown (not in LAYER_TYPE_RULES and not
    # resolved by prefix). By default these always land in the review queue even
    # when they carry a high-confidence own-app tag. Set skip_unknown_type_review=True
    # to let the own-app-tag rule bypass provisional for these types.
    unknown_type_addrs: Set[str] = set()

    # ── Pass 1: Definite assignments ──
    for addr in all_addrs:
        rtype = meta[addr]["type"]

        # Precedence 1: per-resource agent override
        if addr in resource_overrides:
            ro = resource_overrides[addr]
            layer = int(ro.get("layer", 3))
            layer_map[addr] = layer
            layer_meta[addr] = ("agent_override", "definite")
            continue

        # Precedence 2: accept_provisional (agent confirmed guess — keep placement)
        # Will be resolved to floor after cascade; mark and skip re-classification.

        # Precedence 3: agent type_rules
        trl = match_type_rule(rtype)
        if trl is not None:
            layer_map[addr] = trl
            layer_meta[addr] = ("agent_type_rule", "definite")
            continue

        # Precedence 4: customer taxonomy
        if rtype in taxonomy:
            ceiling, floor = taxonomy[rtype]
        elif rtype in LAYER_TYPE_RULES:
            ceiling, floor = LAYER_TYPE_RULES[rtype]
        else:
            resolved = resolve_unknown_type(rtype)
            if resolved:
                ceiling, floor = resolved
            else:
                # Genuinely unknown type — widest possible range; always flag for
                # review so the agent can encode a reusable type_rules generalization.
                ambiguous[addr] = (1, 3)
                unknown_type_addrs.add(addr)
                continue

        if ceiling == floor:
            layer_map[addr] = ceiling
            layer_meta[addr] = ("type_rule", "definite")
        else:
            ambiguous[addr] = (ceiling, floor)

    # ── Pass 2: Resolve ambiguous via app-spread fixpoint ──
    provisional_apps: Dict[str, str] = {}
    for addr in ambiguous:
        app_tag = get_app_tag(addr, meta, layer3_tag_keys)
        if app_tag:
            provisional_apps[addr] = app_tag

    changed = True
    max_iterations = 10
    iteration = 0
    while changed and iteration < max_iterations:
        changed = False
        iteration += 1
        for addr in list(ambiguous.keys()):
            ceiling, floor = ambiguous[addr]
            dependents = reverse_deps.get(addr, set())

            # Count distinct L3 apps that depend on this resource
            dependent_apps: Set[str] = set()
            for d in dependents:
                if d in layer_map and layer_map[d] == 3:
                    app = get_app_tag(d, meta, layer3_tag_keys) or provisional_apps.get(d)
                    if app:
                        dependent_apps.add(app)

            # Own-tag rule: a resource's own app tag is strong L3 evidence unless ≥2 other
            # apps use it — BUT skip this shortcut for genuinely unknown types unless the
            # caller opted out via skip_unknown_type_review=True.
            # Unknown types always go to agent review so the agent can produce a reusable
            # type_rules generalization (e.g. aws_appconfig_* → L3 for all future runs).
            own_app = get_app_tag(addr, meta, layer3_tag_keys)
            if own_app and floor == 3:
                if addr in unknown_type_addrs and not skip_unknown_type_review:
                    pass  # unknown type: fall through to provisional regardless of tag
                else:
                    other_apps = dependent_apps - {own_app}
                    if len(other_apps) < 2:
                        layer_map[addr] = floor
                        layer_meta[addr] = ("own_app_tag", "high")
                        provisional_apps[addr] = own_app
                        del ambiguous[addr]
                        changed = True
                        continue
                # else: tag says one app but ≥2 others consume → fall through to app-spread

            # App-spread rule: shared by ≥2 apps → push toward ceiling (L1 or L2)
            if len(dependent_apps) >= 2:
                layer = max(ceiling, min(2, floor))  # at most L2
                layer_map[addr] = layer
                layer_meta[addr] = ("app_spread", "high")
                del ambiguous[addr]
                changed = True
                continue

            # Single app → floor (most specific layer)
            if len(dependent_apps) == 1:
                layer_map[addr] = floor
                layer_meta[addr] = ("app_spread", "high")
                provisional_apps[addr] = next(iter(dependent_apps))
                del ambiguous[addr]
                changed = True
                continue

            # Dependency-based: what layers do my dependencies live in?
            dep_layers = {layer_map.get(d) for d in deps_map.get(addr, set())}
            dep_layers.discard(None)

            if dep_layers and all(l <= 1 for l in dep_layers) and indegree.get(addr, 0) >= 3:
                # Sits on L1, moderate fan-in → L2
                layer = max(ceiling, 2)
                layer_map[addr] = layer
                layer_meta[addr] = ("dependency", "medium")
                del ambiguous[addr]
                changed = True
                continue

            # High fan-in → shared → L2
            if indegree.get(addr, 0) >= 5:
                layer = max(ceiling, 2)
                layer_map[addr] = layer
                layer_meta[addr] = ("dependency", "medium")
                del ambiguous[addr]
                changed = True

    # ── Pass 3: Remaining ambiguous → provisional + accept_provisional honour ──
    for addr in list(ambiguous.keys()):
        ceiling, floor = ambiguous[addr]
        if addr in accept_provisional:
            # Agent confirmed the script's guess → keep floor, mark accepted
            layer_map[addr] = floor
            layer_meta[addr] = ("agent_accept", "high")
        else:
            layer_map[addr] = floor
            layer_meta[addr] = ("provisional", "low")

    return layer_map, layer_meta


# ---------------------------------------------------------------------------
# Section 4: Cross-Env Shared Resource Detection
# ---------------------------------------------------------------------------

def detect_cross_env_shared(
    layer_map: Dict[str, int],
    env_map: Dict[str, Tuple[str, str]],
    deps_map: Dict[str, Set[str]],
    reverse_deps: Dict[str, Set[str]],
) -> List[dict]:
    """Find resources consumed by multiple environments and promote to L1-global.

    Returns a list of promotion records (also written to layer_summary.json).
    """
    promotions = []
    for addr, layer in list(layer_map.items()):
        if env_map.get(addr, ("",))[0] == "global":
            continue  # already global
        dependents = reverse_deps.get(addr, set())
        consuming_envs = {env_map.get(d, ("default",))[0] for d in dependents}
        consuming_envs.discard("default")
        if len(consuming_envs) >= 2:
            promotions.append({
                "address": addr,
                "original_layer": layer,
                "original_env": env_map.get(addr, ("default",))[0],
                "consuming_envs": sorted(consuming_envs),
                "promoted_to": 1,
                "reason": "cross_env_shared",
            })
            layer_map[addr] = 1
            env_map[addr] = ("global", "cross_env")
    return promotions


# ---------------------------------------------------------------------------
# Section 5: Per-Layer Grouping (Stage C)
# ---------------------------------------------------------------------------

def dominant_type_label(comp: Set[str], meta: dict) -> str:
    """Short label from the most common type in a set of addresses."""
    type_counts: Counter = Counter(meta.get(a, {}).get("type", "unknown") for a in comp)
    dominant = type_counts.most_common(1)[0][0]
    parts = dominant.split("_")
    if len(parts) > 2:
        return "_".join(parts[1:3])  # aws_s3_bucket → s3_bucket
    return dominant


def group_layer1(
    cloud: str,
    env: str,
    addrs: Set[str],
    meta: dict,
    deps_map: Dict[str, Set[str]],
) -> Dict[str, dict]:
    """Group L1 resources: one group per cloud×env, subdivided by connectivity if multiple VPCs."""
    if len(addrs) <= 1:
        gid = f"{cloud}-{env}-l1-foundation"
        return {gid: {
            "layer": 1, "cloud": cloud, "environment": env,
            "resource_addresses": sorted(addrs),
        }}

    # Build adjacency within this L1 bucket (cross-layer edges already severed)
    l1_deps = {a: {d for d in deps_map.get(a, set()) if d in addrs} for a in addrs}
    adj = build_adjacency(addrs, l1_deps)
    components = connected_components(addrs, adj)

    if len(components) == 1:
        gid = f"{cloud}-{env}-l1-foundation"
        return {gid: {
            "layer": 1, "cloud": cloud, "environment": env,
            "resource_addresses": sorted(addrs),
        }}

    manifest: Dict[str, dict] = {}
    for i, comp in enumerate(sorted(components, key=lambda c: -len(c))):
        gid = f"{cloud}-{env}-l1-foundation-{i + 1:02d}"
        manifest[gid] = {
            "layer": 1, "cloud": cloud, "environment": env,
            "resource_addresses": sorted(comp),
        }
    return manifest


def group_layer3(
    cloud: str,
    env: str,
    l3_addrs: Set[str],
    meta: dict,
    deps_map: Dict[str, Set[str]],
    layer_map: Dict[str, int],
    tag_keys: List[str],
    cap: int,
) -> Dict[str, dict]:
    """Group Layer 3 by app tag with tag-conflict detection.

    CRITICAL: sever cross-layer edges before connectivity fallback.
    """
    app_buckets: Dict[str, Set[str]] = defaultdict(set)
    untagged: Set[str] = set()
    tag_conflicts: List[dict] = []

    # Phase A: Tag-based bucketing
    for addr in l3_addrs:
        app = get_app_tag(addr, meta, tag_keys)
        if app:
            app_buckets[app].add(addr)
        else:
            untagged.add(addr)

    # Phase B: Untagged → attach by dependency to tagged app (L3-only edges)
    for addr in list(untagged):
        candidate_apps: Counter = Counter()
        for dep in deps_map.get(addr, set()):
            if layer_map.get(dep) != 3:
                continue  # sever cross-layer edge
            dep_app = get_app_tag(dep, meta, tag_keys)
            if dep_app:
                candidate_apps[dep_app] += 1
        if len(candidate_apps) == 1:
            app = next(iter(candidate_apps))
            app_buckets[app].add(addr)
            untagged.discard(addr)
        elif len(candidate_apps) > 1:
            top_app = candidate_apps.most_common(1)[0][0]
            app_buckets[top_app].add(addr)
            untagged.discard(addr)
            tag_conflicts.append({
                "address": addr,
                "candidate_apps": dict(candidate_apps),
                "assigned_to": top_app,
            })

    # Phase C: Remaining untagged → connectivity clustering (L3-only edges)
    if untagged:
        l3_only_deps = {
            a: {d for d in deps_map.get(a, set()) if d in untagged and layer_map.get(d) == 3}
            for a in untagged
        }
        adj = build_adjacency(untagged, l3_only_deps)
        for comp in connected_components(untagged, adj):
            label = dominant_type_label(comp, meta)
            app_buckets[f"untagged-{label}"].update(comp)

    # Phase D: Build manifest + cap enforcement
    manifest: Dict[str, dict] = {}
    for app_name, addrs in sorted(app_buckets.items()):
        conflicts_for_app = [tc for tc in tag_conflicts if tc["assigned_to"] == app_name]
        eff_cap = cap if cap > 0 else len(addrs) + 1

        if len(addrs) <= eff_cap:
            gid = f"{cloud}-{env}-l3-{sanitize(app_name)}"
            manifest[gid] = {
                "layer": 3, "cloud": cloud, "environment": env,
                "app": app_name,
                "resource_addresses": sorted(addrs),
                "tag_conflicts": conflicts_for_app,
            }
        else:
            # BFS cap-split over THIS bucket's own L3-only edges
            bucket_deps = {
                a: {d for d in deps_map.get(a, set())
                    if d in addrs and layer_map.get(d) == 3}
                for a in addrs
            }
            bucket_adj = build_adjacency(addrs, bucket_deps)
            seed_keys_local = {a: meta[a]["seed_key"] for a in addrs}
            for i, chunk in enumerate(cap_split_bfs(addrs, bucket_adj, eff_cap, seed_keys_local)):
                gid = f"{cloud}-{env}-l3-{sanitize(app_name)}-{i + 1:02d}"
                manifest[gid] = {
                    "layer": 3, "cloud": cloud, "environment": env,
                    "app": app_name,
                    "resource_addresses": sorted(chunk),
                    "tag_conflicts": conflicts_for_app if i == 0 else [],
                }
    return manifest


def group_all_layers(
    layer_map: Dict[str, int],
    env_map: Dict[str, Tuple[str, str]],
    meta: dict,
    deps_map: Dict[str, Set[str]],
    layer3_tag_keys: List[str],
    cap: int,
    env_scope: str = "all",
) -> Dict[str, dict]:
    """Group resources within each layer.

    env_scope:
      "all"  — L1, L2, L3 all scoped by env (default)
      "l2l3" — only L2 and L3; L1 is one group per cloud
      "l2"   — only L2; L1 and L3 ignore env
    """
    manifest: Dict[str, dict] = {}
    buckets: Dict[Tuple[str, str, int], Set[str]] = defaultdict(set)

    for addr, layer in layer_map.items():
        cloud = meta[addr]["cloud"]
        env = env_map[addr][0]

        # Apply env_scope
        if env_scope == "l2" and layer != 2:
            env = "all"
        elif env_scope == "l2l3" and layer == 1:
            env = "all"

        buckets[(cloud, env, layer)].add(addr)

    for (cloud, env, layer), addrs in sorted(buckets.items()):
        if layer == 1:
            manifest.update(group_layer1(cloud, env, addrs, meta, deps_map))
        elif layer == 2:
            gid = f"{cloud}-{env}-l2-platform"
            manifest[gid] = {
                "layer": 2, "cloud": cloud, "environment": env,
                "resource_addresses": sorted(addrs),
            }
        elif layer == 3:
            manifest.update(group_layer3(
                cloud, env, addrs, meta, deps_map, layer_map,
                layer3_tag_keys, cap,
            ))

    return manifest


# ---------------------------------------------------------------------------
# Section 6: Upstream Refs + Remote State Scaffold (Stage D)
# ---------------------------------------------------------------------------

def compute_upstream_refs(manifest: Dict[str, dict], deps_map: Dict[str, Set[str]], layer_map: Dict[str, int]) -> None:
    """Track cross-layer dependency edges as upstream references (mutates manifest in place)."""
    group_lookup: Dict[str, str] = {}
    for gid, entry in manifest.items():
        for addr in entry.get("resource_addresses") or []:
            group_lookup[addr] = gid

    for gid, entry in manifest.items():
        refs = []
        seen: Set[Tuple] = set()
        for addr in entry.get("resource_addresses") or []:
            for dep in deps_map.get(addr, set()):
                dep_group = group_lookup.get(dep)
                if dep_group and dep_group != gid:
                    ref_key = (addr, dep, dep_group)
                    if ref_key not in seen:
                        seen.add(ref_key)
                        refs.append({
                            "from_address": addr,
                            "to_address": dep,
                            "to_group": dep_group,
                            "to_layer": layer_map.get(dep),
                        })
        entry["upstream_refs"] = refs


def scaffold_remote_state(group_dir: str, group_id: str, upstream_refs: List[dict]) -> None:
    """Generate upstream.tf with terraform_remote_state data sources (TODO markers)."""
    if not upstream_refs:
        return

    upstream_groups: Dict[str, dict] = {}
    for ref in upstream_refs:
        gid = ref["to_group"]
        if gid not in upstream_groups:
            upstream_groups[gid] = {
                "layer": ref["to_layer"],
                "addresses_referenced": [],
            }
        upstream_groups[gid]["addresses_referenced"].append(ref["to_address"])

    lines = ["# Auto-generated upstream references (cross-layer dependencies)\n"]
    lines.append("# TODO: Configure backend paths for your environment\n\n")

    for upstream_gid, info in sorted(upstream_groups.items()):
        safe_name = sanitize_identifier(upstream_gid)
        lines.append(f'data "terraform_remote_state" "{safe_name}" {{\n')
        lines.append(f'  backend = "local" # TODO: replace with your backend (s3, gcs, etc.)\n')
        lines.append(f'  config = {{\n')
        lines.append(f'    path = "../{upstream_gid}/terraform.tfstate" # TODO: real path\n')
        lines.append(f'  }}\n')
        lines.append(f'}}\n\n')
        lines.append(f'# Referenced resources from {upstream_gid} (layer {info["layer"]}):\n')
        for addr in sorted(set(info["addresses_referenced"])):
            lines.append(f'#   {addr}\n')
        lines.append(f'# TODO: map to specific outputs, e.g.:\n')
        lines.append(f'#   data.terraform_remote_state.{safe_name}.outputs.<output_name>\n\n')

    os.makedirs(group_dir, exist_ok=True)
    upstream_path = os.path.join(group_dir, "upstream.tf")
    with open(upstream_path, "w", encoding="utf-8") as fh:
        fh.writelines(lines)


# ---------------------------------------------------------------------------
# Section 7: Impact-Ranked Review Queue
# ---------------------------------------------------------------------------

def build_review_queue(
    meta: dict,
    deps_map: Dict[str, Set[str]],
    layer_map: Dict[str, int],
    layer_meta: Dict[str, Tuple[str, str]],
    reverse_deps: Dict[str, Set[str]],
    layer3_tag_keys: List[str],
) -> dict:
    """Build an impact-ranked review queue for low-confidence assignments.

    Triage:
      high_impact  (≤ 50)  — agent reviews individually
      batch_rules  (≤ 10)  — type-pattern batches, agent confirms once
      auto_assigned (rest) — script's best guess, logged for audit
    """
    items: List[dict] = []
    for addr, (source, confidence) in layer_meta.items():
        if confidence not in ("low", "provisional"):
            continue  # only review low-confidence assignments

        dependents = reverse_deps.get(addr, set())
        deps = deps_map.get(addr, set())

        # Impact score
        impact = len(dependents) * 2

        # Cross-layer boundary bonus
        crosses = sum(
            1 for d in dependents
            if layer_map.get(d) is not None and layer_map.get(d) != layer_map.get(addr)
        )
        impact += crosses * 5

        # Tag conflict bonus (resource depended on by multiple apps)
        app_tags: Set[str] = set()
        for d in dependents:
            app = get_app_tag(d, meta, layer3_tag_keys)
            if app:
                app_tags.add(app)
        if len(app_tags) > 1:
            impact += 10

        rtype = meta[addr]["type"]
        items.append({
            "address": addr,
            "resource_type": rtype,
            "tags": meta[addr].get("tags", {}),
            "current_layer": layer_map[addr],
            "range": list(LAYER_TYPE_RULES.get(rtype, (1, 3))),
            "indegree": len(dependents),
            "depends_on": sorted(deps)[:10],
            "depended_on_by": sorted(dependents)[:10],
            "impact_score": impact,
            "reason": source,
        })

    # Sort by impact (highest first)
    items.sort(key=lambda x: -x["impact_score"])

    high_impact = items[:50]
    remaining = items[50:]

    # Batch remaining by type pattern
    type_groups: Dict[str, List[dict]] = defaultdict(list)
    for item in remaining:
        type_groups[item["resource_type"]].append(item)

    batch_rules: List[dict] = []
    auto_assigned: List[dict] = []
    for rtype, group in sorted(type_groups.items(), key=lambda x: -len(x[1])):
        if len(batch_rules) < 10 and len(group) >= 3:
            batch_rules.append({
                "resource_type": rtype,
                "count": len(group),
                "current_layer": group[0]["current_layer"],
                "sample_addresses": [g["address"] for g in group[:5]],
                "suggested_layer": group[0]["current_layer"],
            })
        else:
            auto_assigned.extend(group)

    return {
        "high_impact": high_impact,
        "batch_rules": batch_rules,
        "auto_assigned": auto_assigned,
        "summary": {
            "total_review": len(items),
            "high_impact_count": len(high_impact),
            "batch_rule_count": len(batch_rules),
            "auto_assigned_count": len(auto_assigned),
        },
    }


# ---------------------------------------------------------------------------
# Section 7.5: Load overrides.json (Pass 2 write-back)
# ---------------------------------------------------------------------------

def load_overrides(overrides_path: str) -> dict:
    """Load overrides.json and detect stale keys (addresses no longer in state)."""
    if not overrides_path or not os.path.isfile(overrides_path):
        return {}
    with open(overrides_path, encoding="utf-8") as fh:
        return json.load(fh)


def load_taxonomy(work_root: str) -> Dict[str, Tuple[int, int]]:
    """Load customer type→layer overrides from layer_taxonomy.json."""
    path = os.path.join(work_root, "layer_taxonomy.json")
    if not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as fh:
        raw = json.load(fh)
    taxonomy: Dict[str, Tuple[int, int]] = {}
    for rtype, val in raw.items():
        if isinstance(val, list) and len(val) == 2:
            taxonomy[rtype] = (int(val[0]), int(val[1]))
        elif isinstance(val, int):
            taxonomy[rtype] = (val, val)
    return taxonomy


def check_stale_overrides(overrides: dict, all_addrs: Set[str]) -> List[str]:
    """Report override addresses no longer present in state."""
    stale = []
    for addr in (overrides.get("resource_overrides") or {}):
        if addr not in all_addrs:
            stale.append(addr)
    for addr in (overrides.get("accept_provisional") or []):
        if addr not in all_addrs:
            stale.append(addr)
    return stale


# ---------------------------------------------------------------------------
# Section 8: Main layered split command
# ---------------------------------------------------------------------------

def cmd_layered_split(
    work_root: str,
    state_path: str,
    cap: int,
    overrides_path: Optional[str] = None,
    env_tag_keys: Optional[List[str]] = None,
    layer3_tag_keys: Optional[List[str]] = None,
    env_scope: str = "all",
    skip_unknown_type_review: bool = False,
) -> int:
    """Full layered split pipeline:
    Stage A → env assign
    Stage B → layer classify
    cross-env → promote shared
    Stage C → per-layer group
    Stage D → upstream refs + scaffold upstream.tf
    review queue → review_items.json
    extract states → groups/<id>/terraform.tfstate
    scaffold registry → versions/providers/imports.tf
    reconcile → reconcile_result.json
    """
    if env_tag_keys is None:
        env_tag_keys = ["env", "environment", "Environment", "stage", "Stage"]
    if layer3_tag_keys is None:
        layer3_tag_keys = ["app", "application", "Application", "service", "team", "project"]

    os.makedirs(work_root, exist_ok=True)

    # Load state
    state, meta, deps_map, _inst_index = load_state_index(state_path)
    all_addrs = set(meta.keys())

    # Load customer taxonomy + overrides
    taxonomy = load_taxonomy(work_root)
    overrides = load_overrides(overrides_path) if overrides_path else {}
    stale_overrides = check_stale_overrides(overrides, all_addrs)

    # Write inventory
    write_inventory(state_path, work_root)

    # Stage A — Environment assignment
    env_map = assign_environments(meta, deps_map, env_tag_keys)

    # Stage B — Layer classification
    layer_map, layer_meta = classify_layers(
        meta, deps_map, env_map, taxonomy, layer3_tag_keys, overrides,
        skip_unknown_type_review=skip_unknown_type_review,
    )

    # Cross-env shared detection
    reverse_deps = build_reverse_deps(all_addrs, deps_map)
    promotions = detect_cross_env_shared(layer_map, env_map, deps_map, reverse_deps)

    # Stage C — Per-layer grouping
    eff_cap = normalize_cap(cap, len(all_addrs))
    manifest = group_all_layers(
        layer_map, env_map, meta, deps_map,
        layer3_tag_keys, cap, env_scope,
    )

    # Stage D — Upstream refs
    compute_upstream_refs(manifest, deps_map, layer_map)

    # Stamp cross_env_promoted on affected L1 groups
    promoted_addrs = {p["address"] for p in promotions}
    for gid, entry in manifest.items():
        if entry.get("layer") == 1 and entry.get("environment") == "global":
            group_addrs = set(entry.get("resource_addresses") or [])
            if group_addrs & promoted_addrs:
                entry.setdefault("notes", {})["cross_env_promoted"] = True

    # Build review queue
    review_queue = build_review_queue(
        meta, deps_map, layer_map, layer_meta, reverse_deps, layer3_tag_keys
    )

    # Layer distribution stats
    layer_dist: Dict[str, int] = Counter(str(v) for v in layer_map.values())
    env_dist: Dict[str, int] = Counter(v[0] for v in env_map.values())
    source_dist: Dict[str, int] = Counter(v[0] for v in layer_meta.values())
    confidence_dist: Dict[str, int] = Counter(v[1] for v in layer_meta.values())

    layer_summary = {
        "strategy": "layered_three_tier",
        "resource_count": len(all_addrs),
        "group_count": len(manifest),
        "layer_distribution": dict(layer_dist),
        "env_distribution": dict(env_dist),
        "layer_source_distribution": dict(source_dist),
        "confidence_distribution": dict(confidence_dist),
        "cross_env_promotions": promotions,
        "stale_overrides": stale_overrides,
        "review_summary": review_queue["summary"],
        "env_scope": env_scope,
        "skip_unknown_type_review": skip_unknown_type_review,
        "cap": cap,
    }

    # Write primary outputs
    manifest_path = os.path.join(work_root, "logical_group_manifest.json")
    review_path = os.path.join(work_root, "review_items.json")
    summary_path = os.path.join(work_root, "layer_summary.json")
    shard_path = os.path.join(work_root, "shard_manifest.json")
    counts_path = os.path.join(work_root, "per_group_resource_counts.json")

    # Strip upstream_refs from manifest before writing (stored separately to keep manifest clean)
    manifest_clean = {}
    for gid, entry in manifest.items():
        e = {k: v for k, v in entry.items() if k != "upstream_refs"}
        manifest_clean[gid] = e

    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest_clean, fh, indent=2, sort_keys=True)
    with open(shard_path, "w", encoding="utf-8") as fh:
        json.dump(manifest_clean, fh, indent=2, sort_keys=True)
    per_group = {gid: len(e.get("resource_addresses") or []) for gid, e in manifest_clean.items()}
    with open(counts_path, "w", encoding="utf-8") as fh:
        json.dump(per_group, fh, indent=2, sort_keys=True)
    with open(review_path, "w", encoding="utf-8") as fh:
        json.dump(review_queue, fh, indent=2)
    with open(summary_path, "w", encoding="utf-8") as fh:
        json.dump(layer_summary, fh, indent=2)

    # Extract per-group state shards
    group_paths = extract_group_states(state_path, work_root, manifest_clean)

    # Scaffold HCL (versions/providers/imports.tf) + upstream.tf
    for gid, entry in manifest.items():
        state_shard = group_paths.get(gid) or os.path.join(work_root, "groups", gid, "terraform.tfstate")
        if os.path.isfile(state_shard):
            group_dir = os.path.join(work_root, "groups", gid)
            scaffold_group_dir(group_dir, gid, state_shard)
            upstream_refs = entry.get("upstream_refs") or []
            if upstream_refs:
                scaffold_remote_state(group_dir, gid, upstream_refs)

    # Reconcile
    result = reconcile(state_path, manifest_clean)
    result_path = os.path.join(work_root, "reconcile_result.json")
    with open(result_path, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)

    # Write compact handoff file for ingest runner
    work_dir = os.path.join(work_root, ".work")
    os.makedirs(work_dir, exist_ok=True)
    handoff_path = os.path.join(work_dir, "ingest-handoff.txt")
    with open(handoff_path, "w", encoding="utf-8") as fh:
        fh.write(f"logical_group_manifest_path={manifest_path}\n")
        fh.write(f"group_count={len(manifest_clean)}\n")
        fh.write(f"aggregate_group_resource_count={sum(per_group.values())}\n")
        fh.write(f"monolith_resource_count={result['monolith_resource_count']}\n")
        fh.write(f"count_reconciliation_ok={str(result['count_reconciliation_ok']).lower()}\n")
        fh.write(f"grouping_strategy=layered_three_tier\n")
        fh.write(f"review_items_path={review_path}\n")
        fh.write(f"high_impact_count={review_queue['summary']['high_impact_count']}\n")
        fh.write(f"layer_summary_path={summary_path}\n")

    # Print handoff keys (stdout for runner)
    print(f"logical_group_manifest_path={manifest_path}")
    print(f"group_count={len(manifest_clean)}")
    print(f"aggregate_group_resource_count={sum(per_group.values())}")
    print(f"monolith_resource_count={result['monolith_resource_count']}")
    print(f"grouping_strategy=layered_three_tier")
    print(f"max_resources_per_appstack={cap_label(cap)}")
    print(f"count_reconciliation_ok={str(result['count_reconciliation_ok']).lower()}")
    print(f"reconcile_result_path={result_path}")
    print(f"review_items_path={review_path}")
    print(f"high_impact_count={review_queue['summary']['high_impact_count']}")
    print(f"batch_rule_count={review_queue['summary']['batch_rule_count']}")
    print(f"auto_assigned_count={review_queue['summary']['auto_assigned_count']}")
    print(f"layer_summary_path={summary_path}")
    print(f"cross_env_promotions={len(promotions)}")
    if stale_overrides:
        print(f"stale_overrides={json.dumps(stale_overrides)}", file=sys.stderr)

    return 0 if result["count_reconciliation_ok"] else 1


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: tfstate_monolith_decomposer.py <split|reconcile|extract-states|inventory|scaffold-registry|prepare-parallel-artifacts> ...",
            file=sys.stderr,
        )
        return 2

    cmd = sys.argv[1]

    if cmd == "split":
        # split <work_root> <state_path> [cap] [--overrides <path>]
        # [--env-tag-keys k1,k2] [--layer3-tag-keys k1,k2] [--env-scope all|l2l3|l2]
        if len(sys.argv) < 4:
            print("usage: tfstate_monolith_decomposer.py split <work_root> <state_path> [cap] [--overrides <path>]", file=sys.stderr)
            return 2

        work_root = sys.argv[2]
        state_path = sys.argv[3]

        # Parse optional cap (positional, before flags)
        cap = UNLIMITED_CAP_SENTINEL
        flag_start = 4
        if len(sys.argv) > 4 and not sys.argv[4].startswith("--"):
            try:
                cap = int(sys.argv[4])
                flag_start = 5
            except ValueError:
                pass

        # Parse flags
        overrides_path: Optional[str] = None
        env_tag_keys: Optional[List[str]] = None
        layer3_tag_keys: Optional[List[str]] = None
        env_scope = "all"
        skip_unknown_type_review = False

        args = sys.argv[flag_start:]
        i = 0
        while i < len(args):
            if args[i] == "--overrides" and i + 1 < len(args):
                overrides_path = args[i + 1]
                i += 2
            elif args[i] == "--env-tag-keys" and i + 1 < len(args):
                env_tag_keys = [k.strip() for k in args[i + 1].split(",") if k.strip()]
                i += 2
            elif args[i] == "--layer3-tag-keys" and i + 1 < len(args):
                layer3_tag_keys = [k.strip() for k in args[i + 1].split(",") if k.strip()]
                i += 2
            elif args[i] == "--env-scope" and i + 1 < len(args):
                env_scope = args[i + 1]
                i += 2
            elif args[i] == "--skip-unknown-type-review":
                skip_unknown_type_review = True
                i += 1
            else:
                i += 1

        return cmd_layered_split(
            work_root, state_path, cap,
            overrides_path=overrides_path,
            env_tag_keys=env_tag_keys,
            layer3_tag_keys=layer3_tag_keys,
            env_scope=env_scope,
            skip_unknown_type_review=skip_unknown_type_review,
        )

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

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
