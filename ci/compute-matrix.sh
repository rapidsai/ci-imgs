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

yq -o json matrix.yaml | jq -c 'include "ci/compute-matrix"; compute_matrix(.)'
