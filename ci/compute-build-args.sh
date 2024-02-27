#!/bin/bash
set -euo pipefail

if [[ -z "${CUDA_VER}" || -z "${LINUX_VER}" || -z "${PYTHON_VER}" || -z "${ARCH}" ]]; then
  echo "Error: One or more required variables are not provided."
  exit 1
fi

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

YAML_FILE="versions.yaml"
if [ -f "$YAML_FILE" ]; then
  while IFS= read -r line; do
    key=$(echo "$line" | cut -f1 -d':')
    value=$(echo "$line" | cut -f2 -d':')
    ARGS+=("$key=${value}")
  done < <(yq e '. | to_entries | .[] | .key + ":" + (.value | sub("^v"; ""))' "$YAML_FILE")
fi

set +u
if [ -n "$GITHUB_ACTIONS" ]; then
cat <<EOF > "${GITHUB_OUTPUT:-/dev/stdout}"
ARGS<<EOT
$(printf "%s\n" "${ARGS[@]}")
EOT
EOF
else
  for arg in "${ARGS[@]}"; do
    printf -- "--build-arg %s " "$arg"
  done
fi
