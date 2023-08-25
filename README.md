# ci-imgs

This repository has been merged with [cibuildwheel-imgs](https://github.com/rapidsai/cibuildwheel-imgs). This repository used to contain only the dockerfile used for the CI images used by RAPIDS (these images are build from the [rapidsai/mambaforge-cuda](https://github.com/rapidsai/mambaforge-cuda) images).

Added now to this repository are all the images used to build [RAPIDS pip wheel](https://rapids.ai/pip) releases.

- `ci` images are conda CI images used for building RAPIDS.
- `ci-wheel` images are for building manylinux-compliant wheels. They are also used to build pure-Python wheels, and for publishing wheels with twine
- `citestwheel` images are for running wheel tests

Old `cibuildwheels-imgs` repository is [here](https://github.com/rapidsai/cibuildwheel-imgs).

## `latest` tag

The `latest` tag is an alias for the Docker image that has the latest CUDA version, Python version, and Ubuntu version supported by this repository at any given time.
