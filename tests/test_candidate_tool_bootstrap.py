# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Exercise train-bound packaging and actual installation without a release download."""

import hashlib
import json
import os
import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, **kwargs):
    return subprocess.run(
        arguments, check=True, capture_output=True, text=True, **kwargs
    )


@pytest.fixture
def staged_tools(tmp_path):
    source = tmp_path / "frozen-inputs" / "gha-tools"
    tools = source / "tools"
    tools.mkdir(parents=True)
    helper = tools / "rapids-conda-retry"
    helper.write_text("#!/bin/bash\nprintf 'frozen-retry-helper\\n'\n")
    helper.chmod(0o755)
    run(["git", "init", "--quiet", str(source)])
    run(["git", "-C", str(source), "add", "tools"])
    run(
        [
            "git",
            "-C",
            str(source),
            "-c",
            "commit.gpgsign=false",
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "--quiet",
            "-m",
            "Fixture tools",
        ]
    )
    revision = run(["git", "-C", str(source), "rev-parse", "HEAD"]).stdout.strip()
    train_file = source.parent / "release-train.json"
    train_file.write_text(
        json.dumps(
            {
                "train_sha256": "a" * 64,
                "build_implementation_revisions": {"gha-tools": revision},
            }
        )
    )
    scripts = tmp_path / "context" / "scripts"
    scripts.mkdir(parents=True)
    shutil.copy2(ROOT / "context/scripts/install-tools", scripts / "install-tools")
    environment = {
        **os.environ,
        "RAPIDS_RELEASE_CANDIDATE_TRAIN_FILE": str(train_file),
        "RELEASE_CANDIDATE_TRAIN_SHA256": "a" * 64,
        "RELEASE_CANDIDATE_GHA_TOOLS_REVISION": revision,
    }
    run(
        ["bash", str(ROOT / "ci/stage-candidate-gha-tools.sh")],
        cwd=tmp_path,
        env=environment,
    )
    return tmp_path, source, scripts, revision, environment


def test_packages_committed_tools_reproducibly_and_installs_without_network(
    staged_tools,
):
    root, source, scripts, revision, environment = staged_tools
    staged = scripts / "candidate-gha-tools"
    archive = staged / "tools.tar.gz"
    original = archive.read_bytes()
    assert original[4:8] == b"\0" * 4  # gzip stores no varying timestamp.
    assert (
        hashlib.sha256(original).hexdigest()
        == (staged / "sha256.txt").read_text().strip()
    )
    (source / "tools/rapids-conda-retry").write_text(
        "uncommitted change must not enter image"
    )
    run(
        ["bash", str(ROOT / "ci/stage-candidate-gha-tools.sh")],
        cwd=root,
        env=environment,
    )
    assert archive.read_bytes() == original
    with tarfile.open(archive) as bundle:
        assert (
            bundle.extractfile("tools/rapids-conda-retry")
            .read()
            .startswith(b"#!/bin/bash")
        )
    output = root / "installed"
    output.mkdir()
    result = run(
        ["bash", str(scripts / "install-tools"), "--gha-tools"],
        env={
            **environment,
            "TOOL_INSTALL_DIR": str(output),
            "GHA_TOOLS_CANDIDATE_REVISION": revision,
            # An invalid release version must never be consulted on this path.
            "GHA_TOOLS_VERSION": "not-a-release",
            "GHA_TOOLS_SHA256": "invalid",
        },
    )
    assert "done installing" in result.stdout
    assert run([str(output / "rapids-conda-retry")]).stdout == "frozen-retry-helper\n"


