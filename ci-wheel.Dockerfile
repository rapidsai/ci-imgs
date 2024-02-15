ARG CUDA_VER=notset
ARG LINUX_VER=notset

ARG BASE_IMAGE=nvcr.io/nvidia/cuda:${CUDA_VER}-devel-${LINUX_VER}
FROM ${BASE_IMAGE}

ARG CUDA_VER
ARG LINUX_VER
ARG CPU_ARCH
ARG REAL_ARCH
ARG PYTHON_VER
ARG MANYLINUX_VER
ARG POLICY=${MANYLINUX_VER}

ARG DEBIAN_FRONTEND=noninteractive

# Set RAPIDS versions env variables
ENV RAPIDS_CUDA_VERSION="${CUDA_VER}"
ENV RAPIDS_PY_VERSION="${PYTHON_VER}"

# RAPIDS pip index
ENV PIP_EXTRA_INDEX_URL="https://pypi.anaconda.org/rapidsai-wheels-nightly/simple"

ENV PYENV_ROOT="/pyenv"
ENV PATH="/pyenv/bin:/pyenv/shims:$PATH"

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    echo 'APT::Update::Error-Mode "any";' > /etc/apt/apt.conf.d/warnings-as-errors
    apt update -y
    apt install -y \
      debianutils build-essential software-properties-common \
      jq wget gcc zlib1g-dev libbz2-dev \
      libssl-dev libreadline-dev libsqlite3-dev libffi-dev curl git libncurses5-dev \
      libnuma-dev openssh-client libcudnn8-dev zip libopenblas-dev liblapack-dev \
      protobuf-compiler autoconf automake libtool cmake yasm libopenslide-dev
    add-apt-repository ppa:git-core/ppa
    add-apt-repository ppa:ubuntu-toolchain-r/test
    apt update -y
    apt install -y git gcc-9 g++-9
    add-apt-repository -r ppa:git-core/ppa
    add-apt-repository -r ppa:ubuntu-toolchain-r/test
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90 --slave /usr/bin/g++ g++ /usr/bin/g++-9 --slave /usr/bin/gcov gcov /usr/bin/gcov-9
    rm -rf /var/lib/apt/lists/*
    ;;
  "centos"*)
    yum update --exclude=libnccl* -y
    yum install -y epel-release
    yum update --exclude=libnccl* -y
    yum install -y \
      which wget gcc zlib-devel bzip2 bzip2-devel readline-devel sqlite \
      sqlite-devel xz xz-devel libffi-devel curl git ncurses-devel numactl \
      numactl-devel openssh-clients libcudnn8-devel zip blas-devel lapack-devel \
      protobuf-compiler autoconf automake libtool centos-release-scl scl-utils cmake \
      yasm openslide-devel
    yum remove -y git
    yum install -y https://packages.endpointdev.com/rhel/7/os/x86_64/endpoint-repo.x86_64.rpm
    yum install -y git jq devtoolset-11
    yum remove -y endpoint-repo
    yum clean all
    echo -e ' \
      #!/bin/bash\n \
      source scl_source enable devtoolset-11\n \
    ' > /etc/profile.d/enable_devtools.sh
    pushd tmp
    wget https://ftp.openssl.org/source/openssl-1.1.1k.tar.gz
    tar -xzvf openssl-1.1.1k.tar.gz
    cd openssl-1.1.1k
    ./config --prefix=/usr --openssldir=/etc/ssl --libdir=lib no-shared zlib-dynamic
    make
    make install
    popd
    ;;
  "rockylinux"*)
    dnf update -y
    dnf install -y epel-release
    dnf update -y
    dnf install -y \
      which wget gcc zlib-devel bzip2 bzip2-devel readline-devel sqlite \
      sqlite-devel xz xz-devel libffi-devel curl git ncurses-devel numactl \
      numactl-devel openssh-clients libcudnn8-devel zip jq openslide-devel \
      protobuf-compiler autoconf automake libtool dnf-plugins-core cmake
    dnf config-manager --set-enabled powertools
    dnf install -y blas-devel lapack-devel
    dnf -y install gcc-toolset-11-gcc gcc-toolset-11-gcc-c++
    dnf -y install yasm
    dnf clean all
    echo -e ' \
      #!/bin/bash\n \
      source /opt/rh/gcc-toolset-11/enable \
    ' > /etc/profile.d/enable_devtools.sh
    pushd tmp
    wget https://ftp.openssl.org/source/openssl-1.1.1k.tar.gz
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

# Download and install GH CLI tool v2.32.0
ARG GH_VERSION=2.32.0
RUN <<EOF
set -e
wget https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${CPU_ARCH}.tar.gz
tar -xf gh_*.tar.gz
mv gh_*/bin/gh /usr/local/bin
rm -rf gh_*
EOF

