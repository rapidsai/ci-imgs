#!/usr/bin/env bash

set -eoxu pipefail

export RAPIDS_PY_WHEEL_NAME="${RAPIDS_PY_WHEEL_NAME:-}"
export RAPIDS_PY_VERSION="${RAPIDS_PY_VERSION:-}"
export CIBW_TEST_EXTRAS="${CIBW_TEST_EXTRAS:-}"
export CIBW_TEST_COMMAND="${CIBW_TEST_COMMAND:-}"
export RAPIDS_BEFORE_TEST_COMMANDS_AMD64="${RAPIDS_BEFORE_TEST_COMMANDS_AMD64:-}"
export RAPIDS_BEFORE_TEST_COMMANDS_ARM64="${RAPIDS_BEFORE_TEST_COMMANDS_ARM64:-}"
export PIP_EXTRA_INDEX_URL="${PIP_EXTRA_INDEX_URL:-}"

mkdir -p ./dist

arch=$(uname -m)

# need this to init pyenv first
eval "$(pyenv init -)"

# use pyenv to set appropriate python as default before citestwheel
pyenv global "${RAPIDS_PY_VERSION}" && python --version

rapids-download-wheels-from-s3 ./dist

if [ "${arch}" == "x86_64" ]; then
        sh -c "${RAPIDS_BEFORE_TEST_COMMANDS_AMD64}"
elif [ "${arch}" == "aarch64" ]; then
        sh -c "${RAPIDS_BEFORE_TEST_COMMANDS_ARM64}"
fi

# see: https://cibuildwheel.readthedocs.io/en/stable/options/#test-extras
extra_requires_suffix=''
if [ "${CIBW_TEST_EXTRAS}" != "" ]; then
        extra_requires_suffix="[${CIBW_TEST_EXTRAS}]"
fi

# echo to expand wildcard before adding `[extra]` requires for pip
python -m pip install --verbose $(echo ./dist/${RAPIDS_PY_WHEEL_NAME}*.whl)$extra_requires_suffix

python -m pip check

sh -c "${CIBW_TEST_COMMAND}"
