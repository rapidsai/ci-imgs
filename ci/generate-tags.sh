#!/bin/bash
set -euo pipefail

if [[ ! "$CURRENT_TAG" =~ "ci-conda" ]]; then
  echo "TAG=$CURRENT_TAG" > "$GITHUB_OUTPUT"
  exit 0
fi

CI_TAG=$(echo "$CURRENT_TAG" | sed 's/ci-conda/ci/')

echo "TAG=$CURRENT_TAG,$CI_TAG" | tee --append "$GITHUB_OUTPUT"

