# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
import gzip
import json
import os
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_candidate_matrix_preserves_all_production_variants():
    env = {**os.environ, "RAPIDS_VERSION_MAJOR_MINOR": "26.12", "BUILD_TYPE": "branch"}
    production = subprocess.run(
        ["yq", "-o", "json", "matrix.yaml"],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    production = subprocess.run(
        ["jq", "-c", 'include "ci/compute-matrix"; compute_matrix(.)'],
        input=production.stdout,
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    candidate = subprocess.run(
        ["bash", "ci/compute-candidate-matrix.sh"],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    expected = [
        {**{key: value for key, value in row.items() if key != "ARCHES"}, "ARCH": arch}
        for row in json.loads(production.stdout)["include"]
        for arch in row["ARCHES"]
    ]
    assert json.loads(candidate.stdout)["include"] == expected
    assert len(expected) == 208
    assert {row["ARCH"] for row in expected} == {"amd64", "arm64"}
    assert {row["IMAGE_REPO"] for row in expected} == {
        "ci-conda",
        "ci-wheel",
        "citestwheel",
    }


@pytest.mark.parametrize("arch", ["amd64", "arm64"])
def test_archive_retains_real_bytes_and_frozen_identity(tmp_path, arch):
    archive = tmp_path / ".release-candidate-artifacts/container"
    archive.mkdir(parents=True)
    (archive / "image.tar").write_bytes(b"original OCI archive bytes")
    image = "rapidsai/ci-wheel:26.12-cuda13.3.0-rockylinux8-py3.14"
    subprocess.run(
        ["bash", str(ROOT / "ci/prepare-candidate-image.sh")],
        cwd=tmp_path,
        env={
            **os.environ,
            "ARCH": arch,
            "IMAGE_NAME": image,
            "RAPIDS_VERSION_MAJOR_MINOR": "26.12",
        },
        check=True,
    )
    assert (
        gzip.decompress(
            (
                archive / f"image-26.12-cuda13.3.0-rockylinux8-py3.14-{arch}.tar.gz"
            ).read_bytes()
        )
        == b"original OCI archive bytes"
    )
    assert json.loads((archive / "package-identity.json").read_text()) == {
        "ecosystem": "container",
        "name": "docker.io/rapidsai/ci-wheel",
        "version": "26.12",
        "build": f"26.12-cuda13.3.0-rockylinux8-py3.14-{arch}",
        "platform": f"linux/{arch}",
    }


@pytest.mark.parametrize(
    "image,arch",
    [
        ("rapidsai/ci-wheel:latest", "amd64"),
        ("evil/image:tag", "amd64"),
        ("rapidsai/ci-conda:26.12-cuda13.3.0-ubuntu24.04-py3.14", "x86"),
    ],
)
def test_unknown_or_mutable_image_identity_is_rejected(tmp_path, image, arch):
    result = subprocess.run(
        ["bash", str(ROOT / "ci/prepare-candidate-image.sh")],
        cwd=tmp_path,
        env={
            **os.environ,
            "ARCH": arch,
            "IMAGE_NAME": image,
            "RAPIDS_VERSION_MAJOR_MINOR": "26.12",
        },
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert not (tmp_path / ".release-candidate-artifacts").exists()


def test_candidate_workflow_never_logs_in_pushes_or_exports_registry_cache():
    workflow = yaml.safe_load((ROOT / ".github/workflows/build.yaml").read_text())
    for job in workflow["jobs"].values():
        assert "secrets" not in job
        assert job["permissions"].get("packages", "read") == "read"
        for step in job["steps"]:
            assert "docker/login-action" not in step.get("uses", "")
            if "docker/build-push-action" in step.get("uses", ""):
                assert step["with"]["push"] is False
                assert "cache-to" not in step["with"]
                assert step["with"]["outputs"].startswith("type=oci,")
                assert step["with"]["context"] == "context"
    assert "container:ci-images" in (ROOT / ".github/workflows/build.yaml").read_text()


@pytest.mark.parametrize(
    "image_repo,expected_args",
    [
        (
            "ci-conda",
            {
                "CUDA_BASE_IMAGE": "docker.io/nvidia/cuda:13.3.0-base-ubuntu22.04",
                "MINIFORGE_BASE_IMAGE": "docker.io/condaforge/miniforge3:26.1.0-0",
            },
        ),
        (
            "ci-wheel",
            {
                "BASE_IMAGE": "docker.io/nvidia/cuda:13.3.0-devel-rockylinux8",
            },
        ),
        (
            "citestwheel",
            {
                "CUDA_BASE_IMAGE": "docker.io/nvidia/cuda:13.3.0-base-ubuntu22.04",
            },
        ),
    ],
)
def test_candidate_build_args_select_mirror_images(tmp_path, image_repo, expected_args):
    output_file = tmp_path / "github-output"
    env = {
        **os.environ,
        "GITHUB_ACTIONS": "true",
        "GITHUB_OUTPUT": str(output_file),
        "RAPIDS_VERSION_MAJOR_MINOR": "26.12",
        "CUDA_VER": "13.3.0",
        "LINUX_VER": "rockylinux8" if image_repo == "ci-wheel" else "ubuntu22.04",
        "PYTHON_VER": "3.14",
        "ARCH": "amd64",
        "IMAGE_REPO": image_repo,
        "CANDIDATE_IMAGE_MIRROR": "true",
    }
    subprocess.run(["bash", "ci/compute-build-args.sh"], cwd=ROOT, env=env, check=True)

    output = output_file.read_text()
    args_block = output.split("ARGS<<EOT\n", maxsplit=1)[1].split(
        "\nEOT\n", maxsplit=1
    )[0]
    args = {
        key: value.rstrip()
        for key, value in (
            line.split("=", maxsplit=1) for line in args_block.splitlines()
        )
    }
    for key, value in expected_args.items():
        assert args[key] == value
    if image_repo == "citestwheel":
        versions = yaml.safe_load((ROOT / "versions.yaml").read_text())
        assert (
            args["GHA_TOOLS_BOOTSTRAP_VERSION"]
            == versions["GHA_TOOLS_BOOTSTRAP_VERSION"]
        )
        assert (
            args["GHA_TOOLS_BOOTSTRAP_SHA256"] == versions["GHA_TOOLS_BOOTSTRAP_SHA256"]
        )
    if image_repo == "ci-wheel":
        assert "BASE_IMAGE=docker.io/nvidia/cuda:13.3.0-devel-rockylinux8" in output
    assert "dockerhub.nvidia.com" not in output


def test_citestwheel_declares_frozen_gha_tools_build_arguments_before_use():
    dockerfile = (ROOT / "citestwheel.Dockerfile").read_text()
    install_tools = dockerfile.index("/tmp/build-scripts/install-tools")

    for name in ("GHA_TOOLS_BOOTSTRAP_SHA256", "GHA_TOOLS_BOOTSTRAP_VERSION"):
        declaration = f"ARG {name}=notset"
        assert declaration in dockerfile
        assert dockerfile.index(declaration) < install_tools

    first_install = dockerfile.index("/tmp/build-scripts/install-tools")
    assert dockerfile.rfind(
        "GHA_TOOLS_SHA256=${GHA_TOOLS_BOOTSTRAP_SHA256}", 0, first_install
    ) > dockerfile.index("RUN ")
    assert dockerfile.rfind(
        "GHA_TOOLS_VERSION=${GHA_TOOLS_BOOTSTRAP_VERSION}", 0, first_install
    ) > dockerfile.index("RUN ")


def test_normal_build_args_and_dockerfile_defaults_keep_public_images(tmp_path):
    env = {
        **os.environ,
        "GITHUB_ACTIONS": "true",
        "GITHUB_OUTPUT": str(tmp_path / "github-output"),
        "RAPIDS_VERSION_MAJOR_MINOR": "26.12",
        "CUDA_VER": "13.3.0",
        "LINUX_VER": "ubuntu22.04",
        "PYTHON_VER": "3.14",
        "ARCH": "amd64",
        "IMAGE_REPO": "ci-conda",
        "CANDIDATE_IMAGE_MIRROR": "false",
    }
    subprocess.run(["bash", "ci/compute-build-args.sh"], cwd=ROOT, env=env, check=True)
    output = (tmp_path / "github-output").read_text()
    assert "dockerhub.nvidia.com" not in output
    assert "MINIFORGE_BASE_IMAGE=" not in output
    assert "CUDA_BASE_IMAGE=" not in output

    assert (
        "ARG MINIFORGE_BASE_IMAGE=condaforge/miniforge3:${MINIFORGE_VER}"
        in (ROOT / "ci-conda.Dockerfile").read_text()
    )
    assert (
        "ARG BASE_IMAGE=nvidia/cuda:${CUDA_VER}-devel-${LINUX_VER}"
        in (ROOT / "ci-wheel.Dockerfile").read_text()
    )
    assert (
        "ARG CUDA_BASE_IMAGE=nvidia/cuda:${CUDA_VER}-base-${LINUX_VER}"
        in (ROOT / "citestwheel.Dockerfile").read_text()
    )


def test_candidate_workflow_syncs_wheel_environment_from_selected_base_image():
    workflow = yaml.safe_load((ROOT / ".github/workflows/build.yaml").read_text())
    job = workflow["jobs"]["candidate-images"]
    buildx = next(
        step for step in job["steps"] if "setup-buildx-action" in step.get("uses", "")
    )
    args = next(step for step in job["steps"] if step.get("id") == "args")
    sync = next(
        step
        for step in job["steps"]
        if step.get("name") == "Preserve the CI wheel base environment"
    )

    assert "driver-opts" not in buildx["with"]
    assert buildx["with"]["buildkitd-config"] == "/etc/buildkit/buildkitd.toml"
    assert buildx["with"]["buildkitd-flags"] == "--debug"
    assert args["env"]["CANDIDATE_IMAGE_MIRROR"] == "true"
    assert sync["env"]["BASE_IMAGE"] == "${{ steps.args.outputs.BASE_IMAGE }}"
    assert "${BASE_IMAGE}" in sync["run"]


def test_candidate_matrix_checks_host_config_before_expanding_image_matrix():
    workflow = yaml.safe_load((ROOT / ".github/workflows/build.yaml").read_text())
    steps = workflow["jobs"]["candidate-matrix"]["steps"]
    check_index = next(
        index
        for index, step in enumerate(steps)
        if step.get("run") == "ci/check-candidate-buildkit-config.sh"
    )
    matrix_index = next(
        index
        for index, step in enumerate(steps)
        if step.get("run") == "ci/resolve-candidate-train.sh"
    )

    assert check_index < matrix_index


@pytest.mark.parametrize("readable", [True, False])
def test_candidate_buildkit_config_check_is_fail_closed(tmp_path, readable):
    config = tmp_path / "buildkitd.toml"
    if readable:
        config.write_text(
            '[registry."docker.io"]\nmirrors = ["https://mirror.invalid"]\n'
        )
        config.chmod(0o600)

    result = subprocess.run(
        ["bash", str(ROOT / "ci/check-candidate-buildkit-config.sh")],
        env={**os.environ, "CANDIDATE_BUILDKIT_CONFIG": str(config)},
        capture_output=True,
        text=True,
        check=False,
    )

    assert (result.returncode == 0) is readable
    assert "mirror.invalid" not in result.stdout + result.stderr
