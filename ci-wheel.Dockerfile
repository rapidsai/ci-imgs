# SPDX-FileCopyrightText: Copyright (c) 2023-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

ARG CUDA_VER=notset
ARG LINUX_VER=notset

ARG BASE_IMAGE=nvidia/cuda:${CUDA_VER}-devel-${LINUX_VER}

FROM ${BASE_IMAGE} AS os-base

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
ARG LINUX_VER=notset
RUN \
  --mount=type=bind,source=scripts,target=/tmp/build-scripts \
<<EOF
# configure package managers first (do this first because it affects installs in later scripts)
LINUX_VER=${LINUX_VER} \
  /tmp/build-scripts/configure-system-package-managers

# remove stuff that isn't necessary for wheel builds
PACKAGES_TO_REMOVE=(
  "cuda-compat-*"
  "cuda-gdb-*"
  "cuda-nsight-*"
  "nsight-*"
)
case "${LINUX_VER}" in
  "ubuntu"*)
    apt-get purge -y \
      "${PACKAGES_TO_REMOVE[@]}"
    apt-get autoremove -y
    ;;
  "rockylinux"*)
    dnf remove -y \
      "${PACKAGES_TO_REMOVE[@]}"
    dnf autoremove -y
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}"
    exit 1
    ;;
esac
EOF

# Install all the tools that are just "download a binary and stick it on PATH".
ARG AWS_CLI_VER=notset
ARG CPU_ARCH=notset
ARG GH_CLI_VER=notset
ARG REAL_ARCH=notset
ARG SCCACHE_VER=notset
RUN \
  --mount=type=secret,id=GH_TOKEN,env=GH_TOKEN \
  --mount=type=bind,source=scripts,target=/tmp/build-scripts \
<<EOF
# install AWS CLI, gh CLI, gha-tools, and sccache
#
# notes:
#   * AWS CLI is needed to work with artifacts on S3
AWS_CLI_VER=${AWS_CLI_VER} \
CPU_ARCH=${CPU_ARCH} \
GH_CLI_VER=${GH_CLI_VER} \
REAL_ARCH=${REAL_ARCH} \
SCCACHE_VER=${SCCACHE_VER} \
  /tmp/build-scripts/install-tools \
    --aws-cli \
    --gh-cli \
    --gha-tools \
    --sccache
EOF

