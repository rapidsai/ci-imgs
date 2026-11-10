# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Private cache failures must preserve a real build and artifact verification."""

import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "private_cache", ROOT / "ci/private_buildkit_cache.py"
)
cache = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cache)
SCOPE = "a" * 64


class MemoryStore:
    def __init__(self):
        self.objects = {}
        self.puts = []
        self.gets = []

    def get(self, key, destination, maximum):
        self.gets.append(key)
        if key not in self.objects:
            return False
        body = self.objects[key]
        if len(body) > maximum:
            raise cache.CacheError("size limit")
        destination.write_bytes(body)
        return True

    def etag(self, key):
        body = self.objects.get(key)
        return None if body is None else '"' + hashlib.sha256(body).hexdigest() + '"'

    def put(self, key, source, *, expected_etag=None):
        if self.etag(key) != expected_etag:
            raise cache.CacheError("conditional write conflict")
        self.objects[key] = source.read_bytes()
        self.puts.append((key, expected_etag))


def layout(directory, value=b"cache data"):
    blobs = directory / "blobs/sha256"
    blobs.mkdir(parents=True)
    digest = hashlib.sha256(value).hexdigest()
    (blobs / digest).write_bytes(value)
    (directory / "oci-layout").write_text('{"imageLayoutVersion":"1.0.0"}')
    (directory / "index.json").write_text(
        json.dumps({"schemaVersion": 2, "manifests": [{"digest": "sha256:" + digest}]})
    )
    return digest


@pytest.fixture
def stored(tmp_path):
    store = MemoryStore()
    root = tmp_path / "first"
    layout(root / "export")
    cache.save(store, SCOPE, root, "123", "1")
    return store


def test_round_trip_and_pointer_published_last(stored, tmp_path):
    assert stored.puts[0] == (
        f"{cache.PREFIX}/{SCOPE}/snapshots/123-1/cache.tar.gz",
        None,
    )
    assert stored.puts[1] == (f"{cache.PREFIX}/{SCOPE}/latest.json", None)
    assert cache.restore(stored, SCOPE, tmp_path / "next")
    cache.validate_layout(tmp_path / "next/import")


def test_pointer_updates_use_compare_and_swap(stored, tmp_path):
    key = f"{cache.PREFIX}/{SCOPE}/latest.json"
    old = stored.etag(key)
    root = tmp_path / "second"
    layout(root / "export", b"new data")
    cache.save(stored, SCOPE, root, "456", "1")
    assert stored.puts[-1] == (key, old)
    assert f"{cache.PREFIX}/{SCOPE}/snapshots/123-1/cache.tar.gz" in stored.objects


def test_snapshot_collision_does_not_change_pointer(stored, tmp_path):
    key = f"{cache.PREFIX}/{SCOPE}/latest.json"
    before = stored.objects[key]
    root = tmp_path / "again"
    layout(root / "export", b"different bytes")
    with pytest.raises(cache.CacheError, match="conditional write conflict"):
        cache.save(stored, SCOPE, root, "123", "1")
    assert stored.objects[key] == before


def test_missing_cache_is_a_miss(tmp_path):
    assert cache.restore(MemoryStore(), SCOPE, tmp_path) is False
    assert not (tmp_path / "import").exists()


def test_racing_pointer_writer_cannot_clobber_newer_pointer(stored, tmp_path):
    key = f"{cache.PREFIX}/{SCOPE}/latest.json"
    original_etag = stored.etag

    def racing_etag(path):
        previous = original_etag(path)
        stored.objects[path] = b"concurrent winner"
        return previous

    stored.etag = racing_etag
    root = tmp_path / "new"
    layout(root / "export", b"new cache data")
    with pytest.raises(cache.CacheError, match="conditional write conflict"):
        cache.save(stored, SCOPE, root, "987", "1")
    assert stored.objects[key] == b"concurrent winner"


