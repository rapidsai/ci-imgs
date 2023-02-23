#!/bin/bash
# Script to determine which image architectures should
# be built for different CUDA/OS variants.
# Example Usage:
#   CUDA_VER=11.5.1 LINUX_VER=centos8 ./ci/compute-arch.sh
set -eu

PLATFORMS="linux/amd64"

write_platforms() {
  local PLATFORMS="${1}"

  # Use /dev/null to ensure the script can be tested locally
  echo "PLATFORMS=${PLATFORMS}" | tee --append "${GITHUB_OUTPUT:-/dev/null}"
}

# Ubuntu 18.04 images don't officially support arm64.
# Even though Ubuntu 18.04 images prior to CUDA 11.8.0 did
# have arm64 variants, they were removed for 11.8.0.
if [[
  ("${CUDA_VER}" == "11.8.0" || "${CUDA_VER}" == "12.0.1") &&
  ("${LINUX_VER}" == "ubuntu18.04")
]]; then
  write_platforms "${PLATFORMS}"
  exit 0
fi

if [[
  "${CUDA_VER}" > "11.2.2" &&
  "${LINUX_VER}" != "centos7"
]]; then
  PLATFORMS+=",linux/arm64"
fi

write_platforms "${PLATFORMS}"
