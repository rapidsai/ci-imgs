#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd prepared
mkdir -p results
prefix="rapidsai/staging:gha-bench-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${IMAGE}-${REPETITION}"
cuda=$(jq -r .cuda inputs.json)
python=$(jq -r .python inputs.json)
rapids=$(jq -r .rapids inputs.json)
old=$(jq -r .version OLD.json)
old_sha=$(jq -r .sha256 OLD.json)
new=$(jq -r .version NEW.json)
new_sha=$(jq -r .sha256 NEW.json)
case ${ARCH} in amd64) conda_arch=linux64; real_arch=x86_64 ;; arm64) conda_arch=aarch64; real_arch=aarch64 ;; *) exit 1 ;; esac
[[ $(uname -m) == "${real_arch}" ]]
args=()
while read -r key value; do
  [[ ${key} == \#* || -z ${key} ]] && continue
  args+=(--build-arg "${key%:}=${value}")
done < versions.yaml
args+=(--build-arg "CUDA_VER=${cuda}" --build-arg LINUX_VER=rockylinux8
  --build-arg "PYTHON_VER=${python}" --build-arg "CPU_ARCH=${ARCH}"
  --build-arg "REAL_ARCH=${real_arch}" --build-arg "CONDA_ARCH=${conda_arch}"
  --build-arg MANYLINUX_VER=manylinux_2_28 --build-arg "RAPIDS_VERSION_MAJOR_MINOR=${rapids}")

# Alternate order to limit systematic network/load bias between paired trials.
variants=(baseline cache isolated)
if (( REPETITION % 2 == 0 )); then variants=(isolated cache baseline); fi
builder="gha-bench-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${IMAGE}-${REPETITION}"
trap 'docker buildx rm "${builder}" >/dev/null 2>&1 || true' EXIT
for variant in "${variants[@]}"; do
  for scenario in cold unchanged tools-update; do
    core=${old}; core_sha=${old_sha}; runtime=${old}; runtime_sha=${old_sha}
    if [[ ${scenario} == tools-update ]]; then
      runtime=${new}; runtime_sha=${new_sha}
      if [[ ${variant} != isolated ]]; then core=${new}; core_sha=${new_sha}; fi
    fi
    # A new containerized builder has no local layer/content cache.
    docker buildx create --name "${builder}" --driver docker-container \
      --buildkitd-config /etc/buildkit/buildkitd.toml --use
    docker buildx inspect --bootstrap "${builder}"
    cache_args=()
    if [[ ${variant} != baseline ]]; then
      if [[ ${scenario} != cold ]]; then
        cache_args+=(--cache-from "type=registry,ref=${prefix}-${variant}-seed")
      fi
      # Never overwrite the seed when measuring a rebuild.
      cache_tag="${prefix}-${variant}-${scenario}"
      if [[ ${scenario} == cold ]]; then cache_tag="${prefix}-${variant}-seed"; fi
      cache_args+=(--cache-to "type=registry,ref=${cache_tag},mode=max,compression=zstd,oci-mediatypes=true,image-manifest=true")
    fi
    stem="${IMAGE}-${REPETITION}-${variant}-${scenario}"
    tag="${prefix}-${variant}-${scenario}"
    start=$(date +%s)
    status=0
    docker buildx build --builder "${builder}" --platform "linux/${ARCH}" \
      --file "${IMAGE}-${variant}.Dockerfile" "${args[@]}" \
      --build-arg "BENCH_CORE_VERSION=${core}" --build-arg "BENCH_CORE_SHA256=${core_sha}" \
      --build-arg "BENCH_RUNTIME_VERSION=${runtime}" --build-arg "BENCH_RUNTIME_SHA256=${runtime_sha}" \
      --secret id=GH_TOKEN,env=GH_TOKEN "${cache_args[@]}" \
      --output "type=registry,name=${tag},compression=zstd,force-compression=true,oci-mediatypes=true,compression-level=15" \
      --provenance=false --sbom=false --progress=rawjson \
      --metadata-file "results/${stem}-metadata.json" context \
      > "results/${stem}.stdout" 2> "results/${stem}.jsonl" || status=$?
    elapsed=$(( $(date +%s) - start ))
    jq -n --arg image "${IMAGE}" --arg variant "${variant}" --arg scenario "${scenario}" \
      --arg arch "${ARCH}" --arg tag "${tag}" --argjson repetition "${REPETITION}" \
      --argjson seconds "${elapsed}" --argjson status "${status}" \
      '{image:$image,arch:$arch,repetition:$repetition,variant:$variant,scenario:$scenario,seconds:$seconds,status:$status,tag:$tag}' \
      > "results/${stem}-result.json"
    docker buildx rm "${builder}"
    if (( status != 0 )); then tail -n 30 "results/${stem}.jsonl"; exit "${status}"; fi
    digest=$(jq -r '."containerimage.digest"' "results/${stem}-metadata.json")
    docker buildx imagetools inspect "${tag}@${digest}" --raw > "results/${stem}-manifest.json"
    # A single-platform export may still use an index. Save the actual layer manifest.
    child=$(jq -r --arg arch "${ARCH}" '.manifests[]? | select(.platform.architecture == $arch) | .digest' "results/${stem}-manifest.json")
    if [[ -n ${child} ]]; then
      docker buildx imagetools inspect "${tag}@${child}" --raw > "results/${stem}-manifest.json"
    fi
  done
done
