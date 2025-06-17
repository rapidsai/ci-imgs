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

echo "Updating to $NEXT_FULL_TAG"
echo "${NEXT_FULL_TAG}" > VERSION