@pytest.mark.parametrize(
    "mutation", ["checksum", "foreign-key", "expired", "invalid-json"]
)
def test_invalid_pointer_never_exposes_import(stored, tmp_path, mutation):
    key = f"{cache.PREFIX}/{SCOPE}/latest.json"
    pointer = json.loads(stored.objects[key])
    if mutation == "checksum":
        pointer["sha256"] = "b" * 64
    elif mutation == "foreign-key":
        pointer["key"] = pointer["key"].replace(SCOPE, "b" * 64)
    elif mutation == "expired":
        pointer["created_at"] = 0
    stored.objects[key] = (
        b"not json" if mutation == "invalid-json" else json.dumps(pointer).encode()
    )
    with pytest.raises((cache.CacheError, ValueError)):
        cache.restore(stored, SCOPE, tmp_path / "restore")
    assert not (tmp_path / "restore/import").exists()


@pytest.mark.parametrize(
    "name,kind",
    [("../escape", "file"), ("/absolute", "file"), ("index.json", "symlink")],
)
def test_unsafe_tar_members_are_rejected(tmp_path, name, kind):
    archive = tmp_path / "cache.tar.gz"
    with tarfile.open(archive, "w:gz") as target:
        member = tarfile.TarInfo(name)
        if kind == "symlink":
            member.type = tarfile.SYMTYPE
            member.linkname = "/etc/passwd"
            target.addfile(member)
        else:
            member.size = 1
            target.addfile(member, io.BytesIO(b"x"))
    destination = tmp_path / "extract"
    destination.mkdir()
    with pytest.raises(cache.CacheError, match="unsafe"):
        cache.extract_cache(archive, destination)
    assert not (tmp_path / "escape").exists()


def test_corrupt_blob_is_rejected(tmp_path):
    digest = layout(tmp_path / "cache")
    (tmp_path / "cache/blobs/sha256" / digest).write_bytes(b"poison")
    with pytest.raises(cache.CacheError, match="checksum"):
        cache.validate_layout(tmp_path / "cache")


def test_size_limits_apply_before_import(stored, tmp_path, monkeypatch):
    monkeypatch.setattr(cache, "MAX_ARCHIVE_BYTES", 1)
    with pytest.raises(cache.CacheError, match="size limit"):
        cache.restore(stored, SCOPE, tmp_path / "restore")
    assert not (tmp_path / "restore/import").exists()


@pytest.fixture
def candidate_environment(tmp_path):
    train = {
        "candidate_image_policy": {
            "schema_version": 1,
            "mode": "retain",
            "refresh_key": "",
        }
    }
    train["train_sha256"] = hashlib.sha256(cache.canonical(train)).hexdigest()
    path = tmp_path / "train.json"
    path.write_text(json.dumps(train))
    return {
        "GITHUB_REPOSITORY": "rapidsai/ci-imgs",
        "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REF": "refs/heads/release-test-build-system-enrollment",
        "BUILD_TYPE": "release-candidate",
        "IMAGE_REPO": "ci-conda",
        "DOCKER_TARGET": "ci-conda",
        "ARCH": "arm64",
        "CUDA_VER": "12.9.2",
        "LINUX_VER": "rockylinux8",
        "PYTHON_VER": "3.12",
        "RAPIDS_VERSION_MAJOR_MINOR": "26.12",
        "RAPIDS_RELEASE_CANDIDATE_TRAIN_FILE": str(path),
        "RELEASE_CANDIDATE_TRAIN_SHA256": train["train_sha256"],
    }


def variant():
    return {
        "image_repository": "ci-conda",
        "target": "ci-conda",
        "arch": "arm64",
        "linux": "rockylinux8",
        "cuda": "12.9.2",
        "python": "3.12",
        "release": "26.12",
    }


