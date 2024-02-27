# ci-imgs

This repository includes the following CI images for RAPIDS:

- `ci-conda` images are conda CI images used for building RAPIDS.
- `ci-wheel` images are for building manylinux-compliant wheels. They are also used to build pure-Python wheels, and for publishing wheels with twine.
- `citestwheel` images are for running wheel tests.

## `latest` tag

The `latest` image tags are controlled by the values in `latest.yaml`.

## Building the dockerfiles locally
To easily build the dockerfiles locally, you may use the following snippets:
```sh
export LINUX_VER=ubuntu22.04
export CUDA_VER=12.2
export PYTHON_VER=3.11
export ARCH=amd64
docker build $(ci/compute-build-args.sh) -f ci-conda.Dockerfile context/
docker build $(ci/compute-build-args.sh) -f ci-wheel.Dockerfile context/
docker build $(ci/compute-build-args.sh) -f citestwheel.Dockerfile context/
```
