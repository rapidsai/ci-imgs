#!/bin/bash
set -euo pipefail

MANYLINUX_VER="manylinux_2_17"
if [[
  "${LINUX_VER}" == "ubuntu18.04" ||
  "${LINUX_VER}" == "ubuntu20.04"
]]; then
  MANYLINUX_VER="manylinux_2_31"
elif [[
  "${LINUX_VER}" == "rockylinux8"
]]; then
  MANYLINUX_VER="manylinux_2_28"
fi

ARGS=(
  # common args
  "CUDA_VER=${CUDA_VER}"
  "LINUX_VER=${LINUX_VER}"
  "PYTHON_VER=${PYTHON_VER}"
  # wheel args
  "CPU_ARCH=${ARCH}"
  "REAL_ARCH=$(arch)"
  "MANYLINUX_VER=${MANYLINUX_VER}"
)

DYNAMIC_BUILD_ARGS=$(ci/fix-renovate-args.sh ${DOCKERFILE})
IFS=' ' read -r -a dynamic_args_array <<< "$DYNAMIC_BUILD_ARGS"
for arg in "${dynamic_args_array[@]}"; do
  ARGS+=("$arg")
done

cat <<EOF > "${GITHUB_OUTPUT:-/dev/stdout}"
ARGS<<EOT
$(printf "%s\n" "${ARGS[@]}")
EOT
EOF
