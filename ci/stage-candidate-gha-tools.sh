#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

: "${RAPIDS_RELEASE_CANDIDATE_TRAIN_FILE:?Frozen train file is required}"
: "${RELEASE_CANDIDATE_TRAIN_SHA256:?Frozen train identity is required}"
: "${RELEASE_CANDIDATE_GHA_TOOLS_REVISION:?Frozen gha-tools revision is required}"
if [[ ! "${RELEASE_CANDIDATE_TRAIN_SHA256}" =~ ^[0-9a-f]{64}$ ]] ||
   [[ ! "${RELEASE_CANDIDATE_GHA_TOOLS_REVISION}" =~ ^[0-9a-f]{40}$ ]]; then
  echo 'Invalid frozen train/tool identity' >&2
  exit 1
fi
expected_revision=$(jq -er --arg train "${RELEASE_CANDIDATE_TRAIN_SHA256}" '
  if .train_sha256 == $train then .build_implementation_revisions["gha-tools"]
  else error("train identity mismatch") end
' "${RAPIDS_RELEASE_CANDIDATE_TRAIN_FILE}")
if [[ "${expected_revision}" != "${RELEASE_CANDIDATE_GHA_TOOLS_REVISION}" ]]; then
  echo 'gha-tools revision does not match the frozen train' >&2
  exit 1
fi
tool_checkout="$(dirname "${RAPIDS_RELEASE_CANDIDATE_TRAIN_FILE}")/gha-tools"
if [[ "$(git -C "${tool_checkout}" rev-parse HEAD)" != "${expected_revision}" ]]; then
  echo 'gha-tools checkout does not match the frozen revision' >&2
  exit 1
fi
# Package committed tools, never a possibly modified worktree or operator config.
git -C "${tool_checkout}" ls-tree -r "${expected_revision}" tools |
  awk '$1 != "100644" && $1 != "100755" { exit 1 }'
destination=context/scripts/candidate-gha-tools
mkdir -p "${destination}"
git -C "${tool_checkout}" archive --format=tar "${expected_revision}" tools |
  gzip --no-name > "${destination}/tools.tar.gz"
printf '%s\n' "${expected_revision}" > "${destination}/revision.txt"
sha256sum "${destination}/tools.tar.gz" | cut -d ' ' -f 1 > "${destination}/sha256.txt"
