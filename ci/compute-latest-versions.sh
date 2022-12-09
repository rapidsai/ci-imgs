#!/bin/bash
# Computes versions used for "latest" tag based on "axis.yaml"
# values. Will also check to ensure that the "latest" values are
# included in the matrix values.
# Example Usage:
#   ./ci/compute-latest-versions.sh
set -eu

export LINUX_KEY="LINUX_VER"
export CUDA_KEY="CUDA_VER"
export PYTHON_KEY="PYTHON_VER"

# Get latest values
LATEST_LINUX_VER=$(yq '.LATEST_VERSIONS.[strenv(LINUX_KEY)]' axis.yaml)
LATEST_CUDA_VER=$(yq '.LATEST_VERSIONS.[strenv(CUDA_KEY)]' axis.yaml)
LATEST_PYTHON_VER=$(yq '.LATEST_VERSIONS.[strenv(PYTHON_KEY)]' axis.yaml)

# Get matrix array values
LINUX_VERS=$(yq '.[strenv(LINUX_KEY)]' axis.yaml)
CUDA_VERS=$(yq '.[strenv(CUDA_KEY)]' axis.yaml)
PYTHON_VERS=$(yq '.[strenv(PYTHON_KEY)]' axis.yaml)

# Ensure matrix array values contain latest values
for KEY in "${LINUX_KEY}" "${CUDA_KEY}" "${PYTHON_KEY}"; do
  LATEST_STR="LATEST_${KEY}"
  ARRAY_STR="${KEY}S"

  export LATEST_VALUE="${!LATEST_STR}"
  export ARRAY_VALUE="${!ARRAY_STR}"

  yq -ne 'env(ARRAY_VALUE) | contains([strenv(LATEST_VALUE)])'
done

echo "LATEST_LINUX_VER=${LATEST_LINUX_VER}" | tee --append "${GITHUB_OUTPUT:-/dev/null}"
echo "LATEST_CUDA_VER=${LATEST_CUDA_VER}" | tee --append "${GITHUB_OUTPUT:-/dev/null}"
echo "LATEST_PYTHON_VER=${LATEST_PYTHON_VER}" | tee --append "${GITHUB_OUTPUT:-/dev/null}"