# install other tools and libraries
RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    rapids-retry apt-get update -y
    PACKAGES_TO_INSTALL=(
      autoconf
      automake
      build-essential
      ca-certificates
      cmake
      curl
      debianutils
      gcc
      git
      jq
      libbz2-dev
      libcurl4-openssl-dev
      libffi-dev
      liblapack-dev
      libncurses5-dev
      libnuma-dev
      libopenblas-dev
      libopenslide-dev
      libreadline-dev
      libsqlite3-dev
      libssl-dev
      libtool
      libzstd-dev
      openssh-client
      patch
      protobuf-compiler
      software-properties-common
      unzip
      wget
      yasm
      zip
      zlib1g-dev
    )

    # only re-install NCCL if there wasn't one already installed in the image
    if ! apt list --installed | grep -E 'libnccl\-dev' 2>&1 >/dev/null; then
      echo "libnccl-dev not found, manually installing it"
      PACKAGES_TO_INSTALL+=(libnccl-dev)
    else
      echo "libnccl-dev already installed"
    fi

    apt-get install -y --no-install-recommends \
      "${PACKAGES_TO_INSTALL[@]}"

    update-ca-certificates
    add-apt-repository ppa:git-core/ppa
    add-apt-repository ppa:ubuntu-toolchain-r/test
    rapids-retry apt-get update -y
    apt-get install -y git gcc-9 g++-9
    add-apt-repository -r ppa:git-core/ppa
    add-apt-repository -r ppa:ubuntu-toolchain-r/test
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90 --slave /usr/bin/g++ g++ /usr/bin/g++-9 --slave /usr/bin/gcov gcov /usr/bin/gcov-9
    rm -rf \
      /var/cache/apt/archives \
      /var/lib/apt/lists/*
    ;;
  "rockylinux"*)
    dnf update -y
    dnf install --nodocs -y \
      dnf-plugins-core \
      epel-release
    dnf config-manager --set-enabled powertools
    dnf update -y
    PACKAGES_TO_INSTALL=(
      autoconf
      automake
      blas-devel
      bzip2
      bzip2-devel
      ca-certificates
      cmake
      curl
      gcc-toolset-14-gcc
      gcc-toolset-14-gcc-c++
      git
      jq
      lapack-devel
      libcurl-devel
      libffi-devel
      libtool
      ncurses-devel
      numactl
      numactl-devel
      openslide-devel
      openssh-clients
      patch
      protobuf-compiler
      readline-devel
      sqlite
      sqlite-devel
      unzip
      wget
      which
      xz
      xz-devel
      yasm
      zip
      zlib-devel
    )

    # only re-install NCCL if there wasn't one already installed in the image
    if ! rpm --query --all | grep -E 'libnccl\-devel' > /dev/null 2>&1; then
      echo "libnccl-devel not found, manually installing it"
      PACKAGES_TO_INSTALL+=(libnccl-devel)
    else
      echo "libnccl-devel already installed"
    fi

    dnf install --nodocs -y \
      "${PACKAGES_TO_INSTALL[@]}"
    update-ca-trust extract
    dnf clean all
    echo -e ' \
      #!/bin/bash\n \
      source /opt/rh/gcc-toolset-14/enable \
    ' > /etc/profile.d/enable_devtools.sh
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}"
    exit 1
    ;;
esac

# clean up docs and other unnecessary stuff
rm -rf \
  /usr/share/doc \
  /usr/share/info \
  /usr/share/man
EOF

RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
  ;;
  "rockylinux"*)
    pushd tmp
    rapids-retry wget -q https://www.openssl.org/source/openssl-1.1.1k.tar.gz
        tar -xzvf openssl-1.1.1k.tar.gz
    cd openssl-1.1.1k
    ./config --prefix=/usr --openssldir=/etc/ssl --libdir=lib no-shared zlib-dynamic
    # 'install_sw' installs just the libraries, headers, and binaries.
    # Plain 'install' also (slowly) generates and installs the HTML manpages, which we don't need.
    #
    # ref: https://github.com/openssl/openssl/blob/OpenSSL_1_1_1-stable/INSTALL
    #
    make -j"$(nproc)"
    make install_sw
    popd
    rm -rf /tmp/openssl*
    # Python 3.14 adds stdlib compression.zstd and requires libzstd >=1.4.5.
    # Rocky 8 packages libzstd 1.4.4, so provide a newer zstd before pyenv
    # builds Python. See https://github.com/pyenv/pyenv/wiki.
    ZSTD_VERSION=1.5.7
    pushd /tmp
    rapids-retry wget -q "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz"
    tar -xzvf "zstd-${ZSTD_VERSION}.tar.gz"
    cd "zstd-${ZSTD_VERSION}"
    make -j"$(nproc)" lib-release
    make -C lib install PREFIX=/usr LIBDIR=/usr/lib64
    ldconfig
    popd
    rm -rf /tmp/zstd*
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}"
    exit 1
    ;;
esac

# clean up docs and other unnecessary stuff
rm -rf \
  /usr/share/doc \
  /usr/share/info \
  /usr/share/man
EOF

# Set up Python
ARG PYTHON_VER=notset
ENV RAPIDS_WHEEL_BLD_OUTPUT_DIR=/tmp/wheelhouse
ENV PYENV_ROOT="/pyenv"
ENV PATH="${PYENV_ROOT}/bin:${PYENV_ROOT}/shims:${PATH}"
RUN \
  --mount=type=bind,source=scripts,target=/tmp/build-scripts \
<<EOF
# install pyenv
rapids-retry curl https://pyenv.run | bash

# explicitly parallelize builds run by pyenv's 'python-build' plugin.
#
# ref: https://github.com/pyenv/pyenv/blob/b52a8e3f52c3be68cf46c751ed40a180dfc48ba4/plugins/python-build/README.md?plain=1#L190
export MAKE_OPTS="-j$(nproc)"

# Skip building CPython's own test modules. RAPIDS CI builds and tests wheels,
# not CPython itself, so these just slow down the build.
export PYTHON_CONFIGURE_OPTS="--disable-test-modules"

case "${LINUX_VER}" in
  "ubuntu"*)
    pyenv install --verbose "${PYTHON_VER}"
    ;;
  "rockylinux"*)
    # Activate gcc-toolset so its toolchain is used when building CPython and other libraries
    # from source below.
    #
    # In some situations, CPython's ./configure may record an absolute path for
    # the compiler. Not ideal, but if that's going to happen we want it to be the one
    # used for building RAPIDS packages, because scikit-build-core retries that value
    # with `sysconfig.get_config_var("CXX")`.
    source /etc/profile.d/enable_devtools.sh

    # Need to specify the openssl location because of the install from source.
    CPPFLAGS="-I/usr/include/openssl" LDFLAGS="-L/usr/lib" pyenv install --verbose "${PYTHON_VER}"
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}"
    exit 1
    ;;
esac

pyenv global ${PYTHON_VER}
EOF

COPY pip.conf /etc/pip.conf
RUN \
  --mount=type=bind,source=scripts,target=/tmp/build-scripts \
<<EOF
# `rapids-pip-retry` defaults to using `python -m pip` to select which `pip` to
# use so should be compatible with `pyenv`
#
# >=25.3 floor is there to ensure we have a version that respects '--build-constraint'
rapids-pip-retry install --upgrade 'pip>=25.3'

PACKAGES_TO_INSTALL=(
  'abi3audit>=0.0.26'
  'auditwheel>=6.2.0'
  'build>=1.5.1'
  'certifi>=2026.1.4'
  'conda-package-handling>=2.4.0'
  'dunamai>=1.25.0'
  'patchelf>=0.17.2.4'
  'pydistcheck==0.11.*'
  'rapids-dependency-file-generator==1.*,>=1.22'
  'twine>=6.2.0'
  'wheel>=0.45.1'
)
rapids-pip-retry install \
  "${PACKAGES_TO_INSTALL[@]}"

pyenv rehash

# clear the pip cache
pip cache purge

# remove unnecessary pyenv stuff
/tmp/build-scripts/clean-pyenv

# Create output directory for wheel builds
mkdir -p ${RAPIDS_WHEEL_BLD_OUTPUT_DIR}

# Allow git to clone anywhere (these are images for isolated, short-lived CI containers,
# don't need to worry about this setting intended for long-lived / shared servers)
git config --system --add safe.directory '*'
EOF

# Re-organize image layers.
#
# This removes any overhead from changes (e.g. 'dnf update' changing package versions).
#
# trade-offs
# ----------
#
# 'docker pull' can pull layers in parallel (default: 3), so
# splitting into more layers allows for faster pull times via
# parallel pulls. (ref: https://docs.docker.com/reference/cli/dockerd/)
#
# Having more layers reduces the benefits from compression.
# An image split into 100 layers will require more data transfer
# than an identical image split into 10 layers.
#
FROM scratch AS output

# layers 1-3: split the largest CUDA libraries into their own layers
COPY --parents --from=os-base --exclude=usr/local/bin --exclude=usr/local/aws-cli \
     /usr/local/**/libcublas* \
     /
