#!/usr/bin/env python3
"""Render ingest-bootstrap.sh the same way the OpenTofu module does, without tofu."""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def tf_render(text: str, mapping: dict[str, str]) -> str:
    text = text.replace("$${", "\x00{")
    for key, value in mapping.items():
        text = text.replace("${" + key + "}", value)
    return text.replace("\x00{", "${")


def main() -> int:
    dest = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/runner/.aws-migrator/script-pack")
    # Where the pack will sit when the runner executes it, which differs from dest
    # when the build stages the pack outside HOME.
    runtime_dest = Path(sys.argv[2]) if len(sys.argv) > 2 else dest
    module = Path("agent-pipeline-config/modules/aios-agent-aws-migrator")
    helper_tpl = (module / "templates/dbsplit-script-pack-env.sh.tftpl").read_text()
    ingest_tpl = (module / "templates/ingest-execute-series-embedded.sh.tftpl").read_text()

    mapping = {
        "script_pack_version": (dest / "stage-runner.sh")
        .read_text()
        .split('SCRIPT_PACK_VERSION="', 1)[1]
        .split('"', 1)[0],
        "script_pack_preload_dir": str(runtime_dest),
        "script_pack_allocate_sha256": sha256_file(dest / "allocate_manifest.py"),
        "script_pack_decomposer_sha256": sha256_file(dest / "tfstate_monolith_decomposer.py"),
        "script_pack_runner_sha256": sha256_file(dest / "stage-runner.sh"),
        "script_pack_catalog_py_sha256": sha256_file(dest / "azure_mapping_catalog.py"),
        "script_pack_catalog_json_sha256": sha256_file(dest / "mappings/aws-to-azure.json"),
        "script_pack_gcp_catalog_py_sha256": sha256_file(dest / "gcp_mapping_catalog.py"),
        "script_pack_gcp_catalog_json_sha256": sha256_file(dest / "mappings/aws-to-gcp.json"),
        "runner_work_home": "/home/runner",
        "default_grouping_strategy": "tfstate_monolith_decomposer",
        "default_max_resources_per_appstack": "0",
    }
    helpers = tf_render(helper_tpl, mapping)
    mapping["dbsplit_script_pack_preload_helpers"] = helpers
    dest.joinpath("ingest-bootstrap.sh").write_text(tf_render(ingest_tpl, mapping))
    dest.joinpath("ingest-bootstrap.sh").chmod(0o755)
    print(f"wrote {dest / 'ingest-bootstrap.sh'} version={mapping['script_pack_version']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
