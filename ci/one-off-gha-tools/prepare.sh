#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
phase=initialization
preparation_failed() {
  printf '::error::Benchmark preparation failed during %s (line %s, exit %s)\n' "${phase}" "$2" "$1" >&2
  exit "$1"
}
trap 'preparation_failed "$?" "$LINENO"' ERR
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -n ${BENCHMARK_SOURCE_DIR:-} ]]; then cd "${BENCHMARK_SOURCE_DIR}"; fi

[[ ${REPETITIONS} =~ ^[1-5]$ ]]
[[ ${CUDA_VER} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ ${PYTHON_VER} =~ ^3\.[0-9]+$ ]]
mkdir -p prepared
cp -R context prepared/context
cp versions.yaml prepared/
cp "${script_dir}/"*.sh prepared/

# Resolve floating release choices once, before any timed build.
phase='resolving gha-tools releases'
echo "${phase}"
gh api 'repos/rapidsai/gha-tools/releases?per_page=100' > prepared/releases.json
for slot in OLD NEW; do
  if [[ ${slot} == OLD ]]; then version=${OLD_VERSION}; else version=${NEW_VERSION}; fi
  case ${version} in
    previous) version=$(jq -r '[.[] | select(.draft == false and .prerelease == false)][1].tag_name' prepared/releases.json) ;;
    latest) version=$(jq -r '[.[] | select(.draft == false and .prerelease == false)][0].tag_name' prepared/releases.json) ;;
  esac
  version=${version#v}
  [[ ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  curl --fail --location --retry 5 "https://github.com/rapidsai/gha-tools/releases/download/v${version}/tools.tar.gz" -o "prepared/${slot}.tar.gz"
  sha=$(sha256sum "prepared/${slot}.tar.gz" | cut -d ' ' -f 1)
  jq -n --arg version "${version}" --arg sha "${sha}" '{version:$version,sha256:$sha}' > "prepared/${slot}.json"
done
[[ $(jq -r .version prepared/OLD.json) != "$(jq -r .version prepared/NEW.json)" ]]
rm prepared/*.tar.gz

# Keep this installer identical across X/Y builds; only build arguments change.
phase='preparing pinned gha-tools installer'
awk '
  /wget -q https:\/\/github.com\/rapidsai\/gha-tools\/releases\/latest\/download/ {
    print "  : \"${GHA_TOOLS_VERSION:?}\" \"${GHA_TOOLS_SHA256:?}\""
    print "  gha_tools_archive=$(mktemp)"
    print "  wget -q \"https://github.com/rapidsai/gha-tools/releases/download/v${GHA_TOOLS_VERSION}/tools.tar.gz\" -O \"${gha_tools_archive}\""
    print "  echo \"${GHA_TOOLS_SHA256}  ${gha_tools_archive}\" | sha256sum --check --status"
    print "  tar -xzf \"${gha_tools_archive}\" -C \"${TOOL_INSTALL_DIR}\""
    print "  rm -f \"${gha_tools_archive}\""
    found++; next
  }
  { print }
  END { if (found != 1) exit 1 }
' context/scripts/install-tools > prepared/context/scripts/install-tools

# Pin every FROM input by digest, shared by all variants and repetitions.
for kind in ci-wheel ci-conda; do
  if [[ ${kind} == ci-wheel ]]; then flavor=devel; else flavor=base; fi
  base="nvidia/cuda:${CUDA_VER}-${flavor}-rockylinux8"
  phase="resolving ${base}"
  echo "${phase}"
  # Consume the complete output. An early-exiting filter can give the Docker CLI
  # a broken pipe and make it exit 255, even after printing the requested digest.
  digest=$(docker buildx imagetools inspect "${base}" --format '{{json .Manifest}}' | jq -er '.digest')
  [[ ${digest} =~ ^sha256:[a-f0-9]{64}$ ]]
  cp "${kind}.Dockerfile" "prepared/${kind}.source"
  if [[ ${kind} == ci-wheel ]]; then
    ci/sync-base-env.sh "${base}@${digest}" "prepared/${kind}.source"
  fi
  forge=$(awk '$1 == "MINIFORGE_VER:" {print $2}' versions.yaml)
  phase="resolving condaforge/miniforge3:${forge}"
  echo "${phase}"
  forge_digest=$(docker buildx imagetools inspect "condaforge/miniforge3:${forge}" --format '{{json .Manifest}}' | jq -er '.digest')
  [[ ${forge_digest} =~ ^sha256:[a-f0-9]{64}$ ]]
  for variant in baseline cache isolated; do
    phase="generating ${kind}-${variant}.Dockerfile"
    echo "${phase}"
    awk -v base="${base}@${digest}" -v forge="condaforge/miniforge3:${forge}@${forge_digest}" -v isolated="${variant}" '
      NR == FNR {
        if ($0 ~ /^RUN /) run_line = FNR
        if ($0 ~ /^ *\/tmp\/build-scripts\/install-tools/) installs[run_line] = 1
        next
      }
      FNR in installs {
        print "ARG BENCH_CORE_VERSION"
        print "ARG BENCH_CORE_SHA256"
      }
      /^FROM / {
        if ($2 == "${BASE_IMAGE}" || $2 ~ /^nvidia\/cuda:/) $2 = base
        if ($2 ~ /^condaforge\/miniforge3:/) $2 = forge
        print
        next
      }
      /^CMD / && isolated == "isolated" {
        print "ARG BENCH_RUNTIME_VERSION"
        print "ARG BENCH_RUNTIME_SHA256"
        print "RUN --mount=type=bind,source=scripts,target=/tmp/build-scripts \\\n    GHA_TOOLS_VERSION=${BENCH_RUNTIME_VERSION} GHA_TOOLS_SHA256=${BENCH_RUNTIME_SHA256} \\\n    /tmp/build-scripts/install-tools --gha-tools"
      }
      /^ *\/tmp\/build-scripts\/install-tools/ {
        print "GHA_TOOLS_VERSION=${BENCH_CORE_VERSION} GHA_TOOLS_SHA256=${BENCH_CORE_SHA256} \\"
      }
      { print }
    ' "prepared/${kind}.source" "prepared/${kind}.source" > "prepared/${kind}-${variant}.Dockerfile"
  done
  jq -n --arg base "${base}@${digest}" --arg forge "condaforge/miniforge3:${forge}@${forge_digest}" '{base:$base,miniforge:$forge}' > "prepared/${kind}-bases.json"
done
phase='recording frozen benchmark inputs'
jq -n --arg sha "$(git rev-parse HEAD)" --arg cuda "${CUDA_VER}" --arg python "${PYTHON_VER}" \
  --arg rapids "$(cut -d . -f 1,2 VERSION)" \
  '{source_sha:$sha,cuda:$cuda,python:$python,rapids:$rapids,os:"rockylinux8"}' > prepared/inputs.json
jq -cn --argjson n "${REPETITIONS}" '{image:["ci-wheel","ci-conda"],repetition:[range(1;$n+1)]}' | sed 's/^/matrix=/' >> "${GITHUB_OUTPUT}"
echo "repetitions=${REPETITIONS}" >> "${GITHUB_OUTPUT}"