def test_restore_accepts_reported_default_target_variant(
    candidate_environment, tmp_path, monkeypatch
):
    candidate_environment.update(
        DOCKER_TARGET="", ARCH="amd64", CUDA_VER="12.2.2", PYTHON_VER="3.15t"
    )
    for name, value in candidate_environment.items():
        monkeypatch.setenv(name, value)
    store = MemoryStore()
    monkeypatch.setattr(cache, "S3Store", lambda: store)
    output = tmp_path / "outputs"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "cache",
            "restore",
            "--root",
            str(tmp_path / "cache"),
            "--output",
            str(output),
        ],
    )
    cache.main()
    assert len(store.gets) == 1
    assert "cache-from=\n" in output.read_text()
    assert "cache-to=type=local" in output.read_text()
    assert "use-cache=true" in output.read_text()


def test_generated_candidate_matrix_has_valid_distinct_cache_scopes(
    candidate_environment,
):
    rows = json.loads(
        subprocess.check_output(
            ["bash", "ci/compute-candidate-matrix.sh"],
            cwd=ROOT,
            env={**os.environ, **candidate_environment},
            text=True,
        )
    )["include"]
    scopes = set()
    for row in rows:
        actual = {
            "image_repository": row["IMAGE_REPO"],
            "target": row.get("DOCKER_TARGET") or "",
            "arch": row["ARCH"],
            "linux": row["LINUX_VER"],
            "cuda": row["CUDA_VER"],
            "python": row["PYTHON_VER"],
            "release": candidate_environment["RAPIDS_VERSION_MAJOR_MINOR"],
        }
        scopes.add(cache.cache_scope(actual, candidate_environment))
    assert len(scopes) == len(rows)
    assert any(not row.get("DOCKER_TARGET") for row in rows)
    assert any(row["PYTHON_VER"].endswith("t") for row in rows)


@pytest.mark.parametrize("target", ["", "builder", "ci-conda"])
def test_default_and_named_targets_keep_separate_scopes(candidate_environment, target):
    scopes = {
        cache.cache_scope({**variant(), "target": value}, candidate_environment)
        for value in ("", "builder", "ci-conda")
    }
    assert len(scopes) == 3
    assert (
        cache.cache_scope({**variant(), "target": target}, candidate_environment)
        in scopes
    )


@pytest.mark.parametrize(
    "target", ["../stage", "bad stage", "stage\n", "stage,mode=max"]
)
def test_invalid_target_is_still_rejected(candidate_environment, target):
    with pytest.raises(cache.CacheError, match="invalid private cache variant"):
        cache.cache_scope({**variant(), "target": target}, candidate_environment)


def test_scope_survives_unrelated_train_changes_and_separates_variants(
    candidate_environment,
):
    before = cache.cache_scope(variant(), candidate_environment)
    assert (
        cache.cache_scope(
            variant(),
            {**candidate_environment, "RELEASE_CANDIDATE_TRAIN_SHA256": "b" * 64},
        )
        == before
    )
    assert (
        cache.cache_scope({**variant(), "arch": "amd64"}, candidate_environment)
        != before
    )
    assert (
        cache.cache_scope(variant(), candidate_environment, "fresh-generation")
        != before
    )
    assert (
        cache.cache_scope(
            variant(),
            {**candidate_environment, "GITHUB_REF": "refs/heads/release-test-other"},
        )
        != before
    )


@pytest.mark.parametrize(
    "change",
    [
        {"GITHUB_REPOSITORY": "fork/ci-imgs"},
        {"GITHUB_EVENT_NAME": "pull_request"},
        {"GITHUB_REF": "refs/heads/main"},
        {"BUILD_TYPE": "branch"},
    ],
)
def test_untrusted_context_is_rejected_before_store_access(
    candidate_environment, change
):
    with pytest.raises(cache.CacheError, match="trusted"):
        cache.cache_scope(variant(), {**candidate_environment, **change})


def test_changed_train_digest_cannot_change_refresh_intent(candidate_environment):
    path = Path(candidate_environment["RAPIDS_RELEASE_CANDIDATE_TRAIN_FILE"])
    train = json.loads(path.read_text())
    train["candidate_image_policy"]["mode"] = "refresh"
    path.write_text(json.dumps(train))
    with pytest.raises(cache.CacheError, match="identity mismatch"):
        cache.image_policy(candidate_environment)


