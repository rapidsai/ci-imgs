#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
gh api --paginate "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs?per_page=100" | jq -s '{jobs:[.[].jobs[]]}' > refresh-jobs.json
find evidence -name '*.json' ! -name '*-manifest.json' -exec cat {} + | jq -s . > refresh-results.json
jq --slurpfile jobs refresh-jobs.json 'map(. as $r |
  ([$jobs[0].jobs[] | select(.name | startswith($r.phase+" ("+$r.image+")")) | .steps[]? | select(.name == "Build image")][0]) as $step |
  . + {seconds:(if $step.started_at != null and $step.completed_at != null then
    ($step.completed_at|fromdateiso8601)-($step.started_at|fromdateiso8601) else null end)})' refresh-results.json > refresh-results.tmp
mv refresh-results.tmp refresh-results.json
{
  echo '# Verified gha-tools refresh benchmark'
  echo
  echo 'Fresh ARM64 CPU4 runners; CUDA 13.4.3, Rocky Linux 8, Python 3.14.'
  echo 'Seed: cold full build and registry-cache population using the older tool release.'
  echo 'Warm: fresh builder imports that cache and installs the newer release only in the final stage.'
  echo 'Base digests, source and construction-time tool release are frozen; package repositories remain live.'
  echo 'Timings cover the Build image action, including image and cache exports. Artifact setup and post-build content verification are excluded.'
  echo 'Temporary benchmark copies pin the two tool archives; production Dockerfiles and workflow interfaces are unchanged.'
  echo
  echo '| Image | Phase | Tool release | Build seconds | Reused construction layers | Final layer bytes | Release files verified |'
  echo '| --- | --- | --- | --- | --- | --- | --- |'
  jq -r 'sort_by(.image,.phase)[] | "| \(.image) | \(.phase) | \(.release) | \(.seconds) | \(.reused_construction_layers) | \(.last_layer_bytes) | \(.verified) |"' refresh-results.json
} | tee refresh-summary.md >> "${GITHUB_STEP_SUMMARY}"
jq -e 'length == 4 and all(.[]; .verified == true and .seconds != null)' refresh-results.json > /dev/null
