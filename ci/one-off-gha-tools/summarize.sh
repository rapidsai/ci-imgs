#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
find results -name '*-result.json' -exec cat {} + | jq -s . > results.json
{
  echo '# One-off gha-tools build benchmark'
  echo
  echo "Benchmark job result: ${BENCHMARK_RESULT:-unknown}. Missing samples are not successful runs."
  echo
  echo 'Seconds include build, compression, image push and cache export; builder startup is excluded.'
  echo 'Baseline has no remote cache. Cache and isolated variants import only their own cold-build seed.'
  echo 'All trials use fresh BuildKit builders. Cold means no imported build cache, not a cold registry/CDN.'
  echo
  echo '| Image | Arch | Variant | Scenario | Successful runs | Median seconds | Min–max |'
  echo '| --- | --- | --- | --- | --- | --- | --- |'
  jq -r --argjson expected "${EXPECTED_REPETITIONS}" '
    group_by([.image,.arch,.variant,.scenario])[] |
    . as $runs | map(select(.status == 0).seconds) | sort | . as $t |
    (length) as $n |
    (if $n == 0 then "failed" else
      (if $n % 2 == 1 then $t[($n/2|floor)] else ($t[$n/2-1]+$t[$n/2])/2 end | tostring)
    end) as $median |
    "| \($runs[0].image) | \($runs[0].arch) | \($runs[0].variant) | \($runs[0].scenario) | \($n)/\($expected) | \($median) | \($t|min)–\($t|max) |"
  ' results.json
  echo
  echo 'Compare cache versus isolated for tools-update to measure the benefit beyond remote caching.'
  echo 'Raw logs, input digests, per-build manifests and metadata are in the artifacts.'
  echo 'These measurements do not establish consumer pull latency or historical cache-hit frequency.'
} | tee summary.md >> "${GITHUB_STEP_SUMMARY}"
