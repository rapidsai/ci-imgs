#!/bin/bash
set -euo pipefail

ARGS=""
case "${IMAGE_REPO}" in
  ci)
    ARGS="CUDA_VER=\"${CUDA_VER}\"
LINUX_VER=\"${LINUX_VER}\"
PYTHON_VER=\"${PYTHON_VER}\""
    ;;
  *)
    MANYLINUX_VER="manylinux_2_17"
    if [[
        "${LINUX_VER}" == "ubuntu18.04" ||
        "${LINUX_VER}" == "ubuntu20.04"
    ]]; then
        MANYLINUX_VER="manylinux_2_31"
    fi
    ARGS="CUDA_VER=\"${CUDA_VER}\"
LINUX_VER=\"${LINUX_VER}\"
PYTHON_VER=\"${PYTHON_VER}\"
CPU_ARCH=\"${ARCH}\"
REAL_ARCH=$(arch)
MANYLINUX_VER=\"${MANYLINUX_VER}\""
    ;;
esac

echo "ARGS=${ARGS}" >> "$GITHUB_OUTPUT"
