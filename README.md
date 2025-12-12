# ci-imgs

This repository includes the following CI images for RAPIDS:

- [`rapidsai/ci-conda`](https://hub.docker.com/r/rapidsai/ci-conda/tags): for building and testing RAPIDS `conda` packages
- [`rapidsai/ci-wheel`](https://hub.docker.com/r/rapidsai/ci-wheel/tags): for building and publishing RAPIDS wheels (including pure-Python and manylinux-compliant wheels)
- [`rapidsai/citestwheel`](https://hub.docker.com/r/rapidsai/citestwheel/tags): for testing wheels
- [`rapidsai/miniforge-cuda`](https://hub.docker.com/r/rapidsai/citestwheel/tags): base image for `conda`-based images here, and for user-facing RAPIDS images like https://github.com/rapidsai/docker

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
rapidsai/ci-conda:25.10-cuda13.0.2-ubuntu24.04-py3.13
rapidsai/ci-conda:cuda13.0.2-ubuntu24.04-py3.13
rapidsai/ci-conda:25.10-latest
rapidsai/ci-conda:latest
```

But starting with the 25.12 release...

```text
# these images are unchanged
rapidsai/ci-conda:25.10-cuda13.0.2-ubuntu24.04-py3.13
rapidsai/ci-conda:25.10-latest

# these now point to 25.12
rapidsai/ci-conda:cuda13.0.2-ubuntu24.04-py3.13
rapidsai/ci-conda:latest
```

RAPIDS projects and others tightly coupled to RAPIDS releases should use the images prefixed with `{rapids_version}-`.

Other projects that aren't as tightly coupled to RAPIDS may want to use those without `{rapids_version}-`, to automatically
pull in bug fixes, new features, etc. without needing to manually update tags as frequently as RAPIDS releases.

## `latest` tag

The `latest` image tags are controlled by the values in `latest.yaml`.

## Building the dockerfiles locally

To build the dockerfiles locally, you may use the following snippets.

The `ci-conda` and `ci-wheel` images require a GitHub token to download sccache releases.
If you have the `gh` CLI installed and authenticated, you can use `gh auth token` to get your token:

```sh
export LINUX_VER=ubuntu24.04
export CUDA_VER=13.0.2
export PYTHON_VER=3.13
export ARCH=amd64
export GH_TOKEN=$(gh auth token)
export IMAGE_REPO=ci-conda
docker build $(ci/compute-build-args.sh) --secret id=GH_TOKEN -f ci-conda.Dockerfile context/
export IMAGE_REPO=ci-wheel
docker build $(ci/compute-build-args.sh) --secret id=GH_TOKEN -f ci-wheel.Dockerfile context/
export IMAGE_REPO=citestwheel
docker build $(ci/compute-build-args.sh) -f citestwheel.Dockerfile context/
```

## Cleaning Up

Every build first writes images to the https://hub.docker.com/r/rapidsai/staging repo on DockerHub,
then pushes them on to the individual repos like `rapidsai/base`, `rapidsai/notebooks`, etc.

A scheduled job regularly deletes old images from that `rapidsai/staging` repo.
See https://github.com/rapidsai/workflows/blob/main/.github/workflows/cleanup_staging.yaml for details.

If you come back to a pull request here after more than a few days and find that jobs are failing with errors
that suggest that some necessary images don't exist, re-run all of CI on that pull request to produce new images.
