#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

config_path=${CANDIDATE_BUILDKIT_CONFIG:-/etc/buildkit/buildkitd.toml}
if [[ ! -r "${config_path}" ]]; then
  echo "Candidate BuildKit configuration is missing or unreadable: ${config_path}" >&2
  exit 1
fi