# Install sccache
ARG SCCACHE_VERSION=0.7.6

RUN <<EOF
curl -o /tmp/sccache.tar.gz \
  -L "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-"${REAL_ARCH}"-unknown-linux-musl.tar.gz"
tar -C /tmp -xvf /tmp/sccache.tar.gz
mv "/tmp/sccache-v${SCCACHE_VERSION}-"${REAL_ARCH}"-unknown-linux-musl/sccache" /usr/bin/sccache
chmod +x /usr/bin/sccache
EOF

# Set AUDITWHEEL_* env vars for use with auditwheel
ENV AUDITWHEEL_POLICY=${POLICY} AUDITWHEEL_ARCH=${REAL_ARCH} AUDITWHEEL_PLAT=${POLICY}_${REAL_ARCH}

# Set sccache env vars
ENV CMAKE_CUDA_COMPILER_LAUNCHER=sccache
ENV CMAKE_CXX_COMPILER_LAUNCHER=sccache
ENV CMAKE_C_COMPILER_LAUNCHER=sccache
ENV SCCACHE_BUCKET=rapids-sccache-east
ENV SCCACHE_REGION=us-east-2
ENV SCCACHE_IDLE_TIMEOUT=32768
ENV SCCACHE_S3_USE_SSL=true
ENV SCCACHE_S3_NO_CREDENTIALS=false

# Install ucx
ARG UCX=1.14.1
RUN <<EOF
mkdir -p /ucx-src
cd /ucx-src
git clone https://github.com/openucx/ucx -b v${UCX} ucx-git-repo
cd ucx-git-repo
./autogen.sh
./contrib/configure-release \
  --prefix=/usr               \
  --enable-mt                 \
  --enable-cma                \
  --enable-numa               \
  --with-gnu-ld               \
  --with-sysroot              \
  --without-verbs             \
  --without-rdmacm            \
  --with-cuda=/usr/local/cuda
CPPFLAGS=-I/usr/local/cuda/include make -j
make install
cd /
rm -rf /ucx-src/
EOF

# Install pyenv
RUN curl https://pyenv.run | bash

# Create pyenvs
# TODO: Determine if any cleanup of the pyenv layers is needed to shrink the container
RUN pyenv update

RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    pyenv install --verbose "${RAPIDS_PY_VERSION}"
    ;;
  "centos"*)
    # Need to specify the openssl location because of the install from source
    CPPFLAGS="-I/usr/include/openssl" LDFLAGS="-L/usr/lib" pyenv install --verbose "${RAPIDS_PY_VERSION}"
    ;;
  "rockylinux"*)
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
python -m pip install auditwheel patchelf twine rapids-dependency-file-generator dunamai
pyenv rehash
EOF

# Install latest gha-tools
RUN wget https://github.com/rapidsai/gha-tools/releases/latest/download/tools.tar.gz -O - | tar -xz -C /usr/local/bin

# Install anaconda-client
RUN <<EOF
pip install git+https://github.com/Anaconda-Platform/anaconda-client
pip cache purge
EOF

# Install the AWS CLI
COPY --from=amazon/aws-cli /usr/local/aws-cli/ /usr/local/aws-cli/
COPY --from=amazon/aws-cli /usr/local/bin/ /usr/local/bin/

# Mark all directories as safe for git so that GHA clones into the root don't
# run into issues
RUN git config --system --add safe.directory '*'

CMD ["/bin/bash"]
