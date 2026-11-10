# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Transfer disposable BuildKit local caches through the private candidate bucket.

This cache only accelerates Docker builds. Immutable OCI artifact publication,
input verification and catalog admission run independently after every build.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess  # nosec B404 - fixed AWS CLI argv, without a shell.
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Protocol

BUCKET = "rapids-release-candidates"
PREFIX = "build-cache/ci-imgs/buildkit/v1"
MAX_ARCHIVE_BYTES = 4 * 1024**3  # Below S3's single PutObject limit.
MAX_EXPANDED_BYTES = 16 * 1024**3
MAX_MEMBERS = 100_000
MAX_AGE_SECONDS = 7 * 24 * 60 * 60
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
BLOB = re.compile(r"blobs/sha256/([0-9a-f]{64})\Z")


class CacheError(ValueError):
    """An optional cache is unavailable or fails validation."""


class Store(Protocol):
    def get(self, key: str, destination: Path, maximum: int) -> bool: ...

    def etag(self, key: str) -> str | None: ...

    def put(
        self, key: str, source: Path, *, expected_etag: str | None = None
    ) -> None: ...


class S3Store:
    """Use the existing short-lived producer identity; never print AWS output."""

    def __init__(self) -> None:
        executable = shutil.which("aws")
        if executable is None:
            raise CacheError("AWS CLI is unavailable")
        self.executable = executable

    def _run(self, arguments: list[str]) -> subprocess.CompletedProcess:
        try:
            # Resolve the executable locally; other arguments are fixed or validated.
            return subprocess.run(  # nosec B603
                [self.executable, "s3api", *arguments],
                check=False,
                capture_output=True,
                text=True,
                timeout=600,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise CacheError("private cache transfer failed") from error

    def get(self, key: str, destination: Path, maximum: int) -> bool:
        size = self._run(
            [
                "head-object",
                "--bucket",
                BUCKET,
                "--key",
                key,
                "--query",
                "ContentLength",
                "--output",
                "text",
            ]
        )
        if size.returncode:
            if "(404)" in size.stderr or "(NoSuchKey)" in size.stderr:
                return False
            raise CacheError("private cache read unavailable")
        if not size.stdout.strip().isdigit() or int(size.stdout) > maximum:
            raise CacheError("private cache object exceeds its size limit")
        result = self._run(
            ["get-object", "--bucket", BUCKET, "--key", key, str(destination)]
        )
        if result.returncode or destination.stat().st_size > maximum:
            raise CacheError("private cache download failed or exceeded its size limit")
        return True

    def etag(self, key: str) -> str | None:
        result = self._run(
            [
                "head-object",
                "--bucket",
                BUCKET,
                "--key",
                key,
                "--query",
                "ETag",
                "--output",
                "text",
            ]
        )
        if result.returncode:
            if "(404)" in result.stderr or "(NoSuchKey)" in result.stderr:
                return None
            raise CacheError("private cache pointer read unavailable")
        value = result.stdout.strip()
        if not re.fullmatch(r'"[a-f0-9-]+"', value):
            raise CacheError("invalid private cache pointer ETag")
        return value

    def put(self, key: str, source: Path, *, expected_etag: str | None = None) -> None:
        arguments = [
            "put-object",
            "--bucket",
            BUCKET,
            "--key",
            key,
            "--body",
            str(source),
        ]
        arguments += (
            ["--if-match", expected_etag]
            if expected_etag is not None
            else ["--if-none-match", "*"]
        )
        if self._run(arguments).returncode:
            raise CacheError("private cache upload unavailable")


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def file_digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def cache_scope(
    variant: dict[str, str], environment: dict[str, str], refresh_key: str = ""
) -> str:
    """Keep one cache per trusted source ref and complete image variant."""
    if not re.fullmatch(r"[A-Za-z0-9._-]{0,128}", refresh_key):
        raise CacheError("invalid private cache refresh key")
    if (
        environment.get("GITHUB_REPOSITORY") != "rapidsai/ci-imgs"
        or environment.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
        or not re.fullmatch(
            r"refs/heads/release-test-[A-Za-z0-9._-]+",
            environment.get("GITHUB_REF", ""),
        )
        or environment.get("BUILD_TYPE") != "release-candidate"
    ):
        raise CacheError("private cache requires the trusted candidate workflow")
    patterns = {
        "image_repository": r"ci-conda|ci-wheel|citestwheel",
        # Empty selects the Dockerfile's default stage (for example ci-conda).
        "target": r"[A-Za-z0-9_-]*",
        "arch": r"amd64|arm64",
        "linux": r"[a-z0-9.]+",
        "cuda": r"[0-9]+(?:\.[0-9]+){1,2}",
        "python": r"[0-9]+\.[0-9]+t?",
        "release": r"[0-9]{2}\.[0-9]{2}",
    }
    if set(variant) != set(patterns) or any(
        not re.fullmatch(pattern, variant[name]) for name, pattern in patterns.items()
    ):
        raise CacheError("invalid private cache variant")
    descriptor = {
        "schema_version": 1,
        "variant": variant,
        "repository": environment["GITHUB_REPOSITORY"],
        "ref": environment["GITHUB_REF"],
        "refresh_key": refresh_key,
    }
    return hashlib.sha256(canonical(descriptor)).hexdigest()


def image_policy(environment: dict[str, str]) -> tuple[str, str]:
    """Read refresh intent only from the same immutable train used by the build."""
    filename = environment.get("RAPIDS_RELEASE_CANDIDATE_TRAIN_FILE")
    digest = environment.get("RELEASE_CANDIDATE_TRAIN_SHA256", "")
    if not filename or not SHA256.fullmatch(digest):
        raise CacheError("private cache requires the verified candidate train")
    train = json.loads(Path(filename).read_bytes())
    recorded = train.pop("train_sha256", None)
    if recorded != digest or hashlib.sha256(canonical(train)).hexdigest() != digest:
        raise CacheError("private cache train identity mismatch")
    policy = train.get(
        "candidate_image_policy",
        {"schema_version": 1, "mode": "retain", "refresh_key": ""},
    )
    if (
        not isinstance(policy, dict)
        or set(policy) != {"schema_version", "mode", "refresh_key"}
        or type(policy["schema_version"]) is not int
        or policy["schema_version"] != 1
        or policy["mode"] not in ("retain", "refresh")
        or not isinstance(policy["refresh_key"], str)
        or not re.fullmatch(r"[A-Za-z0-9._-]{0,128}", policy["refresh_key"])
    ):
        raise CacheError("invalid candidate image cache policy")
    return policy["mode"], policy["refresh_key"]


def validate_layout(directory: Path) -> None:
    """Validate OCI cache metadata and every content-addressed blob."""
    if directory.is_symlink():
        raise CacheError("private cache directory cannot be a symlink")
    total = 0
    for count, path in enumerate(directory.rglob("*"), start=1):
        if count > MAX_MEMBERS or path.is_symlink():
            raise CacheError("private cache contains too many entries or a symlink")
        name = path.relative_to(directory).as_posix()
        if path.is_dir():
            # BuildKit leaves its empty content-ingestion work directory behind.
            if name == "ingest" and not any(path.iterdir()):
                continue
            if name not in ("blobs", "blobs/sha256"):
                raise CacheError("private cache contains an unexpected directory")
            continue
        match = BLOB.fullmatch(name)
        if not path.is_file() or (
            match is None and name not in ("index.json", "oci-layout")
        ):
            raise CacheError("private cache contains an unexpected file")
        total += path.stat().st_size
        if total > MAX_EXPANDED_BYTES:
            raise CacheError("private cache exceeds its expanded size limit")
        if match is not None and file_digest(path) != match[1]:
            raise CacheError("private cache blob checksum mismatch")
    try:
        if any(
            (directory / name).stat().st_size > 1024**2
            for name in ("index.json", "oci-layout")
        ):
            raise CacheError("private cache metadata is too large")
        layout = json.loads((directory / "oci-layout").read_bytes())
        index = json.loads((directory / "index.json").read_bytes())
        if layout != {"imageLayoutVersion": "1.0.0"} or index.get("schemaVersion") != 2:
            raise CacheError("invalid private OCI cache metadata")
        manifests = index.get("manifests")
        if not isinstance(manifests, list) or not manifests:
            raise CacheError("private OCI cache has no manifests")
        for manifest in manifests:
            digest = manifest.get("digest", "").removeprefix("sha256:")
            if (
                not SHA256.fullmatch(digest)
                or not (directory / "blobs/sha256" / digest).is_file()
            ):
                raise CacheError("private OCI cache manifest is missing")
    except (OSError, ValueError, AttributeError, TypeError) as error:
        raise CacheError("invalid private OCI cache metadata") from error


def extract_cache(archive: Path, destination: Path) -> None:
    """Extract regular OCI files into a new directory without trusting tar paths."""
    total = 0
    seen = set()
    with tarfile.open(archive, "r:gz") as source:
        for count, member in enumerate(source, start=1):
            name = member.name.rstrip("/")
            if count > MAX_MEMBERS or name in seen:
                raise CacheError(
                    "private cache archive contains duplicate or excess entries"
                )
            seen.add(name)
            if member.isdir() and name in ("blobs", "blobs/sha256"):
                continue
            if not member.isfile() or (
                name not in ("index.json", "oci-layout") and not BLOB.fullmatch(name)
            ):
                raise CacheError(
                    "private cache archive contains an unsafe path or entry"
                )
            total += member.size
            if total > MAX_EXPANDED_BYTES:
                raise CacheError("private cache exceeds its expanded size limit")
            output = destination / name
            output.parent.mkdir(parents=True, exist_ok=True)
            contents = source.extractfile(member)
            if contents is None:
                raise CacheError("private cache archive file is missing")
            with contents, output.open("xb") as stream:
                shutil.copyfileobj(contents, stream)
    validate_layout(destination)


def restore(store: Store, scope: str, root: Path, *, now: int | None = None) -> bool:
    if not SHA256.fullmatch(scope):
        raise CacheError("invalid private cache scope")
    root.mkdir(parents=True, exist_ok=True)
    restored = root / "import"
    if restored.exists():
        raise CacheError("private cache import directory must be fresh")
    with tempfile.TemporaryDirectory(prefix="restore-", dir=root) as temporary:
        work = Path(temporary)
        pointer = work / "latest.json"
        if not store.get(f"{PREFIX}/{scope}/latest.json", pointer, 64 * 1024):
            return False
        record = json.loads(pointer.read_bytes())
        if not isinstance(record, dict):
            raise CacheError("invalid private cache pointer")
        timestamp = int(time.time()) if now is None else now
        key = record.get("key", "")
        if (
            set(record) != {"schema_version", "scope", "key", "sha256", "created_at"}
            or type(record.get("schema_version")) is not int
            or record.get("schema_version") != 1
            or record.get("scope") != scope
            or not isinstance(key, str)
            or not re.fullmatch(
                rf"{PREFIX}/{scope}/snapshots/[0-9]+-[0-9]+/cache[.]tar[.]gz", key
            )
            or not isinstance(record.get("sha256"), str)
            or not SHA256.fullmatch(record["sha256"])
            or type(record.get("created_at")) is not int
            or not 0 <= timestamp - record["created_at"] <= MAX_AGE_SECONDS
        ):
            raise CacheError("invalid or expired private cache pointer")
        archive = work / "cache.tar.gz"
        if (
            not store.get(key, archive, MAX_ARCHIVE_BYTES)
            or file_digest(archive) != record["sha256"]
        ):
            raise CacheError("private cache archive is missing or corrupt")
        extracted = work / "import"
        extracted.mkdir()
        extract_cache(archive, extracted)
        extracted.rename(restored)
        return True


def save(store: Store, scope: str, root: Path, run_id: str, attempt: str) -> None:
    if not SHA256.fullmatch(scope):
        raise CacheError("invalid private cache scope")
    if not run_id.isdigit() or not attempt.isdigit():
        raise CacheError("invalid private cache run identity")
    exported = root / "export"
    validate_layout(exported)
    with tempfile.TemporaryDirectory(prefix="save-", dir=root) as temporary:
        archive = Path(temporary) / "cache.tar.gz"
        with (
            archive.open("wb") as output,
            gzip.GzipFile(
                fileobj=output, mode="wb", mtime=0, compresslevel=1
            ) as compressed,
            tarfile.open(fileobj=compressed, mode="w|") as target,
        ):
            for path in sorted(exported.rglob("*")):
                if path.is_file():
                    target.add(
                        path,
                        arcname=path.relative_to(exported).as_posix(),
                        recursive=False,
                    )
        if archive.stat().st_size > MAX_ARCHIVE_BYTES:
            raise CacheError("private cache exceeds its archive size limit")
        key = f"{PREFIX}/{scope}/snapshots/{run_id}-{attempt}/cache.tar.gz"
        store.put(key, archive)
        pointer = Path(temporary) / "latest.json"
        pointer.write_bytes(
            canonical(
                {
                    "schema_version": 1,
                    "scope": scope,
                    "key": key,
                    "sha256": file_digest(archive),
                    "created_at": int(time.time()),
                }
            )
        )
        latest_key = f"{PREFIX}/{scope}/latest.json"
        previous = store.etag(latest_key)
        store.put(latest_key, pointer, expected_etag=previous)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("restore", "save"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    variant = {
        key: os.environ.get(name, "")
        for key, name in {
            "image_repository": "IMAGE_REPO",
            "target": "DOCKER_TARGET",
            "arch": "ARCH",
            "linux": "LINUX_VER",
            "cuda": "CUDA_VER",
            "python": "PYTHON_VER",
            "release": "RAPIDS_VERSION_MAJOR_MINOR",
        }.items()
    }
    environment = dict(os.environ)
    mode, refresh_key = image_policy(environment)
    scope = cache_scope(variant, environment, refresh_key)
    root = arguments.root.resolve()
    hit = False
    try:
        store = S3Store()
        if arguments.operation == "restore" and mode == "retain":
            hit = restore(store, scope, root)
        elif arguments.operation == "save":
            save(
                store,
                scope,
                root,
                os.environ.get("GITHUB_RUN_ID", ""),
                os.environ.get("GITHUB_RUN_ATTEMPT", ""),
            )
    except (CacheError, OSError, ValueError, tarfile.TarError) as error:
        print(f"::warning::Optional private BuildKit cache unavailable: {error}")
    if arguments.operation == "restore" and arguments.output is not None:
        root.mkdir(parents=True, exist_ok=True)
        with arguments.output.open("a") as output:
            output.write(
                f"cache-from=type=local,src={root}/import\n" if hit else "cache-from=\n"
            )
            output.write(
                f"cache-to=type=local,dest={root}/export,mode=max,oci-mediatypes=true,ignore-error=true\n"
            )
            output.write(f"use-cache={'true' if mode == 'retain' else 'false'}\n")
        print(f"Private BuildKit cache {'hit' if hit else 'miss'}: {scope}")


if __name__ == "__main__":
    main()
