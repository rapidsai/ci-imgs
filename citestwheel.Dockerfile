# SPDX-FileCopyrightText: Copyright (c) 2023-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

ARG CUDA_VER=notset
ARG LINUX_VER=notset

ARG BASE_IMAGE=nvidia/cuda:${CUDA_VER}-devel-${LINUX_VER}

FROM ${BASE_IMAGE}

ARG CUDA_VER=notset
ARG LINUX_VER=notset
ARG CPU_ARCH=notset
ARG PYTHON_VER=notset
ARG CONDA_ARCH=notset

# Set RAPIDS versions env variables
ENV RAPIDS_CUDA_VERSION="${CUDA_VER}"
ENV RAPIDS_PY_VERSION="${PYTHON_VER}"
ENV RAPIDS_DEPENDENCIES="latest"
ENV RAPIDS_CONDA_ARCH="${CONDA_ARCH}"

ARG DEBIAN_FRONTEND=noninteractive

ENV PYENV_ROOT="/pyenv"
ENV PATH="/pyenv/bin:/pyenv/shims:$PATH"

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Set apt policy configurations
# We bump up the number of retries and the timeouts for `apt`
# Note that `dnf` defaults to 10 retries, so no additional configuration is required here
RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    echo 'APT::Update::Error-Mode "any";' > /etc/apt/apt.conf.d/warnings-as-errors
    echo 'APT::Acquire::Retries "10";' > /etc/apt/apt.conf.d/retries
    echo 'APT::Acquire::https::Timeout "240";' > /etc/apt/apt.conf.d/https-timeout
    echo 'APT::Acquire::http::Timeout "240";' > /etc/apt/apt.conf.d/http-timeout
    ;;
esac
EOF

# Install latest gha-tools
RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    i=0; until apt-get update -y; do ((++i >= 5)) && break; sleep 10; done
    apt-get install -y --no-install-recommends wget
    wget -q https://github.com/rapidsai/gha-tools/releases/latest/download/tools.tar.gz -O - | tar -xz -C /usr/local/bin
    apt-get purge -y wget && apt-get autoremove -y
    rm -rf /var/lib/apt/lists/*
    ;;
  "rockylinux"*)
    dnf install -y wget
    wget -q https://github.com/rapidsai/gha-tools/releases/latest/download/tools.tar.gz -O - | tar -xz -C /usr/local/bin
    dnf remove -y wget
    dnf clean all
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}"
    exit 1
    ;;
esac
EOF

RUN <<EOF
set -e
case "${LINUX_VER}" in
  "ubuntu"*)
    rapids-retry apt-get update -y
    apt-get install -y software-properties-common
    # update git > 2.17
    add-apt-repository ppa:git-core/ppa -y
    rapids-retry apt-get update -y
    apt-get upgrade -y

    PACKAGES_TO_INSTALL=(
      build-essential
      ca-certificates
      curl
      git
      jq
      libbz2-dev
      libffi-dev
      liblzma-dev
      libncursesw5-dev
      libnuma1
      libreadline-dev
      libsqlite3-dev
      libssl-dev
      libxml2-dev
      libxmlsec1-dev
      llvm
      make
      patch
      ssh
      tk-dev
      tzdata
      unzip
      wget
      xz-utils
      zlib1g-dev
    )

    # tzdata is needed by the ORC library used by pyarrow, because it provides /etc/localtime
    # On Ubuntu 24.04 and newer, we also need tzdata-legacy
    os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2)
    if [[ "${os_version}" > "24.04" ]] || [[ "${os_version}" == "24.04" ]]; then
        PACKAGES_TO_INSTALL+=(tzdata-legacy)
    fi

    apt-get install -y --no-install-recommends \
      "${PACKAGES_TO_INSTALL[@]}" \

    update-ca-certificates

    rm -rf /var/cache/apt/archives /var/lib/apt/lists/*
    ;;
  "rockylinux"*)
    dnf update -y
    dnf install -y epel-release
    dnf update -y
    PACKAGES_TO_INSTALL=(
      bzip2
      bzip2-devel
      ca-certificates
      curl
      dnf-plugins-core
      gcc
      git
      jq
      libffi-devel
      patch
      ncurses-devel
      readline-devel
      sqlite
      sqlite-devel
      unzip
      wget
      which
      xz
      xz-devel
      zlib-devel
    )
    dnf install -y \
      "${PACKAGES_TO_INSTALL[@]}"

    update-ca-trust extract
    dnf clean all
    pushd tmp
    rapids-retry wget -q https://www.openssl.org/source/openssl-1.1.1k.tar.gz
        tar -xzvf openssl-1.1.1k.tar.gz
    cd openssl-1.1.1k
    ./config --prefix=/usr --openssldir=/etc/ssl --libdir=lib no-shared zlib-dynamic
    make
    make install
    popd
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}"
    exit 1
    ;;
esac
EOF

# Download and install gh CLI tool
ARG GH_CLI_VER=notset
RUN <<EOF
set -e
rapids-retry wget -q https://github.com/cli/cli/releases/download/v${GH_CLI_VER}/gh_${GH_CLI_VER}_linux_${CPU_ARCH}.tar.gz
tar -xf gh_*.tar.gz
mv gh_*/bin/gh /usr/local/bin
rm -rf gh_*
EOF

# Download and install awscli
ARG AWS_CLI_VER=notset
ARG REAL_ARCH=notset
RUN <<EOF
# ref: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#getting-started-install-instructions
rapids-retry curl -o /tmp/awscliv2.zip \
  -L "https://awscli.amazonaws.com/awscli-exe-linux-${REAL_ARCH}-${AWS_CLI_VER}.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip
EOF

# Install pyenv
RUN rapids-retry curl https://pyenv.run | bash

# Create pyenvs
RUN <<EOF
  pyenv install ${PYTHON_VER}
  pyenv global ${PYTHON_VER}
  python --version
EOF

# add bin to path
ENV PATH="/pyenv/versions/${PYTHON_VER}/bin/:$PATH"

# update pip and install build tools
RUN <<EOF
pyenv global ${PYTHON_VER}
# `rapids-pip-retry` defaults to using `python -m pip` to select which `pip` to
# use so should be compatible with `pyenv`
rapids-pip-retry install --upgrade pip
rapids-pip-retry install \
  'certifi>=2026.1.4' \
  'rapids-dependency-file-generator==1.*'
pyenv rehash
EOF

# git safe directory
RUN git config --system --add safe.directory '*'

# Add pip.conf
COPY pip.conf /etc/xdg/pip/pip.conf

CMD ["/bin/bash"]
