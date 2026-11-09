#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2022-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
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

RAPIDS_VERSION_MAJOR_MINOR=$(rapids-version-major-minor)
export RAPIDS_VERSION_MAJOR_MINOR

# Hash the repository and full ref to keep scoped tags short, valid, and distinct
# for refs such as feature/foo, feature-foo, and pull-request/467.
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set to scope the cache}"
: "${GITHUB_REF:?GITHUB_REF must be set to scope the cache}"
CACHE_REF_HASH=$(printf '%s:%s' "${GITHUB_REPOSITORY}" "${GITHUB_REF}" | sha256sum | cut -c 1-32)
export CACHE_REF_HASH

yq -o json matrix.yaml | jq -c 'include "ci/compute-matrix"; compute_matrix(.)'
