ARG CUDA_VER=notset
ARG LINUX_VER=notset

ARG BASE_IMAGE=nvcr.io/nvidia/cuda:${CUDA_VER}-devel-${LINUX_VER}
ARG AWS_CLI_VER=notset

FROM amazon/aws-cli:${AWS_CLI_VER} AS aws-cli

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

RUN <<EOF
set -e
case "${LINUX_VER}" in
  "ubuntu"*)
    echo 'APT::Update::Error-Mode "any";' > /etc/apt/apt.conf.d/warnings-as-errors
    apt-get update
    apt-get install -y software-properties-common
    # update git > 2.17
    add-apt-repository ppa:git-core/ppa -y
    apt-get update
    apt-get upgrade -y

    # tzdata is needed by the ORC library used by pyarrow, because it provides /etc/localtime
    # On Ubuntu 24.04 and newer, we also need tzdata-legacy
    os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2)
    if [[ "${os_version}" > "24.04" ]] || [[ "${os_version}" == "24.04" ]]; then
        tzdata_pkgs=(tzdata tzdata-legacy)
    else
        tzdata_pkgs=(tzdata)
    fi

    apt-get install -y --no-install-recommends \
      "${tzdata_pkgs[@]}" \
      build-essential \
      ca-certificates \
      curl \
      git \
      jq \
      libbz2-dev \
      libffi-dev \
      liblzma-dev \
      libncursesw5-dev \
      libreadline-dev \
      libsqlite3-dev \
      libssl-dev \
      libxml2-dev \
      libxmlsec1-dev \
      llvm \
      make \
      ssh \
      tk-dev \
      unzip \
      wget \
      xz-utils \
      zlib1g-dev
    update-ca-certificates
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/*
    ;;
  "rockylinux"*)
    dnf update -y
    dnf install -y epel-release
    dnf update -y
    dnf install -y \
      bzip2 \
      bzip2-devel \
      ca-certificates \
      curl \
      dnf-plugins-core \
      gcc \
      git \
      jq \
      libffi-devel \
      ncurses-devel \
      readline-devel \
      sqlite \
      sqlite-devel \
      wget \
      which \
      xz \
      xz-devel \
      zlib-devel
    update-ca-trust extract
    dnf clean all
    pushd tmp
    wget -q https://www.openssl.org/source/openssl-1.1.1k.tar.gz
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

# Download and install GH CLI tool
ARG GH_CLI_VER=notset
RUN <<EOF
set -e
wget -q https://github.com/cli/cli/releases/download/v${GH_CLI_VER}/gh_${GH_CLI_VER}_linux_${CPU_ARCH}.tar.gz
tar -xf gh_*.tar.gz
mv gh_*/bin/gh /usr/local/bin
rm -rf gh_*
EOF

# Install pyenv
RUN curl https://pyenv.run | bash

# Create pyenvs
RUN pyenv update && pyenv install ${PYTHON_VER}

RUN pyenv global ${PYTHON_VER} && python --version

# add bin to path
ENV PATH="/pyenv/versions/${PYTHON_VER}/bin/:$PATH"

# Install the AWS CLI
# Needed to download wheels for running tests
COPY --from=aws-cli /usr/local/aws-cli/ /usr/local/aws-cli/
COPY --from=aws-cli /usr/local/bin/ /usr/local/bin/

# update pip and install build tools
RUN <<EOF
pyenv global ${PYTHON_VER}
python -m pip install --upgrade pip
python -m pip install \
  certifi \
  'rapids-dependency-file-generator==1.*'
pyenv rehash
EOF

# Install latest gha-tools
RUN wget -q https://github.com/rapidsai/gha-tools/releases/latest/download/tools.tar.gz -O - \
  | tar -xz -C /usr/local/bin

# git safe directory
RUN git config --system --add safe.directory '*'

# Add pip.conf
COPY pip.conf /etc/xdg/pip/pip.conf

CMD ["/bin/bash"]
