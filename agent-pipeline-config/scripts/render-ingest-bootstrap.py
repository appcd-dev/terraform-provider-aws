#!/usr/bin/env python3
"""Render ingest-bootstrap.sh from live module templates.

tofu output -raw ingest_bootstrap_script reads the value frozen at last apply;
template edits do not flow to preload until apply. Preload uses this renderer so
WORK_ROOT fallback fixes reach the runner without a full deployment apply.
"""
from __future__ import annotations

import hashlib
import pathlib
import re
import sys


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def render_template(text: str, variables: dict[str, str]) -> str:
    for key, value in variables.items():
        text = text.replace("${" + key + "}", value)
    return re.sub(r"\$\$\{", "${", text)


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: render-ingest-bootstrap.py <module-src> <script-pack-preload-dir>",
            file=sys.stderr,
        )
        return 2

    module = pathlib.Path(sys.argv[1]).resolve()
    preload_dir = sys.argv[2].rstrip("/")
    pack = module / "scripts"
    maps = module / "mappings"
    version = preload_dir.rsplit("/", 1)[-1]

    variables = {
        "runner_work_home": "/home/runner",
        "script_pack_preload_dir": preload_dir,
        "script_pack_version": version,
        "script_pack_release_repo": "Walmart-StackGen/Nile-Factory",
        "script_pack_tarball_url": (
            "https://github.com/Walmart-StackGen/Nile-Factory/releases/download/"
            f"pack-{version}/script-pack-{version}.tar.gz"
        ),
        "script_pack_allocate_sha256": sha256(pack / "allocate_manifest.py"),
        "script_pack_decomposer_sha256": sha256(pack / "tfstate_monolith_decomposer.py"),
        "script_pack_runner_sha256": sha256(pack / "stage-runner.sh"),
        "script_pack_catalog_py_sha256": sha256(pack / "azure_mapping_catalog.py"),
        "script_pack_catalog_json_sha256": sha256(maps / "aws-to-azure.json"),
        "script_pack_gcp_catalog_py_sha256": sha256(pack / "gcp_mapping_catalog.py"),
        "script_pack_gcp_catalog_json_sha256": sha256(maps / "aws-to-gcp.json"),
        "default_grouping_strategy": "tfstate_monolith_decomposer",
        "default_max_resources_per_appstack": "0",
    }

    helpers = render_template(
        (module / "templates/dbsplit-script-pack-env.sh.tftpl").read_text(),
        variables,
    )
    ingest = (module / "templates/ingest-execute-series-embedded.sh.tftpl").read_text()
    ingest = ingest.replace("${dbsplit_script_pack_preload_helpers}", helpers)
    sys.stdout.write(render_template(ingest, variables))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
