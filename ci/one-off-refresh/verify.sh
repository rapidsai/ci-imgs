#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
mkdir -p evidence
slot=OLD
if [[ ${PHASE} == warm ]]; then slot=NEW; fi
archive="${PWD}/prepared/${slot}.tar.gz"
# Verify every release file in the actual produced image, using its immutable digest.
docker pull "${IMAGE_TAG}@${IMAGE_DIGEST}"
docker run --rm --entrypoint /bin/bash \
  --mount "type=bind,source=${archive},target=/tmp/expected-tools.tar.gz,readonly" \
  "${IMAGE_TAG}@${IMAGE_DIGEST}" -euo pipefail -c '
    expected=$(mktemp -d)
    trap '\''rm -rf "${expected}"'\'' EXIT
    tar -xzf /tmp/expected-tools.tar.gz -C "${expected}"
    while IFS= read -r -d "" file; do
      relative=${file#"${expected}/"}
      expected_hash=$(sha256sum "${file}")
      installed_hash=$(sha256sum "/usr/local/bin/${relative}")
      [[ ${expected_hash%% *} == "${installed_hash%% *}" ]]
      if [[ -x ${file} ]]; then [[ -x /usr/local/bin/${relative} ]]; fi
    done < <(find "${expected}" -type f -print0)
    echo "Installed release files match the expected archive"
  '
manifest="evidence/${IMAGE}-${PHASE}-manifest.json"
docker buildx imagetools inspect "${IMAGE_TAG}@${IMAGE_DIGEST}" --raw > "${manifest}"
child=$(jq -r '.manifests[]? | select(.platform.architecture == "arm64") | .digest' "${manifest}")
if [[ -n ${child} ]]; then docker buildx imagetools inspect "${IMAGE_TAG}@${child}" --raw > "${manifest}"; fi
jq -e '.layers | length > 1' "${manifest}" > /dev/null
if [[ ${PHASE} == warm ]]; then
  jq -e --slurpfile seed "seed/${IMAGE}-seed-manifest.json" '
    [.layers[:-1][].digest] == [$seed[0].layers[:-1][].digest] and
    .layers[-1].digest != $seed[0].layers[-1].digest
  ' "${manifest}" > /dev/null
  echo 'PASS: all construction layers reused; only the tools layer changed'
fi
jq -n --arg image "${IMAGE}" --arg phase "${PHASE}" --arg digest "${IMAGE_DIGEST}" \
  --slurpfile release "prepared/${slot}.json" --slurpfile manifest "${manifest}" \
  '{image:$image,phase:$phase,digest:$digest,release:$release[0].version,verified:true,
    layers:($manifest[0].layers|length),last_layer_bytes:$manifest[0].layers[-1].size,
    reused_construction_layers:(if $phase=="warm" then ($manifest[0].layers|length)-1 else null end)}' \
  > "evidence/${IMAGE}-${PHASE}.json"