def test_refresh_bypasses_import_and_still_exports(
    candidate_environment, tmp_path, monkeypatch
):
    path = Path(candidate_environment["RAPIDS_RELEASE_CANDIDATE_TRAIN_FILE"])
    train = json.loads(path.read_text())
    train.pop("train_sha256")
    train["candidate_image_policy"]["mode"] = "refresh"
    train["train_sha256"] = hashlib.sha256(cache.canonical(train)).hexdigest()
    path.write_text(json.dumps(train))
    candidate_environment["RELEASE_CANDIDATE_TRAIN_SHA256"] = train["train_sha256"]
    for name, value in candidate_environment.items():
        monkeypatch.setenv(name, value)
    store = MemoryStore()
    monkeypatch.setattr(cache, "S3Store", lambda: store)
    output = tmp_path / "outputs"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "cache",
            "restore",
            "--root",
            str(tmp_path / "cache"),
            "--output",
            str(output),
        ],
    )
    cache.main()
    assert not store.gets
    assert "use-cache=false" in output.read_text()
    assert "cache-to=type=local" in output.read_text()


def test_optional_cache_denial_preserves_cold_build(
    candidate_environment, tmp_path, monkeypatch, capsys
):
    for name, value in candidate_environment.items():
        monkeypatch.setenv(name, value)

    def unavailable():
        raise cache.CacheError("private cache read unavailable")

    monkeypatch.setattr(cache, "S3Store", unavailable)
    output = tmp_path / "outputs"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "cache",
            "restore",
            "--root",
            str(tmp_path / "cache"),
            "--output",
            str(output),
        ],
    )
    cache.main()
    assert (
        "::warning::Optional private BuildKit cache unavailable"
        in capsys.readouterr().out
    )
    assert "cache-from=\n" in output.read_text()
    assert "use-cache=true" in output.read_text()


