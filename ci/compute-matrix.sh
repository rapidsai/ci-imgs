#!/bin/bash
set -euo pipefail

case "${BUILD_TYPE}" in
  pull-request)
    export PR_NUM="${GITHUB_REF_NAME##*/}"
    ;;
  branch)
    ;;
  *)
    echo "Invalid build type: '${BUILD_TYPE}'"
    exit 1
    ;;
esac

CI_MATRIX=$(yq -o json '. | del(.LATEST_VERSIONS)' matrices/ci-matrix.yaml | jq -c 'include "ci/compute-ci-matrix"; compute_matrix(.)')
WHEELS_MATRIX=$(yq -o json matrices/wheels-matrix.yaml | jq -c 'include "ci/compute-wheels-matrix"; compute_matrix(.)')

COMBINED_MATRIX=$(jq -c -n \
  --argjson ci_matrix "$CI_MATRIX" \
  --argjson wheels_matrix "$WHEELS_MATRIX" \
  '{"include": ($ci_matrix.include + $wheels_matrix.include)}')

echo "$COMBINED_MATRIX"
