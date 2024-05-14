#!/bin/bash
set -euo pipefail

MANYLINUX_VER="manylinux_2_17"
if [[
  "${LINUX_VER}" == "ubuntu20.04"
]]; then
  MANYLINUX_VER="manylinux_2_31"
elif [[
  "${LINUX_VER}" == "rockylinux8"
]]; then
  MANYLINUX_VER="manylinux_2_28"
fi

ARGS="
CUDA_VER: ${CUDA_VER}
LINUX_VER: ${LINUX_VER}
PYTHON_VER: ${PYTHON_VER}
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
