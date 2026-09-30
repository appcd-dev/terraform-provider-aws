"""AWS -> GCP migration mapping catalog resolver.

Loads the versioned JSON catalog (``mappings/aws-to-gcp.json``) and resolves an
AWS Terraform resource type to a deterministic GCP migration decision.

Both ``cmd_gcp_migration_blueprint`` and ``cmd_gcp_iac_generate`` in ``stage-runner.sh``
import this module from ``$WORK_ROOT/scripts`` so mapping choices stay identical across the
two stages. Without this module the stages would invent service mappings.

Emission honesty: ``status=mapped`` means the catalog has a target type. ``emission`` tells
operators what generate actually writes today (scaffold vs service-account-only vs
project placeholder). Review PRs must not treat ``mapped`` as “full GCP equivalent”.
"""

import json
from pathlib import Path

DEFAULT_CATALOG_NAME = "aws-to-gcp.json"

# What cmd_gcp_iac_generate emits for each scaffold category (operator contract).
# Keep in sync with FULL_SCAFFOLD_CATEGORIES + emit blocks in gcp_iac_generate.py.
EMISSION_BY_CATEGORY = {
    "storage": "full_scaffold",
    "network": "full_scaffold",
    "kubernetes": "full_scaffold",
    "vm": "full_scaffold",
    "vmss": "full_scaffold",
    "function": "full_scaffold",
    "database_postgres": "full_scaffold",
    "database_nosql": "full_scaffold",
    "queue": "full_scaffold",
    "event": "full_scaffold",
    "dns": "full_scaffold",
    "cache": "full_scaffold",
    "observability": "profile_scaffold",
    "containers": "full_scaffold",
    "cdn": "profile_scaffold",
    "load_balancer": "full_scaffold",
    "identity": "managed_identity_rbac_scaffold",
    "static_ip": "full_scaffold",
    "api": "profile_scaffold",
    "key_management": "resource_group_only",
    "analytics": "resource_group_only",
    "data_reference": "none",
    "placeholder": "resource_group_only",
    "non_applicable": "none",
}

# Categories where residual risk is not "fill in CIDR/SKU" — keep HITL even when templates exist.
AMBIGUOUS_CATEGORIES = frozenset(
    {
        "load_balancer",
        "kubernetes",
        "containers",
        "vm",
        "vmss",
        "function",
        "cache",
        "database_postgres",
        "database_nosql",
        "cdn",
        "api",
        "key_management",
        "analytics",
        "placeholder",
    }
)

AMBIGUOUS_SOURCE_TYPES = frozenset(
    {
        "aws_internet_gateway",
        "aws_egress_only_internet_gateway",
        "aws_vpn_gateway",
        "aws_customer_gateway",
        "aws_dx_gateway",
    }
)


