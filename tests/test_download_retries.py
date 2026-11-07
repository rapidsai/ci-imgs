# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Partial retries must not reach archive extraction or installer execution."""

import io
import os
import subprocess
import tarfile
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]


@pytest.fixture
def transfer(tmp_path):
    binaries = tmp_path / "bin"
    binaries.mkdir()
    archive = tmp_path / "gh.tar.gz"
    payload = b"#!/bin/sh\necho installed-gh\n"
    with tarfile.open(archive, "w:gz") as output:
        entry = tarfile.TarInfo("gh_fixture/bin/gh")
        entry.size = len(payload)
        entry.mode = 0o755
        output.addfile(entry, io.BytesIO(payload))
    downloader = """#!/bin/bash
set -euo pipefail
count=0
if [[ -f "$TEST_CALLS" ]]; then count=$(cat "$TEST_CALLS"); fi
count=$((count + 1))
printf '%s' "$count" > "$TEST_CALLS"
output=-
while (( $# )); do
    case "$1" in -O|--output) output=$2; shift ;; esac
    shift
done
printf '%s\\n' "$output" >> "$TEST_OUTPUTS"
if (( count <= TEST_FAILURES )); then
    printf 'touch "%s"\\n' "$TEST_PREMATURE" > "$output"
    echo 'HTTP 500' >&2
    exit 1
fi
if [[ "$0" == */curl ]]; then
    printf 'printf complete > "%s"\\n' "$TEST_MARKER" > "$output"
else
    cp "$TEST_ARCHIVE" "$output"
fi
"""
    for name, content in {
        "wget": downloader,
        "curl": downloader,
        "unzip": "#!/bin/sh\nexit 0\n",
        "gh": "#!/bin/sh\necho original-gh\n",
        "rapids-retry": """#!/bin/bash
for attempt in 1 2 3; do
    if "$@"; then exit 0; fi
    echo "retry $attempt"
done
exit 1
""",
    }.items():
        path = binaries / name
        path.write_text(content)
        path.chmod(0o755)
    environment = {
        **os.environ,
        "PATH": f"{binaries}:{os.environ['PATH']}",
        "TOOL_INSTALL_DIR": str(binaries),
        "GH_CLI_VER": "2.0.0",
        "CPU_ARCH": "amd64",
        "TEST_ARCHIVE": str(archive),
        "TEST_CALLS": str(tmp_path / "calls"),
        "TEST_OUTPUTS": str(tmp_path / "outputs"),
        "TEST_PREMATURE": str(tmp_path / "premature"),
        "TEST_MARKER": str(tmp_path / "executed"),
        "TMPDIR": str(tmp_path),
    }
    return tmp_path, binaries, environment


@pytest.mark.parametrize("kind", ["gh", "pyenv"])
@pytest.mark.parametrize("failures", [0, 1, 3])
def test_bootstrap_consumes_only_a_completed_download(transfer, kind, failures):
    directory, binaries, environment = transfer
    script = (
        ROOT
        / "context/scripts"
        / ("install-tools" if kind == "gh" else "install-pyenv")
    )
    command = ["bash", str(script), *(["--gh-cli"] if kind == "gh" else [])]
    result = subprocess.run(
        command,
        cwd=directory,
        env={**environment, "TEST_FAILURES": str(failures)},
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    assert (result.returncode == 0) == (failures < 3), result.stdout + result.stderr
    assert (directory / "calls").read_text() == str(min(failures + 1, 3))
    assert not (directory / "premature").exists()
    outputs = (directory / "outputs").read_text().splitlines()
    assert all(path != "-" and not Path(path).exists() for path in outputs)
    if kind == "gh":
        installed = subprocess.check_output([str(binaries / "gh")], text=True).strip()
        assert installed == ("installed-gh" if failures < 3 else "original-gh")
    elif failures < 3:
        assert (directory / "executed").read_text() == "complete"
    else:
        assert not (directory / "executed").exists()


@pytest.mark.parametrize("filename", ["ci-wheel.Dockerfile", "citestwheel.Dockerfile"])
def test_wheel_images_use_the_safe_pyenv_installer(filename):
    contents = (ROOT / filename).read_text()
    assert "/tmp/build-scripts/install-pyenv" in contents
    assert "curl https://pyenv.run | bash" not in contents
