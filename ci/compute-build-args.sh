#!/bin/bash
# Copyright (c) 2023-2025, NVIDIA CORPORATION.
set -euo pipefail

if [[
  "${IMAGE_REPO}" == "ci-wheel" &&
  "${LINUX_VER}" != "ubuntu20.04" &&
  "${LINUX_VER}" != "rockylinux8"
]]; then
  echo "Unsupported LINUX_VER: ${LINUX_VER} for ci-wheel image"
  exit 1
fi

RAPIDS_VERSION=$(cat VERSION)
RAPIDS_VERSION_MAJOR_MINOR=$(echo "${RAPIDS_VERSION}" | cut -d. -f1,2)

MANYLINUX_VER="manylinux_2_28"
if [[
  "${LINUX_VER}" == "ubuntu20.04"
]]; then
  MANYLINUX_VER="manylinux_2_31"
fi

# translate ARCH to conda-equivalent string values
CONDA_ARCH=$(echo "$ARCH" | sed 's#amd64#linux64#' | sed 's#arm64#aarch64#')

ARGS="
RAPIDS_VERSION: ${RAPIDS_VERSION}
RAPIDS_VERSION_MAJOR_MINOR: ${RAPIDS_VERSION_MAJOR_MINOR}
CUDA_VER: ${CUDA_VER}
LINUX_VER: ${LINUX_VER}
PYTHON_VER: ${PYTHON_VER}
CPU_ARCH: ${ARCH}
REAL_ARCH: $(arch)
MANYLINUX_VER: ${MANYLINUX_VER}
CONDA_ARCH: ${CONDA_ARCH}
"
export ARGS

if [ -n "${GITHUB_ACTIONS:-}" ]; then
cat <<EOF > "${GITHUB_OUTPUT:-/dev/stdout}"
ARGS<<EOT
$(yq -r '. + env(ARGS) | to_entries | map(.key + "=" + .value) | join(" \n")' versions.yaml)
EOT
EOF
else
  yq -r '. + env(ARGS) | to_entries | map("--build-arg " + .key + "=" + .value) | join(" ")' versions.yaml
fi
