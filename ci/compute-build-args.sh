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

# Candidate images build FROM exactly the base images the release train recorded: CANDIDATE_BASE_IMAGES maps each
# build argument to <tag>@sha256:<digest>, and every tag must be the one candidate_base_images (ci/compute-matrix.jq)
# names for this row, so the planner and the build agree. Nothing is resolved here. The canonical Docker Hub
# references keep the runner's configured Docker and BuildKit mirrors handling every pull. Production is unchanged.
if [[ "${CANDIDATE_IMAGE_MIRROR:-false}" == "true" ]]; then
  if ! jq -e 'type == "object"' <<<"${CANDIDATE_BASE_IMAGES:-}" >/dev/null 2>&1; then
    echo "candidate images need CANDIDATE_BASE_IMAGES, the release train's base images for this row" >&2
    exit 1
  fi
  base_args="$(
    jq -nr \
      --arg repo "${IMAGE_REPO}" --arg cuda "${CUDA_VER}" --arg linux "${LINUX_VER}" \
      --argjson versions "$(yq -o=json versions.yaml)" \
      --argjson given "${CANDIDATE_BASE_IMAGES}" \
      'include "ci/compute-matrix";
       {IMAGE_REPO: $repo, CUDA_VER: $cuda, LINUX_VER: $linux} | candidate_base_images($versions) as $tags
       | if ($given | keys) != ($tags | keys) then error("wrong base image arguments")
         else $tags | to_entries | map(
           .key as $argument | .value as $tag | $given[$argument] as $reference
           | if ($reference | type) == "string" and ($reference | startswith($tag + "@sha256:"))
               and ($reference | ltrimstr($tag + "@sha256:") | test("^[0-9a-f]{64}$"))
             then "\($argument): \($reference)"
             else error("\($argument) is not \($tag) pinned by digest")
             end
         ) | join("\n")
         end'
  )" || {
    echo "CANDIDATE_BASE_IMAGES does not match this row's base images" >&2
    exit 1
  }
  ARGS+=$'\n'"${base_args}"
fi

export ARGS

if [[ "${CANDIDATE_GHA_TOOLS_SOURCE:-false}" == "true" ]]; then
  if [[ ! "${RELEASE_CANDIDATE_GHA_TOOLS_REVISION:-}" =~ ^[0-9a-f]{40}$ ]]; then
    echo 'Candidate image bootstrap requires the frozen gha-tools revision' >&2
    exit 1
  fi
  ARGS+=$'\nGHA_TOOLS_CANDIDATE_REVISION: '"${RELEASE_CANDIDATE_GHA_TOOLS_REVISION}"
fi

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
