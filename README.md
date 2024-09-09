# ci-imgs

This repository includes the following CI images for RAPIDS:

- `ci-conda` images are conda CI images used for building RAPIDS.
- `ci-wheel` images are for building manylinux-compliant wheels. They are also used to build pure-Python wheels, and for publishing wheels with twine.
- `citestwheel` images are for running wheel tests.

## `latest` tag

The `latest` image tags are controlled by the values in `latest.yaml`.

## Building the dockerfiles locally

To build the dockerfiles locally, you may use the following snippets:

```sh
export LINUX_VER=ubuntu22.04
export CUDA_VER=12.5.1
export PYTHON_VER=3.12
export ARCH=amd64
export IMAGE_REPO=ci-conda
docker build $(ci/compute-build-args.sh) -f ci-conda.Dockerfile context/
export IMAGE_REPO=ci-wheel
docker build $(ci/compute-build-args.sh) -f ci-wheel.Dockerfile context/
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
