# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Check effective APT acquire settings with Ubuntu's actual parser."""

import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.skipif(
    os.environ.get("RAPIDS_TEST_APT_CONFIG") != "1",
    reason="opt-in real Ubuntu APT configuration probe",
)
@pytest.mark.parametrize("version", ["22.04", "24.04"])
def test_ubuntu_apt_reads_retries_and_transport_timeouts(version):
    result = subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "--network=none",
            "--env",
            f"LINUX_VER=ubuntu{version}",
            "--mount",
            (
                "type=bind,source="
                f"{ROOT / 'context/scripts/configure-system-package-managers'},"
                "target=/configure-package-managers,readonly"
            ),
            f"ubuntu:{version}",
            "bash",
            "-euc",
            (
                "bash /configure-package-managers; "
                "apt-config shell RETRIES Acquire::Retries "
                "HTTP_TIMEOUT Acquire::http::Timeout "
                "HTTPS_TIMEOUT Acquire::https::Timeout "
                "UPDATE_ERROR_MODE APT::Update::Error-Mode"
            ),
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.splitlines() == [
        "RETRIES='10'",
        "HTTP_TIMEOUT='240'",
        "HTTPS_TIMEOUT='240'",
        "UPDATE_ERROR_MODE='any'",
    ]
