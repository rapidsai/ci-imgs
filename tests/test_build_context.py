# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Dockerfile bind-mounted helpers must survive the filtered build context."""

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]


@pytest.mark.parametrize(
    "filename", ["ci-conda.Dockerfile", "ci-wheel.Dockerfile", "citestwheel.Dockerfile"]
)
def test_bind_mounted_helpers_are_included_in_the_build_context(filename):
    contents = (ROOT / filename).read_text()
    allowlist = (ROOT / "context/.dockerignore").read_text().splitlines()
    helpers = set(re.findall(r"/tmp/build-scripts/([a-z][a-z0-9-]*)", contents))

    assert helpers
    assert "*" in allowlist
    for helper in helpers:
        path = ROOT / "context/scripts" / helper
        assert path.is_file(), f"{filename}: helper {helper} is missing"
        assert os.access(path, os.X_OK), (
            f"{filename}: helper {helper} is not executable"
        )
        assert f"!scripts/{helper}" in allowlist, (
            f"{filename}: .dockerignore excludes {helper}"
        )


@pytest.mark.skipif(
    os.environ.get("RAPIDS_TEST_BUILDKIT_CONTEXT") != "1",
    reason="opt-in real Docker/BuildKit probe",
)
def test_buildkit_mount_contains_pyenv_helper_and_excludes_unlisted_files(tmp_path):
    context = tmp_path / "context"
    shutil.copytree(ROOT / "context", context)
    (context / "scripts/should-stay-excluded").write_text("excluded sentinel\n")
    dockerfile = tmp_path / "Dockerfile"
    dockerfile.write_text(
        "FROM busybox:1.37.0 AS verified\n"
        "RUN --mount=type=bind,source=scripts,target=/tmp/build-scripts "
        "test -x /tmp/build-scripts/install-pyenv && "
        "test -x /tmp/build-scripts/install-tools && "
        "test ! -e /tmp/build-scripts/should-stay-excluded && "
        "sha256sum /tmp/build-scripts/install-pyenv > /context-checksum\n"
        "FROM scratch\nCOPY --from=verified /context-checksum /context-checksum\n"
    )
    output = tmp_path / "output"
    result = subprocess.run(
        [
            "docker",
            "buildx",
            "build",
            "--progress=plain",
            "--file",
            str(dockerfile),
            "--output",
            f"type=local,dest={output}",
            str(context),
        ],
        text=True,
        capture_output=True,
        check=False,
        timeout=180,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert (
        (output / "context-checksum")
        .read_text()
        .endswith("  /tmp/build-scripts/install-pyenv\n")
    )
