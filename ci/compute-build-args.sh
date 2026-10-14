#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2023-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

if [[
  "${IMAGE_REPO}" == "ci-wheel" &&
  "${LINUX_VER}" != "rockylinux8"
]]; then
  echo "Unsupported LINUX_VER: ${LINUX_VER} for ci-wheel image"
  exit 1
fi

RAPIDS_VERSION_MAJOR_MINOR=${RAPIDS_VERSION_MAJOR_MINOR:-$(rapids-version-major-minor)}

MANYLINUX_VER="manylinux_2_28"

# translate ARCH to conda-equivalent string values
CONDA_ARCH=$(echo "$ARCH" | sed 's#amd64#linux64#' | sed 's#arm64#aarch64#')

ARGS="
RAPIDS_VERSION_MAJOR_MINOR: ${RAPIDS_VERSION_MAJOR_MINOR}
CUDA_VER: ${CUDA_VER}
LINUX_VER: ${LINUX_VER}
PYTHON_VER: ${PYTHON_VER}
CPU_ARCH: ${ARCH}
REAL_ARCH: $(arch)
MANYLINUX_VER: ${MANYLINUX_VER}
CONDA_ARCH: ${CONDA_ARCH}
"

# Candidate images use canonical Docker Hub references so the runner's configured
# Docker and BuildKit mirrors handle every pull. Keep production defaults unchanged.
if [[ "${CANDIDATE_IMAGE_MIRROR:-false}" == "true" ]]; then
  case "${IMAGE_REPO}" in
    ci-conda)
      ARGS+=$'\nCUDA_BASE_IMAGE: docker.io/nvidia/cuda:'"${CUDA_VER}-base-${LINUX_VER}"
      ARGS+=$'\nMINIFORGE_BASE_IMAGE: docker.io/condaforge/miniforge3:'"$(yq -r '.MINIFORGE_VER' versions.yaml)"
      ;;
    ci-wheel)
      ARGS+=$'\nBASE_IMAGE: docker.io/nvidia/cuda:'"${CUDA_VER}-devel-${LINUX_VER}"
      ;;
    citestwheel)
      ARGS+=$'\nCUDA_BASE_IMAGE: docker.io/nvidia/cuda:'"${CUDA_VER}-base-${LINUX_VER}"
      ;;
    *)
      echo "Unsupported IMAGE_REPO for candidate image mirror: ${IMAGE_REPO}" >&2
      exit 1
      ;;
  esac
fi

export ARGS

if [ -n "${GITHUB_ACTIONS:-}" ]; then
BUILD_ARGS=$(yq -r '. + env(ARGS) | to_entries | map(.key + "=" + .value) | join(" \n")' versions.yaml)
cat <<EOF > "${GITHUB_OUTPUT:-/dev/stdout}"
ARGS<<EOT
${BUILD_ARGS}
EOT
EOF
if [[ "${CANDIDATE_IMAGE_MIRROR:-false}" == "true" && "${IMAGE_REPO}" == "ci-wheel" ]]; then
  printf 'BASE_IMAGE=%s\n' "$(yq -r '.BASE_IMAGE' <<< "$(yq -o=json '. + env(ARGS)' versions.yaml)")" >> "${GITHUB_OUTPUT:-/dev/stdout}"
fi
else
  yq -r '. + env(ARGS) | to_entries | map("--build-arg " + .key + "=" + .value) | join(" ")' versions.yaml
fi