COPY --parents --from=os-base --exclude=usr/local/bin --exclude=usr/local/aws-cli \
     /usr/local/**/libcusparse* \
     /usr/local/**/libcusolver* \
     /
COPY --parents --from=os-base --exclude=usr/local/bin --exclude=usr/local/aws-cli \
     /usr/local/**/libcufft* \
     /usr/local/**/libcurand* \
     /usr/local/**/libnpp* \
     /

# layer 4: remaining CUDA and other misc. stuff
COPY --from=os-base --exclude=bin --exclude=aws-cli /usr/local /usr/local

# layers 5-6: other things in /usr/local (later because it's faster-changing)
COPY --from=os-base /usr/local/bin /usr/local/bin
COPY --from=os-base /usr/local/aws-cli /usr/local/aws-cli

# layer 7: shared libraries
COPY --from=os-base /usr/lib64 /usr/lib64

# layer 8: more shared libraries
COPY --from=os-base /usr/lib /usr/lib

# layer 9: Python
COPY --from=os-base /pyenv /pyenv

# layer 10: tools
COPY --from=os-base /usr/bin /usr/bin

# layer 11: more tools
COPY --from=os-base /opt /opt

# layer 12: everything else
COPY --from=os-base       \
     --exclude=usr/local \
     --exclude=usr/lib64 \
     --exclude=usr/lib   \
     --exclude=pyenv     \
     --exclude=usr/bin   \
     --exclude=opt       \
     / /

# BEGIN base-image ENV (generated by ci/sync-base-env.sh, do not edit)
# END base-image ENV

# set output env variables

# RAPIDS_* env vars
ARG CONDA_ARCH=notset
ARG CUDA_VER=notset
ARG PYTHON_VER=notset
ENV RAPIDS_CONDA_ARCH="${CONDA_ARCH}"           \
    RAPIDS_CUDA_VERSION="${CUDA_VER}"           \
    RAPIDS_DEPENDENCIES="latest"                \
    RAPIDS_PY_VERSION="${PYTHON_VER}"           \
    RAPIDS_WHEEL_BLD_OUTPUT_DIR=/tmp/wheelhouse

# other output env vars
ARG MANYLINUX_VER=notset
ARG POLICY=${MANYLINUX_VER}
ARG REAL_ARCH=notset
ENV PYENV_ROOT="/pyenv"                      \
    AUDITWHEEL_POLICY="${POLICY}"            \
    AUDITWHEEL_ARCH="${REAL_ARCH}"           \
    AUDITWHEEL_PLAT="${POLICY}_${REAL_ARCH}"

ENV PATH="${PYENV_ROOT}/bin:${PYENV_ROOT}/shims:${PATH}"

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

CMD ["/bin/bash"]
