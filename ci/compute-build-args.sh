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

# compute upper bound, e.g. "3.11 -> 3.12.0a0"
PYTHON_VER_MAJOR="${PYTHON_VER%%.*}"
PYTHON_VER_MINOR="${PYTHON_VER#*.}"
PYTHON_VER_UPPER_BOUND="${PYTHON_VER_MAJOR}.$(( PYTHON_VER_MINOR + 1)).0a0"

ARGS="
CUDA_VER: ${CUDA_VER}
LINUX_VER: ${LINUX_VER}
PYTHON_VER: ${PYTHON_VER}
PYTHON_VER_UPPER_BOUND: ${PYTHON_VER_UPPER_BOUND}
CPU_ARCH: ${ARCH}
REAL_ARCH: $(arch)
MANYLINUX_VER: ${MANYLINUX_VER}
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
