#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

: "${IMAGE_NAME:?Image tag is required}"
: "${ARCH:?Image architecture is required}"
: "${RAPIDS_VERSION_MAJOR_MINOR:?Frozen container version is required}"
if [[ ! "${ARCH}" =~ ^(amd64|arm64)$ ]] ||
   [[ ! "${IMAGE_NAME}" =~ ^rapidsai/(ci-conda|ci-wheel|citestwheel):[0-9]{2}\.[0-9]{2}-cuda[0-9.]+-[a-z0-9.]+-py[0-9.]+$ ]]; then
  echo 'Invalid candidate image identity' >&2
  exit 1
fi
variant="${IMAGE_NAME#*:}-${ARCH}"
if [[ "${variant}" != "${RAPIDS_VERSION_MAJOR_MINOR}-"* ]]; then
  echo 'Image variant does not match the frozen container version' >&2
  exit 1
fi
mkdir -p .release-candidate-artifacts/container
gzip --no-name .release-candidate-artifacts/container/image.tar
mv .release-candidate-artifacts/container/image.tar.gz \
  ".release-candidate-artifacts/container/image-${variant}.tar.gz"
jq -n --arg name "docker.io/${IMAGE_NAME%%:*}" \
  --arg version "${RAPIDS_VERSION_MAJOR_MINOR}" --arg build "${variant}" --arg platform "linux/${ARCH}" \
  '{ecosystem:"container",name:$name,version:$version,build:$build,platform:$platform}' \
  > .release-candidate-artifacts/container/package-identity.json
