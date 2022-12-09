#!/bin/bash
# Computes matrix based on "axis.yaml" values. Will also
# remove any keys (e.g. LATEST_VERSIONS) that are not used
# for the matrix build.
# Example Usage:
#   ./ci/compute-matrix.sh
set -eu

MATRIX=$(yq -o json '. | del(.LATEST_VERSIONS)' axis.yaml | jq -c)
echo "MATRIX=${MATRIX}" | tee --append ${GITHUB_OUTPUT:-/dev/null}