def test_s3_writes_are_conditional_and_use_only_private_namespace(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(shutil, "which", lambda _: "/usr/local/bin/aws")
    store = cache.S3Store()
    commands = []

    def run(arguments):
        commands.append(arguments)
        return subprocess.CompletedProcess(arguments, 0, '"0123456789abcdef"\n', "")

    monkeypatch.setattr(store, "_run", run)
    source = tmp_path / "cache"
    source.write_bytes(b"bytes")
    snapshot = f"{cache.PREFIX}/{SCOPE}/snapshots/123-1/cache.tar.gz"
    pointer = f"{cache.PREFIX}/{SCOPE}/latest.json"
    store.put(snapshot, source)
    previous = store.etag(pointer)
    store.put(pointer, source, expected_etag=previous)
    assert commands[0][-2:] == ["--if-none-match", "*"]
    assert commands[-1][-2:] == ["--if-match", '"0123456789abcdef"']
    assert all(
        command[command.index("--bucket") + 1] == cache.BUCKET for command in commands
    )
    assert all(
        command[command.index("--key") + 1].startswith(cache.PREFIX + "/")
        for command in commands
    )


def test_workflow_keeps_caches_private_and_artifact_admission_independent():
    workflow = yaml.safe_load((ROOT / ".github/workflows/build.yaml").read_text())
    steps = workflow["jobs"]["candidate-images"]["steps"]
    build = next(
        step
        for step in steps
        if step.get("name") == "Build the real CI image to an OCI archive"
    )
    assert build["with"]["push"] is False
    assert "steps.cache.outputs.cache-to" in build["with"]["cache-to"]
    assert "steps.cache.outputs.use-cache" in build["with"]["cache-from"]
    assert build["with"]["no-cache"] == "${{ steps.cache.outputs.use-cache != 'true' }}"
    assert steps[-1]["name"] == "Publish run-bound private image catalog"
    assert not any(
        "cache-gha" in str(step) or "docker/login" in str(step) for step in steps
    )


@pytest.mark.skipif(
    os.environ.get("RUN_S3_CACHE_SMOKE") != "1", reason="explicit local S3 smoke"
)
def test_real_s3_cli_roundtrip_and_conditional_pointer(tmp_path, monkeypatch):
    """Exercise the actual AWS CLI against a temporary, local-only S3 service."""
    import boto3
    from moto.server import ThreadedMotoServer

    server = ThreadedMotoServer(ip_address="127.0.0.1", port=0, verbose=False)
    server.start()
    try:
        host, port = server.get_host_and_port()
        endpoint = f"http://{host}:{port}"
        for name, value in {
            "AWS_ENDPOINT_URL": endpoint,
            "AWS_ACCESS_KEY_ID": "local-test",
            "AWS_SECRET_ACCESS_KEY": "local-test",
            "AWS_DEFAULT_REGION": "us-east-2",
            "AWS_EC2_METADATA_DISABLED": "true",
        }.items():
            monkeypatch.setenv(name, value)
        for name in ("AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_SESSION_TOKEN"):
            monkeypatch.delenv(name, raising=False)
        s3 = boto3.client("s3", endpoint_url=endpoint, region_name="us-east-2")
        s3.create_bucket(
            Bucket=cache.BUCKET,
            CreateBucketConfiguration={"LocationConstraint": "us-east-2"},
        )
        store = cache.S3Store()
        first = tmp_path / "first"
        layout(first / "export")
        cache.save(store, SCOPE, first, "111", "1")
        assert cache.restore(store, SCOPE, tmp_path / "second")
        key = f"{cache.PREFIX}/{SCOPE}/latest.json"
        stale = store.etag(key)
        replacement = tmp_path / "replacement.json"
        pointer = json.loads(s3.get_object(Bucket=cache.BUCKET, Key=key)["Body"].read())
        pointer["created_at"] += 1
        replacement.write_bytes(cache.canonical(pointer))
        store.put(key, replacement, expected_etag=stale)
        assert store.etag(key) != stale
        with pytest.raises(cache.CacheError, match="upload unavailable"):
            store.put(key, replacement, expected_etag=stale)
        with pytest.raises(cache.CacheError, match="upload unavailable"):
            cache.save(store, SCOPE, first, "111", "1")
    finally:
        server.stop()


@pytest.mark.skipif(
    os.environ.get("RUN_BUILDKIT_CACHE_SMOKE") != "1", reason="explicit Docker smoke"
)
def test_real_buildkit_cache_roundtrip_with_fresh_builders(tmp_path):
    """The second fresh BuildKit daemon must reuse transferred layers."""
    context = tmp_path / "context"
    context.mkdir()
    (context / "Dockerfile").write_text("FROM scratch\nCOPY payload /payload\n")
    (context / "payload").write_text("cache integration probe\n")
    store = MemoryStore()
    first = tmp_path / "first"
    first.mkdir()
    builders = [f"ci-imgs-cache-test-{os.getpid()}-{index}" for index in range(2)]
    try:
        for index, builder in enumerate(builders):
            subprocess.run(
                [
                    "docker",
                    "buildx",
                    "create",
                    "--name",
                    builder,
                    "--driver",
                    "docker-container",
                ],
                check=True,
                capture_output=True,
            )
            root = first if index == 0 else tmp_path / "second"
            if index:
                assert cache.restore(store, SCOPE, root)
            command = [
                "docker",
                "buildx",
                "build",
                "--builder",
                builder,
                "--progress=plain",
                "--cache-to",
                f"type=local,dest={root}/export,mode=max",
                "--output",
                f"type=oci,dest={tmp_path}/image-{index}.tar",
                str(context),
            ]
            if index:
                command += ["--cache-from", f"type=local,src={root}/import"]
            result = subprocess.run(command, check=True, capture_output=True, text=True)
            (tmp_path / f"build-{index}.log").write_text(result.stderr)
            if index:
                assert "CACHED" in result.stderr
            else:
                cache.save(store, SCOPE, root, "123", "1")
        cache.validate_layout(tmp_path / "second/export")
    finally:
        for builder in builders:
            subprocess.run(
                ["docker", "buildx", "rm", "--force", builder],
                check=False,
                capture_output=True,
            )
