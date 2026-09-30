#!/usr/bin/env python3
"""Regression tests for shared-runner Git config races."""
from __future__ import annotations

import os
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent


def run_pack_entry(home: Path, preload: Path) -> subprocess.CompletedProcess[str]:
    env = {
        **os.environ,
        "HOME": str(home),
        "PRELOAD_DIR": str(preload),
        "PACK_VER": "test",
        "GIT_TOKEN": "test-token",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }
    return subprocess.run(
        ["bash", str(SCRIPTS / "pack-entry.sh"), "converge", "wf-git-config-test"],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_concurrent_pack_entry_uses_process_scoped_config() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        home, preload = root / "home", root / "pack"
        cred_dir = home / ".aws-migrator" / "bin"
        home.mkdir()
        preload.mkdir()

        for name in (
            "runner-capability-preflight.sh",
            "cloud2code-aws-scan.sh",
            "ingest-bootstrap.sh",
            "iac-pr-bootstrap.sh",
            "converge-bootstrap.sh",
            "run-destination-stage.sh",
        ):
            (preload / name).write_text(
                '#!/bin/sh\n'
                'test "$(git config --get credential.helper)" = '
                '"$HOME/.aws-migrator/bin/git-credential-stackgen" || exit 31\n'
                'test "${GIT_CONFIG_COUNT:-0}" -ge 1 || exit 32\n'
                'echo git_helper_configured=true\n'
            )

        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: run_pack_entry(home, preload), range(16)))

        for result in results:
            assert result.returncode == 0, result.stderr
            assert "git_helper_configured=true" in result.stdout, result.stdout
        assert not (home / ".gitconfig").exists(), "must not mutate shared ~/.gitconfig"
        assert not list(cred_dir.glob(".git-credential-stackgen.*")), "temporary helper files leaked"
        helper = cred_dir / "git-credential-stackgen"
        assert helper.is_file() and os.access(helper, os.X_OK)


def test_scripts_do_not_write_global_git_config() -> None:
    pack_entry = (SCRIPTS / "pack-entry.sh").read_text()
    preflight = (SCRIPTS / "runner-capability-preflight.sh").read_text()
    stage_runner = (SCRIPTS / "stage-runner.sh").read_text()
    for source in (pack_entry, preflight, stage_runner):
        executable_lines = "\n".join(
            line for line in source.splitlines() if not line.lstrip().startswith("#")
        )
        assert "git config --global" not in executable_lines
        assert "gh auth setup-git" not in executable_lines
    assert "GIT_CONFIG_KEY_${config_count}=credential.helper" in pack_entry
    assert "GIT_CONFIG_KEY_${_git_config_count}=credential.helper" in preflight
    assert "GIT_CONFIG_KEY_${config_count}=user.name" in stage_runner


if __name__ == "__main__":
    test_concurrent_pack_entry_uses_process_scoped_config()
    test_scripts_do_not_write_global_git_config()
    print("OK: git configuration is process-scoped and concurrency-safe")
