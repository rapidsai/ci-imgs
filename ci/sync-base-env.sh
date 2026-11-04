#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# [description]
#
#   'COPY --from=<base> / /' copies files from <base> but loses
#   image metadata like 'ENV'.
#
#   This script reads the ENV from a base image and writes it
#   into a Dockerfile, so the final image has the same environment variables
#   as the base image.
#
# [usage]
#
#   ci/sync-base-env.sh nvidia/cuda:${CUDA_VER}-devel-${LINUX_VER}
#

set -e -u -o pipefail

BASE_IMAGE="${1}"
DOCKERFILE="${2}"

BEGIN_MARKER='# BEGIN base-image ENV (used by ci/sync-base-env.sh, do not edit)'
END_MARKER='# END base-image ENV (used by ci/sync-base-env.sh, do not edit)'

if ! docker image inspect "${BASE_IMAGE}" > /dev/null 2>&1; then
  echo "Pulling ${BASE_IMAGE}" >&2
  docker pull "${BASE_IMAGE}" >&2
fi

# One 'KEY="value"' per base-image ENV entry. Values are escaped for a Dockerfile:
# backslashes, double quotes and '$' (which would otherwise be expanded at build time).
ENV_ARGS="$(
  docker image inspect --format '{{json .Config.Env}}' "${BASE_IMAGE}" \
  | jq -r '
      .[]
      | index("=") as $i
      | .[:$i] + "=\"" + (.[$i+1:] | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\\$"; "\\$")) + "\""
    '
)"

BLOCK_FILE="$(mktemp)"
OUT_FILE="$(mktemp)"
trap 'rm -f "${BLOCK_FILE}" "${OUT_FILE}"' EXIT

{
  echo "${BEGIN_MARKER}"
  echo "# source: ${BASE_IMAGE}"
  echo "ENV \\"
  # join entries with ' \' continuation, no trailing backslash on the last one
  echo "${ENV_ARGS}" | sed 's/^/    /' | sed '$!s/$/ \\/'
  echo "${END_MARKER}"
} > "${BLOCK_FILE}"

# replace the existing generated block
awk \
  -v begin="${BEGIN_MARKER}" \
  -v end="${END_MARKER}" \
  -v block_file="${BLOCK_FILE}" \
  '$0 == begin { skipping = 1; while ((getline line < block_file) > 0) print line; next }
  skipping    { if ($0 == end) skipping = 0; next }
  { print }
' "${DOCKERFILE}" > "${OUT_FILE}"

cat "${OUT_FILE}" > "${DOCKERFILE}"
echo "Generated ENV statements from '${BASE_IMAGE}' in '${DOCKERFILE}'" >&2
