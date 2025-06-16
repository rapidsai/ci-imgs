# Copyright (c) 2023-2025, NVIDIA CORPORATION.

ARG CUDA_VER=notset
ARG LINUX_VER=notset

ARG BASE_IMAGE=nvidia/cuda:${CUDA_VER}-devel-${LINUX_VER}
ARG AWS_CLI_VER=notset

FROM amazon/aws-cli:${AWS_CLI_VER} AS aws-cli

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

# Install bundled `rapids-retry`
COPY rapids-retry /usr/local/bin

RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    echo 'APT::Update::Error-Mode "any";' > /etc/apt/apt.conf.d/warnings-as-errors
    rapids-retry apt update -y
    rapids-retry apt install -y \
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
      wget \
      yasm \
      zip \
      zlib1g-dev
    update-ca-certificates
    rapids-retry add-apt-repository ppa:git-core/ppa
    rapids-retry add-apt-repository ppa:ubuntu-toolchain-r/test
    rapids-retry apt update -y
    rapids-retry apt install -y git gcc-9 g++-9
    rapids-retry add-apt-repository -r ppa:git-core/ppa
    rapids-retry add-apt-repository -r ppa:ubuntu-toolchain-r/test
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90 --slave /usr/bin/g++ g++ /usr/bin/g++-9 --slave /usr/bin/gcov gcov /usr/bin/gcov-9
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/*
    ;;
  "rockylinux"*)
    rapids-retry dnf update -y
    rapids-retry dnf install -y epel-release
    rapids-retry dnf update -y
    rapids-retry dnf install -y \
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
      wget \
      which \
      xz \
      xz-devel \
      zip \
      zlib-devel
    update-ca-trust extract
    dnf config-manager --set-enabled powertools
    rapids-retry dnf install -y blas-devel lapack-devel
    rapids-retry dnf -y install gcc-toolset-11-gcc gcc-toolset-11-gcc-c++
    rapids-retry dnf -y install yasm
    dnf clean all
    echo -e ' \
      #!/bin/bash\n \
      source /opt/rh/gcc-toolset-11/enable \
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

# Install latest gha-tools (after removing bundled `rapids-retry`)
RUN rm /usr/local/bin/rapids-retry && wget -q https://github.com/rapidsai/gha-tools/releases/latest/download/tools.tar.gz -O - | tar -xz -C /usr/local/bin

# Download and install GH CLI tool
ARG GH_CLI_VER=notset
RUN <<EOF
set -e
rapids-retry wget -q https://github.com/cli/cli/releases/download/v${GH_CLI_VER}/gh_${GH_CLI_VER}_linux_${CPU_ARCH}.tar.gz
tar -xf gh_*.tar.gz
mv gh_*/bin/gh /usr/local/bin
rm -rf gh_*
EOF

# Install sccache
ARG SCCACHE_VER=notset

RUN <<EOF
rapids-retry curl -o /tmp/sccache.tar.gz \
  -L "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VER}/sccache-v${SCCACHE_VER}-"${REAL_ARCH}"-unknown-linux-musl.tar.gz"
tar -C /tmp -xvf /tmp/sccache.tar.gz
mv "/tmp/sccache-v${SCCACHE_VER}-"${REAL_ARCH}"-unknown-linux-musl/sccache" /usr/bin/sccache
chmod +x /usr/bin/sccache
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
  'auditwheel>=6.2.0' \
  certifi \
  conda-package-handling \
  dunamai \
  patchelf \
  'pydistcheck==0.9.*' \
  'rapids-dependency-file-generator==1.*' \
  twine \
  wheel
pyenv rehash
EOF

# Install anaconda-client
RUN <<EOF
rapids-pip-retry install git+https://github.com/Anaconda-Platform/anaconda-client
pip cache purge
EOF

# Install the AWS CLI
COPY --from=aws-cli /usr/local/aws-cli/ /usr/local/aws-cli/
COPY --from=aws-cli /usr/local/bin/ /usr/local/bin/

# Create output directory for wheel builds
RUN mkdir -p ${RAPIDS_WHEEL_BLD_OUTPUT_DIR}

# Mark all directories as safe for git so that GHA clones into the root don't
# run into issues
RUN git config --system --add safe.directory '*'

# Add pip.conf
COPY pip.conf /etc/xdg/pip/pip.conf

CMD ["/bin/bash"]
