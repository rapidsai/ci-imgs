#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

: "${RAPIDS_VERSION_MAJOR_MINOR:?Frozen train container version is required}"
if [[ ! "${RAPIDS_VERSION_MAJOR_MINOR}" =~ ^[0-9]{2}\.[0-9]{2}$ ]]; then
  echo 'Invalid frozen container version' >&2
  exit 1
fi
export BUILD_TYPE=branch
export RAPIDS_VERSION_MAJOR_MINOR
yq -o json matrix.yaml | jq -c '
  include "ci/compute-matrix";
  compute_matrix(.) |
  {include: [.include[] | . as $variant | .ARCHES[] as $arch |
    $variant + {ARCH: $arch} | del(.ARCHES)]}
'
