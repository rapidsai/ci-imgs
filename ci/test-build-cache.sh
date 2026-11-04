#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fixture_dir=$(mktemp -d)
trap 'rm -rf "${fixture_dir}"' EXIT

# Exercise all image kinds and two values for each cache-key input.
for build_type in branch pull-request; do
  for release in 26.12 27.02; do
    for pr in 467 468; do
      BUILD_TYPE=${build_type} RAPIDS_VERSION_MAJOR_MINOR=${release} PR_NUM=${pr} \
        jq -n 'include "ci/compute-matrix";
          {CUDA_VER:["12.9.2","13.4.3"], LINUX_VER:["rockylinux8","ubuntu24.04"],
           PYTHON_VER:["3.13","3.14"], CI_IMAGE_CONFIG:[
             {IMAGE_REPO:"ci-wheel",dockerfile:"ci-wheel.Dockerfile",docker_target:""},
             {IMAGE_REPO:"ci-conda",dockerfile:"ci-conda.Dockerfile",docker_target:""},
             {IMAGE_REPO:"citestwheel",dockerfile:"citestwheel.Dockerfile",docker_target:""}]} |
          compute_matrix(.)' > "${fixture_dir}/${build_type}-${release}-${pr}.json"
    done
  done
done

for matrix in "${fixture_dir}/"*.json; do
  jq -e '
    all(.include[];
      .CACHE_IMAGE_NAME == ("rapidsai/" + .IMAGE_REPO + ":cuda" + .CUDA_VER + "-" + .LINUX_VER + "-py" + .PYTHON_VER)
      and .ARCHES == ["amd64","arm64"])
    and ([.include[].CACHE_IMAGE_NAME] | length == (unique | length))
  ' "${matrix}" > /dev/null
done

for pr in 467 468; do
  for build_type in branch pull-request; do
    # Release rollover preserves both read and write cache names.
    jq -e --slurpfile next "${fixture_dir}/${build_type}-27.02-${pr}.json" '
      [.include[] | [.CACHE_IMAGE_NAME,.IMAGE_NAME_NO_RAPIDS_VERSION]] ==
      [$next[0].include[] | [.CACHE_IMAGE_NAME,.IMAGE_NAME_NO_RAPIDS_VERSION]]
    ' "${fixture_dir}/${build_type}-26.12-${pr}.json" > /dev/null
  done
  jq -e --arg pr "${pr}" --slurpfile branch "${fixture_dir}/branch-26.12-${pr}.json" '
    [.include[].CACHE_IMAGE_NAME] == [$branch[0].include[].CACHE_IMAGE_NAME]
    and all(.include[];
      .IMAGE_NAME_NO_RAPIDS_VERSION ==
      ("rapidsai/staging:" + .IMAGE_REPO + "-" + $pr + "-cuda" + .CUDA_VER + "-" + .LINUX_VER + "-py" + .PYTHON_VER))
  ' "${fixture_dir}/pull-request-26.12-${pr}.json" > /dev/null
done

# Independent PRs never share a write tag, and main writes only its stable caches.
jq -e --slurpfile other "${fixture_dir}/pull-request-26.12-468.json" '
  [.include[].IMAGE_NAME_NO_RAPIDS_VERSION] as $ours |
  all($other[0].include[]; .IMAGE_NAME_NO_RAPIDS_VERSION as $tag | $ours | index($tag) | not)
' "${fixture_dir}/pull-request-26.12-467.json" > /dev/null
jq -e 'all(.include[]; .CACHE_IMAGE_NAME == .IMAGE_NAME_NO_RAPIDS_VERSION)' \
  "${fixture_dir}/branch-26.12-467.json" > /dev/null

echo 'Build cache scope checks passed'
