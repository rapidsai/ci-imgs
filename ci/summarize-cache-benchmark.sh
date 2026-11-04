#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
if [[ $# == 1 ]]; then
  cp "$1" benchmark-jobs.json
else
  gh api --paginate "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs?per_page=100" \
    | jq -s '{jobs:[.[].jobs[]]}' > benchmark-jobs.json
fi
jq '[.jobs[] |
  select(.name | test("^(baseline|seed|shared|scoped) ")) |
  . as $job | [.steps[]? | select(.name == "Build image")][0] as $step |
  select($step != null) |
  {job_id:$job.id,job:$job.name,scenario:($job.name | capture("^(?<s>baseline|seed|shared|scoped)").s),
   image:(if ($job.name | contains("ci-wheel")) then "ci-wheel" else "ci-conda" end),
   status:$step.conclusion,
   seconds:(if $step.started_at != null and $step.completed_at != null then
     (($step.completed_at|fromdateiso8601)-($step.started_at|fromdateiso8601)) else null end)}]
' benchmark-jobs.json > benchmark-results.json
{
  echo '# One-off registry cache benchmark'
  echo
  echo "Source commit: ${GITHUB_SHA}"
  echo
  echo 'ARM64 CPU4 runners; Rocky Linux 8, CUDA 13.4.3, Python 3.14.'
  echo 'One observation per image/scenario, each on a fresh runner and BuildKit builder.'
  echo 'Timings cover the Build image action, including cache import/export, compression and image publication; setup is excluded.'
  echo 'Image sources and version pins are identical. External package repositories, latest gha-tools, base tags and network conditions remain live.'
  echo
  echo '| Image | Scenario | Status | Build seconds |'
  echo '| --- | --- | --- | --- |'
  jq -r 'sort_by(.image,.scenario)[] | "| \(.image) | \(.scenario) | \(.status) | \(.seconds) |"' benchmark-results.json
  echo
  echo 'baseline: no remote cache import/export. seed: first population of an empty isolated cache.'
  echo 'shared: import the seed as the main cache and write a new scoped cache.'
  echo 'scoped: import both main and the scoped cache populated by shared.'
  echo 'All writes use run-specific staging tags. Production cache tags are untouched.'
  echo 'Raw build records and logs are attached to the individual image jobs.'
} | tee benchmark-summary.md >> "${GITHUB_STEP_SUMMARY}"
jq -e 'length == 8 and all(.[]; .status == "success" and .seconds != null)' benchmark-results.json > /dev/null
