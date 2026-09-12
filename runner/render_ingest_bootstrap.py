#!/usr/bin/env python3
"""Render pack bootstrap scripts the same way the OpenTofu module does, without tofu.

Writes ingest-bootstrap.sh, iac-pr-bootstrap.sh, and converge-bootstrap.sh so stage
notes only paste thin one-liners (session 9c88eca9: huge IAC_PR/CONVERGE heredocs
were "unavailable" to the agent).
"""

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

    version = (
        (dest / "stage-runner.sh")
        .read_text()
        .split('SCRIPT_PACK_VERSION="', 1)[1]
        .split('"', 1)[0]
    )
    release_repo = "Walmart-StackGen/Nile-Factory"
    tarball_url = (
        f"https://github.com/{release_repo}/releases/download/"
        f"pack-{version}/script-pack-{version}.tar.gz"
    )
    mapping = {
        "script_pack_version": version,
        "script_pack_preload_dir": str(runtime_dest),
        "script_pack_tarball_url": tarball_url,
        "script_pack_release_repo": release_repo,
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
        "default_iac_repository_url": "https://github.com/Walmart-StackGen/Nile-Factory.git",
        "default_branch": "main",
    }
    helpers = tf_render(helper_tpl, mapping)
    mapping["dbsplit_script_pack_preload_helpers"] = helpers

    bootstraps = (
        ("ingest-execute-series-embedded.sh.tftpl", "ingest-bootstrap.sh"),
        ("iac-pr-execute-series-embedded.sh.tftpl", "iac-pr-bootstrap.sh"),
        ("converge-execute-series-embedded.sh.tftpl", "converge-bootstrap.sh"),
    )
    for tpl_name, out_name in bootstraps:
        tpl = (module / "templates" / tpl_name).read_text()
        out = dest / out_name
        out.write_text(tf_render(tpl, mapping))
        out.chmod(0o755)
        print(f"wrote {out} version={mapping['script_pack_version']} bytes={out.stat().st_size}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
