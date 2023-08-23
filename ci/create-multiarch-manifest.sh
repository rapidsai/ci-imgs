#!/bin/bash
set -euo pipefail

# if IMAGE_REPO is "ci" then compute the latest versions below
if [[ "${IMAGE_REPO}" == "ci" ]]; then
  LATEST_CUDA_VER=$(yq '.CUDA_VER | sort | .[-1]' matrix.yaml)
  LATEST_PYTHON_VER=$(yq -o json '.PYTHON_VER' matrix.yaml | jq -r 'max_by(split(".") | map(tonumber))')
  LATEST_UBUNTU_VER=$(yq '.LINUX_VER | map(select(. == "*ubuntu*")) | sort | .[-1]' matrix.yaml)
fi

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
