#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

MATRIX="${1:-}"
if [[ -z "${MATRIX}" ]]; then
  echo "Usage: validate-latest.sh MATRIX_JSON"
  exit 1
fi

errors=0
for image_repo in $(yq -r 'keys | .[]' latest.yaml); do
  cuda_ver=$(yq -r ".${image_repo}.CUDA_VER" latest.yaml)
  python_ver=$(yq -r ".${image_repo}.PYTHON_VER" latest.yaml)
  linux_ver=$(yq -r ".${image_repo}.LINUX_VER" latest.yaml)
  match=$(echo "${MATRIX}" | jq \
    --arg image_repo "${image_repo}" \
    --arg cuda_ver "${cuda_ver}" \
    --arg python_ver "${python_ver}" \
    --arg linux_ver "${linux_ver}" \
    '[.include[] | select(.IMAGE_REPO == $image_repo and .CUDA_VER == $cuda_ver and .PYTHON_VER == $python_ver and .LINUX_VER == $linux_ver)] | length')
  if [[ "${match}" -eq 0 ]]; then
    echo "::error::latest.yaml entry for '${image_repo}' (CUDA_VER=${cuda_ver}, PYTHON_VER=${python_ver}, LINUX_VER=${linux_ver}) does not match any entry in the build matrix."
    errors=$((errors + 1))
  else
    echo "latest.yaml entry for '${image_repo}' matches ${match} matrix entries."
  fi
done
if [[ "${errors}" -gt 0 ]]; then
  exit 1
fi
