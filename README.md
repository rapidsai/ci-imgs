# ci-imgs

This repository includes the following CI images for RAPIDS:

- `ci` images are conda CI images used for building RAPIDS.
- `ci-wheel` images are for building manylinux-compliant wheels. They are also used to build pure-Python wheels, and for publishing wheels with twine.
- `citestwheel` images are for running wheel tests.

## `latest` tag

The `latest` image tags are controlled by the values in `latest.yaml`.
