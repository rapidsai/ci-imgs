#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
trap 'echo "::error::Benchmark preparation failed at line ${LINENO}" >&2' ERR
mkdir -p prepared
cp -R context prepared/context
cp ci/one-off-refresh/verify.sh prepared/
gh api 'repos/rapidsai/gha-tools/releases?per_page=100' > prepared/releases.json
for slot in OLD NEW; do
  index=0
  if [[ ${slot} == OLD ]]; then index=1; fi
  version=$(jq -r --argjson index "${index}" '[.[] | select(.draft == false and .prerelease == false)][$index].tag_name' prepared/releases.json)
  version=${version#v}
  [[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  curl --fail --location --retry 5 "https://github.com/rapidsai/gha-tools/releases/download/v${version}/tools.tar.gz" -o "prepared/${slot}.tar.gz"
  jq -n --arg version "${version}" --arg sha "$(sha256sum "prepared/${slot}.tar.gz" | cut -d ' ' -f 1)" '{version:$version,sha256:$sha}' > "prepared/${slot}.json"
done
old_version=$(jq -r .version prepared/OLD.json)
old_sha=$(jq -r .sha256 prepared/OLD.json)
# Identical context for seed and warm builds. Only the final stage declares the
# benchmark args; construction uses the frozen older release in both builds.
awk -v version="${old_version}" -v sha="${old_sha}" '
  /wget -q https:\/\/github.com\/rapidsai\/gha-tools\/releases\/latest\/download/ {
    print "  tools_version=\"${BENCHMARK_TOOLS_VERSION:-" version "}\""
    print "  tools_sha=\"${BENCHMARK_TOOLS_SHA256:-" sha "}\""
    print "  tools_archive=$(mktemp)"
    print "  wget -q \"https://github.com/rapidsai/gha-tools/releases/download/v${tools_version}/tools.tar.gz\" -O \"${tools_archive}\""
    print "  echo \"${tools_sha}  ${tools_archive}\" | sha256sum --check --status"
    print "  tar -xzf \"${tools_archive}\" -C \"${TOOL_INSTALL_DIR}\""
    print "  rm -f \"${tools_archive}\""
    found++; next
  }
  {print}
  END {if (found != 1) exit 1}
' context/scripts/install-tools > prepared/context/scripts/install-tools
# Use the repository build-argument generator with the frozen helper release.
mkdir prepared/host-tools
tar -xzf prepared/OLD.tar.gz -C prepared/host-tools
export PATH="${PWD}/prepared/host-tools:${PATH}"
export CUDA_VER=13.4.3 LINUX_VER=rockylinux8 PYTHON_VER=3.14 ARCH=arm64
[[ $(uname -m) == aarch64 ]]
forge=$(yq -r .MINIFORGE_VER versions.yaml)
forge_digest=$(docker buildx imagetools inspect "condaforge/miniforge3:${forge}" --format '{{json .Manifest}}' | jq -er .digest)
for image in ci-conda ci-wheel; do
  export IMAGE_REPO=${image}
  GITHUB_OUTPUT="${PWD}/prepared/args-output" ci/compute-build-args.sh
  sed '1d;$d' prepared/args-output > "prepared/${image}.args"
  flavor=base
  if [[ ${image} == ci-wheel ]]; then flavor=devel; fi
  base="nvidia/cuda:${CUDA_VER}-${flavor}-${LINUX_VER}"
  digest=$(docker buildx imagetools inspect "${base}" --format '{{json .Manifest}}' | jq -er .digest)
  cp "${image}.Dockerfile" "prepared/${image}.source"
  if [[ ${image} == ci-wheel ]]; then ci/sync-base-env.sh "${base}@${digest}" "prepared/${image}.source"; fi
  awk -v base="${base}@${digest}" -v forge="condaforge/miniforge3:${forge}@${forge_digest}" '
    /^FROM / {
      if ($2 == "${BASE_IMAGE}" || $2 ~ /^nvidia\/cuda:/) $2=base
      if ($2 ~ /^condaforge\/miniforge3:/) $2=forge
      print
      if ($0 ~ / AS gha-tools-update$/) {
        print "ARG BENCHMARK_TOOLS_VERSION"
        print "ARG BENCHMARK_TOOLS_SHA256"
      }
      next
    }
    {print}
  ' "prepared/${image}.source" > "prepared/${image}.Dockerfile"
done
jq -n --arg source "$(git rev-parse HEAD)" '{source:$source,arch:"arm64",cuda:"13.4.3",os:"rockylinux8",python:"3.14"}' > prepared/source.json