def default_catalog_path(base=None):
    """Return the first existing catalog path, preferring ``mappings/aws-to-gcp.json``."""
    here = Path(base) if base else Path(__file__).resolve().parent
    candidates = [
        here / "mappings" / DEFAULT_CATALOG_NAME,
        here / DEFAULT_CATALOG_NAME,
        here.parent / "mappings" / DEFAULT_CATALOG_NAME,
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def load_catalog(path=None):
    """Load and lightly validate the mapping catalog JSON."""
    catalog_path = Path(path) if path else default_catalog_path()
    data = json.loads(Path(catalog_path).read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("catalog root must be a JSON object")
    data.setdefault("resource_migration_map", {})
    data.setdefault("migration_classes", {})
    return data


def _class_entry(catalog, migration_class):
    entry = catalog.get("migration_classes", {}).get(migration_class)
    return entry if isinstance(entry, dict) else {}


def _matched_key(resource_map, source_type):
    """Resolve ``source_type`` to a catalog key: exact first, then longest matching prefix."""
    if source_type in resource_map:
        return source_type, "exact"
    best = None
    for key in resource_map:
        if source_type.startswith(key) and (best is None or len(key) > len(best)):
            best = key
    if best is not None:
        return best, "prefix"
    return None, "none"


def emission_for_category(category):
    """Return the generate emission class for a scaffold category."""
    return EMISSION_BY_CATEGORY.get(category or "placeholder", "resource_group_only")


def classify_hitl_lane(decision):
    """Classify a mapping decision into an operator HITL lane (shape/permissions/defer/ambiguous).

    Mirrors the Azure catalog so TODO and review-needed share one triage vocabulary.
    """
    if not isinstance(decision, dict):
        return "ambiguous"
    explicit = (decision.get("hitl_lane") or "").strip()
    if explicit in ("shape", "permissions", "defer", "ambiguous"):
        return explicit
    status = decision.get("status") or ""
    emission = decision.get("emission") or ""
    category = decision.get("category") or ""
    source = decision.get("source_type") or ""
    if status == "non_applicable" or category == "non_applicable" or emission == "none":
        return "defer"
    if emission in ("managed_identity_rbac_scaffold", "managed_identity_scaffold") or category == "identity":
        return "permissions"
    if status != "mapped":
        return "ambiguous"
    if source in AMBIGUOUS_SOURCE_TYPES or category in AMBIGUOUS_CATEGORIES:
        return "ambiguous"
    if emission in ("full_scaffold", "profile_scaffold", "static_ip"):
        return "shape"
    if emission == "resource_group_only":
        return "ambiguous"
    return "ambiguous"


def counts_toward_group_confidence(decision):
    """Return True when a decision should affect the group-level confidence average.

    ``non_applicable`` / ``emission=none`` types must not drag mapped scaffolds below the review
    threshold. Shared with the Azure catalog contract so blueprint scoring stays consistent.
    """
    if not isinstance(decision, dict):
        return False
    if decision.get("status") == "non_applicable":
        return False
    if decision.get("category") == "non_applicable":
        return False
    if decision.get("emission") == "none":
        return False
    return True


def group_confidence(decisions):
    """Average confidence of applicable decisions for a migration group.

    Returns ``(confidence, reason)`` where ``confidence`` is a float rounded to 2 decimals, or
    ``None`` when every decision is non-applicable (``reason="non_applicable_only"``).
    """
    scored = [d for d in (decisions or []) if counts_toward_group_confidence(d)]
    if not scored:
        return None, "non_applicable_only"
    avg = round(sum(float(d.get("confidence") or 0.0) for d in scored) / len(scored), 2)
    return avg, ""


def explain_review_needed(decisions, confidence, confidence_reason, threshold, review_categories):
    """Return ``(review_needed, reasons)`` explaining why a group needs human review.

    Mirrors the Azure helper. ``defer`` does not force actionable HITL; ``permissions`` and
    ``ambiguous`` always do; ``shape`` only when below the confidence threshold.
    """
    reasons = []
    threshold = float(threshold)
    review_categories = set(review_categories or [])

    scored = [d for d in (decisions or []) if counts_toward_group_confidence(d)]
    if confidence is None and confidence_reason == "non_applicable_only":
        # Pure defer groups are visible via primary_hitl_lane=defer — not mandatory HITL.
        return False, []
    if confidence is None:
        reasons.append(
            f"group confidence unavailable ({confidence_reason or 'no_scored_decisions'})"
        )
    elif scored and confidence < threshold:
        reasons.append(f"group confidence {confidence} below threshold {threshold}")

    for decision in decisions or []:
        source = decision.get("source_type") or "unknown"
        status = decision.get("status") or "unknown"
        category = decision.get("category") or ""
        conf = float(decision.get("confidence") or 0.0)
        review = (decision.get("review") or "").strip()
        note = f" — {review}" if review else ""
        lane = classify_hitl_lane(decision)

        if lane == "defer" or status == "non_applicable":
            continue
        if status != "mapped":
            reasons.append(f"{source}: status={status} (ambiguous){note}")
            continue
        if lane == "permissions":
            reasons.append(f"{source}: permissions HITL — translate IAM actions/conditions{note}")
            continue
        if lane == "ambiguous" or category in review_categories:
            reasons.append(f"{source}: ambiguous mapping choice required{note}")
            continue
        if counts_toward_group_confidence(decision) and conf < threshold:
            reasons.append(f"{source}: confidence {conf} below threshold {threshold}{note}")

    deduped = []
    seen = set()
    for reason in reasons:
        if reason in seen:
            continue
        seen.add(reason)
        deduped.append(reason)
    return bool(deduped), deduped


def resolve(catalog, source_type):
    """Resolve an AWS Terraform type to a normalized GCP migration decision."""
    resource_map = catalog.get("resource_migration_map", {})
    matched_key, match_kind = _matched_key(resource_map, source_type)

    if matched_key is None:
        return {
            "source_type": source_type,
            "status": "unsupported",
            "category": "placeholder",
            "emission": "resource_group_only",
            "migration_resource_class": None,
            "gcp_service": "Placeholder Terraform scaffold",
            "default_target": None,
            "target_resource_types": [],
            "companions": [],
            "attribute_mapping": {},
            "confidence": 0.4,
            "review": "No catalog mapping exists for this AWS type; generated root includes a project scaffold and a review note only.",
            "match_kind": "none",
            "hitl_lane": "ambiguous",
        }

    entry = resource_map[matched_key]
    migration_class = entry.get("migration_resource_class")
    class_entry = _class_entry(catalog, migration_class) if migration_class else {}
    status = "non_applicable" if migration_class == "non_applicable" else "mapped"
    category = entry.get("category") or migration_class or "placeholder"
    emission = emission_for_category(category)
    if status == "non_applicable":
        emission = "none"

    default_target = entry.get("default_target_resource_type")
    target_types = list(class_entry.get("target_resource_types") or [])
    if default_target and default_target not in target_types:
        target_types = [default_target] + target_types

    attribute_mapping = {}
    attr = class_entry.get("attribute_mapping")
    if isinstance(attr, dict):
        attribute_mapping = attr.get(matched_key) or attr.get(source_type) or {}

    review = entry.get("review") or "Review the GCP equivalent configuration before production use."
    if emission == "managed_identity_scaffold":
        review = (
            f"{review} Emission=managed_identity_scaffold: generate emits a service account only; "
            "IAM role bindings are documented for operators, not auto-authored."
        )

    decision = {
        "source_type": source_type,
        "status": status,
        "category": category,
        "emission": emission,
        "migration_resource_class": migration_class,
        "gcp_service": entry.get("gcp_service_label") or default_target or "Review-only (no direct GCP equivalent)",
        "default_target": default_target,
        "target_resource_types": target_types,
        "companions": list(entry.get("companion_resource_types") or []),
        "attribute_mapping": attribute_mapping,
        "confidence": float(entry.get("confidence", 0.6)),
        "review": review,
        "match_kind": match_kind,
    }
    if entry.get("hitl_lane"):
        decision["hitl_lane"] = entry.get("hitl_lane")
    decision["hitl_lane"] = classify_hitl_lane(decision)
    return decision
