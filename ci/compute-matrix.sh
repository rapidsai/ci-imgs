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

COMBINED_MATRIX_YAML=$(yq -o json 'matrix.yaml')

# Get all top-level keys (e.g., "ci", "wheels") from matrix.yaml
CONFIGURATIONS=$(echo "$COMBINED_MATRIX_YAML" | jq -r 'keys[]')

COMBINED_COMPUTED='{"include": []}'

# Loop through each configuration and compute matrix
for CONFIG in $CONFIGURATIONS; do
  CONFIG_MATRIX=$(echo "$COMBINED_MATRIX_YAML" | jq -c --arg config "$CONFIG" '.[$config] | del(.LATEST_VERSIONS)')
  CONFIG_COMPUTED=$(echo "$CONFIG_MATRIX" | jq -c --arg type "$CONFIG" 'include "ci/compute-matrix"; compute_matrix($type; .)')
  COMBINED_COMPUTED=$(echo "$COMBINED_COMPUTED" | jq -c \
    --argjson config_computed "$CONFIG_COMPUTED" \
    '{"include": (.include + $config_computed.include)}')
done

echo "$COMBINED_COMPUTED"
