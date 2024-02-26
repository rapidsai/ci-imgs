#!/bin/bash
set -euo pipefail

if [ -z "$1" ]; then
  echo "Error: Path to Dockerfile is required as the first argument."
  exit 1
fi
DOCKERFILE_PATH="$1"

CUDA_VER="${CUDA_VER:-11.2.0}"
LINUX_VER="${LINUX_VER:-ubuntu20.04}"
PYTHON_VER="${PYTHON_VER:-3.8}"
ARCH="${ARCH:-x86_64}"
MANYLINUX_VER="${MANYLINUX_VER:-manylinux_2_28}"

YAML_FILE="renovate.yaml"

BUILD_ARGS=""

if [ -f "$YAML_FILE" ]; then
  while IFS= read -r line; do
    key=$(echo "$line" | cut -f1 -d':')
    value=$(echo "$line" | cut -f2 -d':')
    if [ -n "$GITHUB_ACTIONS" ]; then
      # Format the output for array appending (in ci/compute-build-args.sh)
      BUILD_ARGS+="$key=$value "
    else
      # Locally, format as Docker build arguments
      BUILD_ARGS+="--build-arg $key=$value "
    fi
  done < <(yq e '. | to_entries | .[] | .key + ":" + (.value | sub("^v"; ""))' "$YAML_FILE")
fi

if [ -n "$GITHUB_ACTIONS" ]; then
  echo "$BUILD_ARGS"
else
  eval "docker build -f \"$DOCKERFILE_PATH\" . \
    --build-arg CUDA_VER=\"$CUDA_VER\" \
    --build-arg LINUX_VER=\"$LINUX_VER\" \
    --build-arg PYTHON_VER=\"$PYTHON_VER\" \
    --build-arg CPU_ARCH=\"$ARCH\" \
    --build-arg REAL_ARCH=\"$(arch)\" \
    --build-arg MANYLINUX_VER=\"$MANYLINUX_VER\" \
    $BUILD_ARGS"
fi
