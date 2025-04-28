#!/bin/bash
set -euo pipefail

if [[
  "${IMAGE_REPO}" == "ci-wheel" &&
  "${LINUX_VER}" != "ubuntu20.04" &&
  "${LINUX_VER}" != "rockylinux8"
]]; then
  echo "Unsupported LINUX_VER: ${LINUX_VER} for ci-wheel image"
  exit 1
fi

MANYLINUX_VER="manylinux_2_28"
if [[
  "${LINUX_VER}" == "ubuntu20.04"
]]; then
  MANYLINUX_VER="manylinux_2_31"
fi


# Set BASE_IMAGE based on LINUX_VER
case "${LINUX_VER}" in
  "ubuntu"*)
    BASE_IMAGE="ubuntu:${LINUX_VER#ubuntu}"
    ;;
  "rockylinux"*)
    BASE_IMAGE="rockylinux:${LINUX_VER#rockylinux}"
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}"
    exit 1
    ;;
esac

# Translate ARCH to equivalent string values for NVARCH and CONDA_ARCH
case "${ARCH}" in
  "amd64")
    NVARCH="x86_64"
    CONDA_ARCH="linux64"
    ;;
  "arm64")
    NVARCH="sbsa"
    CONDA_ARCH="aarch64"
    ;;
  *)
    echo "Unsupported ARCH: ${ARCH}"
    exit 1
    ;;
esac

ARGS="
CUDA_VER: ${CUDA_VER}
LINUX_VER: ${LINUX_VER}
BASE_IMAGE: ${BASE_IMAGE}
PYTHON_VER: ${PYTHON_VER}
CPU_ARCH: ${ARCH}
REAL_ARCH: $(arch)
NVARCH: ${NVARCH}
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
