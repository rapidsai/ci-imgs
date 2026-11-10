# ci-imgs

This repository includes the following CI images for RAPIDS:

- [`rapidsai/ci-conda`](https://hub.docker.com/r/rapidsai/ci-conda/tags): for building and testing RAPIDS `conda` packages
- [`rapidsai/ci-wheel`](https://hub.docker.com/r/rapidsai/ci-wheel/tags): for building and publishing RAPIDS wheels (including pure-Python and manylinux-compliant wheels)
- [`rapidsai/citestwheel`](https://hub.docker.com/r/rapidsai/citestwheel/tags): for testing wheels

The `ci-wheel` and `citestwheel` images include a standalone `uv` in `/usr/local/bin`,
with its version pinned in `versions.yaml`. Existing Python tooling continues to be
installed using pip; downstream jobs explicitly opt in to uv.

## Tagging Strategy

Images built from the `main` branch in CI are double-published with the following tags:

```text
:{rapids_version}-cuda{cuda_version}-{operating_system}-py{python_version}
:cuda{cuda_version}-{operating_system}-py{python_version}
```

Images built from other branches (including release branches), pull requests, or locally only receive the versioned tag (with `{rapids_version}-`).

One particular combination is also chosen for `latest` tags like these:

```text
:{rapids_version}-latest
:latest
```

For example, during the 25.10 release the following might all point to the same image:

```text
rapidsai/ci-conda:25.10-cuda13.1.0-ubuntu24.04-py3.13
rapidsai/ci-conda:cuda13.1.0-ubuntu24.04-py3.13
rapidsai/ci-conda:25.10-latest
rapidsai/ci-conda:latest
```

But starting with the 25.12 release...

```text
# these images are unchanged
rapidsai/ci-conda:25.10-cuda13.1.0-ubuntu24.04-py3.13
rapidsai/ci-conda:25.10-latest

# these now point to 25.12
rapidsai/ci-conda:cuda13.1.0-ubuntu24.04-py3.13
rapidsai/ci-conda:latest
```

RAPIDS projects and others tightly coupled to RAPIDS releases should use the images prefixed with `{rapids_version}-`.

Other projects that aren't as tightly coupled to RAPIDS may want to use those without `{rapids_version}-`, to automatically
pull in bug fixes, new features, etc. without needing to manually update tags as frequently as RAPIDS releases.

## `latest` tag

The `latest` image tags are controlled by the values in `latest.yaml`.

## Building the images locally

To build the images locally, you may use the following snippets.

These scripts require the `gha-tools` project.
If you don't have it installed, you may install it like this:

```shell
git clone https://github.com/rapidsai/gha-tools.git /tmp/gha-tools
export PATH="/tmp/gha-tools/tools:${PATH}"
```

The `ci-conda` and `ci-wheel` images require a GitHub token to download sccache releases.
If you have the `gh` CLI installed and authenticated, you can use `gh auth token` to get your token:

```sh
export LINUX_VER=rockylinux8
export CUDA_VER=13.4.3
export PYTHON_VER=3.14
export ARCH=amd64
export GH_TOKEN=$(gh auth token)

export IMAGE_REPO=ci-conda
docker build $(ci/compute-build-args.sh) --secret id=GH_TOKEN -f ci-conda.Dockerfile -t rapidsai/${IMAGE_REPO}:local context/

export IMAGE_REPO=ci-wheel
./ci/sync-base-env.sh "nvidia/cuda:${CUDA_VER}-devel-${LINUX_VER}" ./ci-wheel.Dockerfile
docker build $(ci/compute-build-args.sh) --secret id=GH_TOKEN -f ci-wheel.Dockerfile -t rapidsai/${IMAGE_REPO}:local context/

export IMAGE_REPO=citestwheel
docker build $(ci/compute-build-args.sh) -f citestwheel.Dockerfile -t rapidsai/${IMAGE_REPO}:local context/
```

### Updating `gha-tools`

`ci-conda` and `ci-wheel` use two independent `gha-tools` pins in `versions.yaml`:

- `GHA_TOOLS_BOOTSTRAP_VERSION` supplies the retry helpers used while building the expensive image layers. Update it only when image construction needs new helper behavior.
- `GHA_TOOLS_VERSION` is the version shipped to users. It is installed in the final image layer so routine updates can reuse all earlier layers.

Update the corresponding SHA-256 value whenever either version changes. CI stores a separate registry-backed BuildKit cache for each image variant and architecture. Pull requests read the branch cache but write to a PR-specific cache, while branch caches use the unversioned image name so they remain reusable across RAPIDS release-number changes.

## Release candidate image scope

The private release candidate workflow builds `ci-conda` and `ci-wheel` images.
It omits `citestwheel` so test image construction and failures do not delay the
release. Test images may be built later through the regular image workflow;
that work is independent of release readiness. The regular workflow retains
the full image matrix and its `latest.yaml` validation. Private candidates do
not publish `latest` tags.

### Private candidate layer caches

Candidate image builds restore and export Docker's supported `local` BuildKit
cache backend through the private `rapids-release-candidates` bucket. This
avoids registry publication credentials and the experimental native S3 backend.
The disposable cache lives under `build-cache/ci-imgs/buildkit/v1/`, separately
from immutable candidate artifacts and train references. Its scope includes the
trusted repository/ref, image repository/target, architecture, OS, CUDA, Python,
RAPIDS release, and optional refresh generation. An unrelated package change
in a new train therefore does not discard the image's layer cache.

Every build exports to a fresh local directory so obsolete blobs do not
accumulate. The helper uploads a create-only run/attempt snapshot, then updates
the small `latest.json` pointer using an ETag conditional write. A concurrent
writer cannot silently replace a newer pointer. Restores verify the archive
SHA-256, reject unsafe tar paths and links, and validate OCI metadata and blob
digests. Snapshots are limited to 4 GiB compressed, 16 GiB expanded and 100,000
entries; imports expire after seven days. Missing, inaccessible, oversized, or
corrupt caches warn and fall back to a normal build. A successful image build
still creates its OCI archive and passes independent catalog admission.

The frozen train's `candidate_image_policy.mode=refresh` bypasses both private
and public cache imports and runs Docker with `no-cache`; it can still export
the refreshed layers. `refresh_key` optionally selects a persistent new cache
generation. This policy is independent of compiler `sccache` policy.

Before enabling writes, the existing CI-images private producer role needs
`s3:GetObject` and `s3:PutObject` only on
`arn:aws:s3:::rapids-release-candidates/build-cache/ci-imgs/buildkit/v1/*`.
The bucket policy must admit conditional updates only for this prefix's
`*/latest.json` pointers; snapshot writes remain create-only. Configure a
seven-day lifecycle for current and noncurrent cache objects and abort
incomplete multipart uploads after one day. These permissions and retention
rules do not apply to canonical artifacts or public publishing. Source-only
validation does not establish that this live infrastructure is activated.

Run `RUN_BUILDKIT_CACHE_SMOKE=1 python -m pytest -q
tests/test_private_buildkit_cache.py` to exercise two fresh BuildKit daemons
with an exported cache transferred through the helper's storage interface.

## Cleaning Up

Every build first writes images to the https://hub.docker.com/r/rapidsai/staging repo on DockerHub,
then pushes them on to the individual repos like `rapidsai/base`, `rapidsai/notebooks`, etc.

A scheduled job regularly deletes old images from that `rapidsai/staging` repo.
See https://github.com/rapidsai/workflows/blob/main/.github/workflows/cleanup_staging.yaml for details.

If you come back to a pull request here after more than a few days and find that jobs are failing with errors
that suggest that some necessary images don't exist, re-run all of CI on that pull request to produce new images.
