#!/bin/bash
# Script to determine which image architectures should
# be built for different CUDA/OS variants.
# Example Usage:
#   CUDA_VER=11.5.1 LINUX_VER=rockylinux8 ./ci/compute-arch.sh
set -eu

PLATFORMS="linux/amd64"

write_platforms() {
  local PLATFORMS="${1}"

  # Use /dev/null to ensure the script can be tested locally
  echo "PLATFORMS=${PLATFORMS}" | tee --append "${GITHUB_OUTPUT:-/dev/null}"
}

if [[
  "${CUDA_VER}" > "11.2.2" &&
  "${LINUX_VER}" != "centos7"
]]; then
  PLATFORMS+=",linux/arm64"
fi

write_platforms "${PLATFORMS}"
