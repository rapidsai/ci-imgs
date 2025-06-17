#!/bin/bash
# Copyright (c) 2025, NVIDIA CORPORATION.
###########################
# ci-imgs Version Updater #
###########################

## Usage
# bash update-version.sh <new_version>

set -e

# Format is YY.MM.PP - no leading 'v' or trailing 'a'
NEXT_FULL_TAG=$1

# Get <major>.<minor> for next version
NEXT_MAJOR=$(echo "$NEXT_FULL_TAG" | awk '{split($0, a, "."); print a[1]}')
NEXT_MINOR=$(echo "$NEXT_FULL_TAG" | awk '{split($0, a, "."); print a[2]}')
NEXT_SHORT_TAG=${NEXT_MAJOR}.${NEXT_MINOR}

echo "Updating to $NEXT_FULL_TAG"
echo "${NEXT_FULL_TAG}" > VERSION
