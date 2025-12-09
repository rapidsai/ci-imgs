# SPDX-FileCopyrightText: Copyright (c) 2023-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

ARG CUDA_VER=notset
ARG LINUX_VER=notset

ARG BASE_IMAGE=nvidia/cuda:${CUDA_VER}-devel-${LINUX_VER}

FROM ${BASE_IMAGE}

ARG CUDA_VER=notset
ARG LINUX_VER=notset
ARG CPU_ARCH=notset
ARG REAL_ARCH=notset
ARG PYTHON_VER=notset
ARG MANYLINUX_VER=notset
ARG POLICY=${MANYLINUX_VER}
ARG CONDA_ARCH=notset

ARG DEBIAN_FRONTEND=noninteractive

# Set RAPIDS versions env variables
ENV RAPIDS_CUDA_VERSION="${CUDA_VER}"
ENV RAPIDS_PY_VERSION="${PYTHON_VER}"
ENV RAPIDS_DEPENDENCIES="latest"
ENV RAPIDS_CONDA_ARCH="${CONDA_ARCH}"
ENV RAPIDS_WHEEL_BLD_OUTPUT_DIR=/tmp/wheelhouse

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
ARG SCCACHE_VER=notset
RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    i=0; until apt-get update -y; do ((++i >= 5)) && break; sleep 10; done
    apt-get install -y --no-install-recommends wget
    wget -q https://github.com/rapidsai/gha-tools/releases/latest/download/tools.tar.gz -O - | tar -xz -C /usr/local/bin
    SCCACHE_VERSION="${SCCACHE_VER}" rapids-install-sccache
    apt-get purge -y wget && apt-get autoremove -y
    rm -rf /var/lib/apt/lists/*
    ;;
  "rockylinux"*)
    dnf install -y wget
    wget -q https://github.com/rapidsai/gha-tools/releases/latest/download/tools.tar.gz -O - | tar -xz -C /usr/local/bin
    SCCACHE_VERSION="${SCCACHE_VER}" rapids-install-sccache
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
case "${LINUX_VER}" in
  "ubuntu"*)
    rapids-retry apt-get update -y
    apt-get install -y \
      autoconf \
      automake \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      debianutils \
      gcc \
      git \
      jq \
      libbz2-dev \
      libcudnn8-dev \
      libcurl4-openssl-dev \
      libffi-dev \
      liblapack-dev \
      libncurses5-dev \
      libnuma-dev \
      libopenblas-dev \
      libopenslide-dev \
      libreadline-dev \
      libsqlite3-dev \
      libssl-dev \
      libtool \
      openssh-client \
      protobuf-compiler \
      software-properties-common \
      unzip \
      wget \
      yasm \
      zip \
      zlib1g-dev
    update-ca-certificates
    add-apt-repository ppa:git-core/ppa
    add-apt-repository ppa:ubuntu-toolchain-r/test
    rapids-retry apt-get update -y
    apt-get install -y git gcc-9 g++-9
    add-apt-repository -r ppa:git-core/ppa
    add-apt-repository -r ppa:ubuntu-toolchain-r/test
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90 --slave /usr/bin/g++ g++ /usr/bin/g++-9 --slave /usr/bin/gcov gcov /usr/bin/gcov-9
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/*
    ;;
  "rockylinux"*)
    dnf update -y
    dnf install -y epel-release
    dnf update -y
    dnf install -y \
      autoconf \
      automake \
      bzip2 \
      bzip2-devel \
      ca-certificates \
      cmake \
      curl \
      dnf-plugins-core \
      gcc \
      git \
      jq \
      libcudnn8-devel \
      libcurl-devel \
      libffi-devel \
      libtool \
      ncurses-devel \
      numactl \
      numactl-devel \
      openslide-devel \
      openssh-clients \
      protobuf-compiler \
      readline-devel \
      sqlite \
      sqlite-devel \
      unzip \
      wget \
      which \
      xz \
      xz-devel \
      zip \
      zlib-devel
    update-ca-trust extract
    dnf config-manager --set-enabled powertools
    dnf install -y blas-devel lapack-devel
    dnf -y install gcc-toolset-14-gcc gcc-toolset-14-gcc-c++
    dnf -y install yasm
    dnf clean all
    echo -e ' \
      #!/bin/bash\n \
      source /opt/rh/gcc-toolset-14/enable \
    ' > /etc/profile.d/enable_devtools.sh
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
# Needed to download wheels for running tests
ARG AWS_CLI_VER=notset
RUN <<EOF
# ref: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#getting-started-install-instructions
rapids-retry curl -o /tmp/awscliv2.zip \
  -L "https://awscli.amazonaws.com/awscli-exe-linux-${REAL_ARCH}-${AWS_CLI_VER}.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip
EOF

# Set AUDITWHEEL_* env vars for use with auditwheel
ENV AUDITWHEEL_POLICY=${POLICY} AUDITWHEEL_ARCH=${REAL_ARCH} AUDITWHEEL_PLAT=${POLICY}_${REAL_ARCH}

# Install pyenv
RUN rapids-retry curl https://pyenv.run | bash

RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    pyenv install --verbose "${RAPIDS_PY_VERSION}"
    ;;
  "rockylinux"*)
    # Need to specify the openssl location because of the install from source
    CPPFLAGS="-I/usr/include/openssl" LDFLAGS="-L/usr/lib" pyenv install --verbose "${RAPIDS_PY_VERSION}"
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}"
    exit 1
    ;;
esac
EOF

RUN <<EOF
pyenv global ${PYTHON_VER}
# `rapids-pip-retry` defaults to using `python -m pip` to select which `pip` to
# use so should be compatible with `pyenv`
rapids-pip-retry install --upgrade pip
rapids-pip-retry install \
  'anaconda-client>=1.13.0' \
  'auditwheel>=6.2.0' \
  certifi \
  conda-package-handling \
  dunamai \
  patchelf \
  'pydistcheck==0.9.*' \
  'rapids-dependency-file-generator==1.*' \
  twine \
  wheel
pip cache purge
pyenv rehash
EOF

# Create output directory for wheel builds
RUN mkdir -p ${RAPIDS_WHEEL_BLD_OUTPUT_DIR}

# Mark all directories as safe for git so that GHA clones into the root don't
# run into issues
RUN git config --system --add safe.directory '*'

# Add pip.conf
COPY pip.conf /etc/xdg/pip/pip.conf

CMD ["/bin/bash"]
