#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

uv --version
python -m pip --version
rapids-pip-retry --version
rapids-dependency-file-generator --version

scratch_dir=$(mktemp -d)
trap 'rm -rf "${scratch_dir}"' EXIT
python - "${scratch_dir}" <<'PYTHON'
from pathlib import Path
import sys
import zipfile

with zipfile.ZipFile(Path(sys.argv[1]) / "rapids_uv_probe-1.0-py3-none-any.whl", "w") as wheel:
    wheel.writestr("rapids_uv_probe.py", "def main():\n    import sys\n    print(sys.executable)\n")
    metadata = "rapids_uv_probe-1.0.dist-info"
    wheel.writestr(f"{metadata}/METADATA", "Metadata-Version: 2.1\nName: rapids-uv-probe\nVersion: 1.0\n")
    wheel.writestr(f"{metadata}/WHEEL", "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n")
    wheel.writestr(f"{metadata}/entry_points.txt", "[console_scripts]\nrapids-uv-probe = rapids_uv_probe:main\n")
    wheel.writestr(f"{metadata}/RECORD", "")
PYTHON

selected_python=$(python -c 'import sys; print(sys.executable)')
# The container is disposable; installing into pyenv tests the real shim path.
uv pip install --python "${selected_python}" --no-cache --no-index \
    "${scratch_dir}/rapids_uv_probe-1.0-py3-none-any.whl"
pyenv rehash
hash -r
test "$(rapids-uv-probe)" = "${selected_python}"
test "$(pyenv which rapids-uv-probe)" = "$(dirname "${selected_python}")/rapids-uv-probe"

uv venv --python "${selected_python}" "${scratch_dir}/venv"
uv pip install --python "${scratch_dir}/venv/bin/python" --no-cache --no-index \
    "${scratch_dir}/rapids_uv_probe-1.0-py3-none-any.whl"
test "$("${scratch_dir}/venv/bin/rapids-uv-probe")" = "${scratch_dir}/venv/bin/python"
