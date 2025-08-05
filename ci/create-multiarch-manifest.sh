#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2023-2025 NVIDIA CORPORATION & AFFILIATES.
# All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

RAPIDS_VERSION_MAJOR_MINOR=$(rapids-version-major-minor)

LATEST_CUDA_VER=$(yq -r ".${IMAGE_REPO}.CUDA_VER" latest.yaml)
LATEST_PYTHON_VER=$(yq -r ".${IMAGE_REPO}.PYTHON_VER" latest.yaml)
LATEST_UBUNTU_VER=$(yq -r ".${IMAGE_REPO}.LINUX_VER" latest.yaml)

source_tags=()
tag="${IMAGE_NAME}"
for arch in $(echo "${ARCHES}" | jq .[] -r); do
  source_tags+=("${tag}-${arch}")
done

# create/update manifests for RAPIDS-versioned images
docker manifest create "${tag}" "${source_tags[@]}"
docker manifest push "${tag}"

# create/update manifests for non-RAPIDS-versioned images
docker manifest create "${IMAGE_NAME_NO_RAPIDS_VERSION}" "${source_tags[@]}"
docker manifest push "${IMAGE_NAME_NO_RAPIDS_VERSION}"

if [[
  "${LATEST_UBUNTU_VER}" == "${LINUX_VER}" &&
  "${LATEST_CUDA_VER}" == "${CUDA_VER}" &&
  "${LATEST_PYTHON_VER}" == "${PYTHON_VER}"
]]; then
  # only create/update ':latest' manifest if it is a non-PR workflow.
  MANIFEST_TAG="${RAPIDS_VERSION_MAJOR_MINOR}-latest"
  if [[ "${BUILD_TYPE}" != "pull-request" ]]; then
    # create/update ":latest"
    docker manifest create "rapidsai/${IMAGE_REPO}:latest" "${source_tags[@]}"
    docker manifest push "rapidsai/${IMAGE_REPO}:latest"

    # create/update ":{rapids_version}-latest"
    docker manifest create "rapidsai/${IMAGE_REPO}:${MANIFEST_TAG}" "${source_tags[@]}"
    docker manifest push "rapidsai/${IMAGE_REPO}:${MANIFEST_TAG}"
  else
    echo "Skipping 'latest' and '${MANIFEST_TAG}' manifest creation for PR workflow."
  fi
fi