@pytest.mark.parametrize("change", ["revision", "checksum", "archive", "missing"])
def test_candidate_install_rejects_bad_or_missing_inputs(staged_tools, change):
    root, _, scripts, revision, environment = staged_tools
    staged = scripts / "candidate-gha-tools"
    if change == "revision":
        (staged / "revision.txt").write_text("b" * 40 + "\n")
    elif change == "checksum":
        (staged / "sha256.txt").write_text("b" * 64 + "\n")
    elif change == "archive":
        with (staged / "tools.tar.gz").open("ab") as stream:
            stream.write(b"tampered")
    else:
        (staged / "tools.tar.gz").unlink()
    output = root / "installed"
    output.mkdir()
    result = subprocess.run(
        ["bash", str(scripts / "install-tools"), "--gha-tools"],
        env={
            **environment,
            "TOOL_INSTALL_DIR": str(output),
            "GHA_TOOLS_CANDIDATE_REVISION": revision,
        },
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert list(output.iterdir()) == []


@pytest.mark.parametrize("change", ["train", "revision", "checkout"])
def test_staging_rejects_mismatched_frozen_identity(staged_tools, change):
    root, source, _, _, environment = staged_tools
    if change == "train":
        environment["RELEASE_CANDIDATE_TRAIN_SHA256"] = "b" * 64
    elif change == "revision":
        environment["RELEASE_CANDIDATE_GHA_TOOLS_REVISION"] = "b" * 40
    else:
        run(
            [
                "git",
                "-C",
                str(source),
                "-c",
                "commit.gpgsign=false",
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "commit",
                "--allow-empty",
                "--quiet",
                "-m",
                "Wrong checkout",
            ]
        )
    result = subprocess.run(
        ["bash", str(ROOT / "ci/stage-candidate-gha-tools.sh")],
        cwd=root,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0


def test_ordinary_install_ignores_staged_candidate_archive(staged_tools):
    root, _, scripts, _, environment = staged_tools
    released = root / "released-retry"
    released.write_text("#!/bin/bash\nprintf 'released-retry-helper\\n'\n")
    released.chmod(0o755)
    archive = root / "release.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(released, arcname="rapids-conda-retry")
    tools = root / "fake-download"
    tools.mkdir()
    wget = tools / "wget"
    wget.write_text(
        '#!/bin/bash\nprintf "%s" "$2" > "$FIXTURE_REQUEST"\ncp "$FIXTURE_ARCHIVE" "$4"\n'
    )
    wget.chmod(0o755)
    output = root / "installed"
    output.mkdir()
    request = root / "download-url"
    run(
        ["bash", str(scripts / "install-tools"), "--gha-tools"],
        env={
            **environment,
            "PATH": str(tools) + os.pathsep + environment["PATH"],
            "TOOL_INSTALL_DIR": str(output),
            "GHA_TOOLS_CANDIDATE_REVISION": "",
            "GHA_TOOLS_VERSION": "0.0.213",
            "GHA_TOOLS_SHA256": hashlib.sha256(archive.read_bytes()).hexdigest(),
            "FIXTURE_ARCHIVE": str(archive),
            "FIXTURE_REQUEST": str(request),
        },
    )
    assert (
        request.read_text()
        == "https://github.com/rapidsai/gha-tools/releases/download/v0.0.213/tools.tar.gz"
    )
    assert run([str(output / "rapids-conda-retry")]).stdout == "released-retry-helper\n"


def test_candidate_workflow_stages_tools_before_build_and_passes_explicit_revision(
    tmp_path,
):
    environment = {
        **os.environ,
        "IMAGE_REPO": "ci-conda",
        "LINUX_VER": "ubuntu22.04",
        "CUDA_VER": "12.2.2",
        "PYTHON_VER": "3.14",
        "ARCH": "amd64",
        "RAPIDS_VERSION_MAJOR_MINOR": "26.12",
        "GITHUB_ACTIONS": "true",
        "GITHUB_OUTPUT": str(tmp_path / "output"),
        "CANDIDATE_GHA_TOOLS_SOURCE": "true",
        "RELEASE_CANDIDATE_GHA_TOOLS_REVISION": "a" * 40,
    }
    run(["bash", str(ROOT / "ci/compute-build-args.sh")], cwd=ROOT, env=environment)
    assert (
        f"GHA_TOOLS_CANDIDATE_REVISION={'a' * 40}" in (tmp_path / "output").read_text()
    )
    environment["RELEASE_CANDIDATE_GHA_TOOLS_REVISION"] = ""
    result = subprocess.run(
        ["bash", str(ROOT / "ci/compute-build-args.sh")],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
