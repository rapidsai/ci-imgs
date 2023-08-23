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

COMBINED_MATRIX_YAML=$(yq -o json '. | del(.LATEST_VERSIONS)' 'matrix.yaml')

# Separate CI and Wheels axes
CI_MATRIX=$(echo "$COMBINED_MATRIX_YAML" | jq -c '{ci: .ci} | .ci | del(.LATEST_VERSIONS)')
WHEELS_MATRIX=$(echo "$COMBINED_MATRIX_YAML" | jq -c '{wheels: .wheels} | .wheels')

CI_COMPUTED=$(echo "$CI_MATRIX" | jq -c --arg type "ci" 'include "ci/compute-matrix"; compute_matrix($type; .)')
WHEELS_COMPUTED=$(echo "$WHEELS_MATRIX" | jq -c --arg type "wheels" 'include "ci/compute-matrix"; compute_matrix($type; .)')

# Combine CI and Wheels matrices
COMBINED_COMPUTED=$(jq -c -n \
  --argjson ci_matrix "$CI_COMPUTED" \
  --argjson wheels_matrix "$WHEELS_COMPUTED" \
  '{"include": ($ci_matrix.include + $wheels_matrix.include)}')

echo "$COMBINED_COMPUTED"
