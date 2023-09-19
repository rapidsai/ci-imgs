#!/bin/bash
set -euo pipefail

PREFIX="conda"
if [[ "${IMAGE_REPO}" != "ci-conda" ]]; then
  PREFIX="wheels"
fi

LATEST_CUDA_VER=$(yq -r ".$PREFIX.CUDA_VER" latest.yaml)
LATEST_PYTHON_VER=$(yq -r ".$PREFIX.PYTHON_VER" latest.yaml)
LATEST_UBUNTU_VER=$(yq -r ".$PREFIX.LINUX_VER" latest.yaml)

source_tags=()
tag="${IMAGE_NAME}"
for arch in $(echo "${ARCHES}" | jq .[] -r); do
  source_tags+=("${tag}-${arch}")
done

docker manifest create "${tag}" "${source_tags[@]}"
docker manifest push "${tag}"
if [[
  "${LATEST_UBUNTU_VER}" == "${LINUX_VER}" &&
  "${LATEST_CUDA_VER}" == "${CUDA_VER}" &&
  "${LATEST_PYTHON_VER}" == "${PYTHON_VER}"
]]; then
  # only create a 'latest' manifest if it is a non-PR workflow.
  if [[ "${BUILD_TYPE}" != "pull-request" ]]; then
    docker manifest create "rapidsai/${IMAGE_REPO}:latest" "${source_tags[@]}"
    docker manifest push "rapidsai/${IMAGE_REPO}:latest"
  else
    echo "Skipping 'latest' manifest creation for PR workflow."
  fi
fi

# publish rapidsai/ci manifests too
if [[ $IMAGE_NAME =~ ci-conda ]]; then
  IMAGE_NAME=$(echo "$IMAGE_NAME" | sed 's/ci-conda/ci/')
  source_tags=()
  tag="${IMAGE_NAME}"
  for arch in $(echo "${ARCHES}" | jq .[] -r); do
    source_tags+=("${tag}-${arch}")
  done

  docker manifest create "${tag}" "${source_tags[@]}"
  docker manifest push "${tag}"
  if [[
    "${LATEST_UBUNTU_VER}" == "${LINUX_VER}" &&
    "${LATEST_CUDA_VER}" == "${CUDA_VER}" &&
    "${LATEST_PYTHON_VER}" == "${PYTHON_VER}"
  ]]; then
    # only create a 'latest' manifest if it is a non-PR workflow.
    if [[ "${BUILD_TYPE}" != "pull-request" ]]; then
      docker manifest create "rapidsai/${IMAGE_REPO}:latest" "${source_tags[@]}"
      docker manifest push "rapidsai/${IMAGE_REPO}:latest"
    else
      echo "Skipping 'latest' manifest creation for PR workflow."
    fi
  fi
fi
