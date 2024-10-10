ARG CUDA_VER=notset
ARG LINUX_VER=notset

ARG BASE_IMAGE=nvcr.io/nvidia/cuda:${CUDA_VER}-devel-${LINUX_VER}
ARG AWS_CLI_VER=notset

FROM amazon/aws-cli:${AWS_CLI_VER} AS aws-cli

FROM ${BASE_IMAGE}

ARG CUDA_VER=notset
ARG LINUX_VER=notset
ARG PYTHON_VER=notset
ARG CPU_ARCH=notset

# Set RAPIDS versions env variables
ENV RAPIDS_CUDA_VERSION="${CUDA_VER}"
ENV RAPIDS_PY_VERSION="${PYTHON_VER}"

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
    apt-get install -y --no-install-recommends \
      wget curl git jq ssh \
      make build-essential libssl-dev zlib1g-dev \
      libbz2-dev libreadline-dev libsqlite3-dev wget \
      curl llvm libncursesw5-dev xz-utils tk-dev unzip \
      libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/*
    ;;
  "rockylinux"*)
    dnf update -y
    dnf install -y epel-release
    dnf update -y
    dnf install -y \
      which wget gcc zlib-devel bzip2 bzip2-devel readline-devel sqlite \
      sqlite-devel xz xz-devel libffi-devel curl git ncurses-devel \
      jq dnf-plugins-core
    dnf clean all
    pushd tmp
    wget https://www.openssl.org/source/openssl-1.1.1k.tar.gz
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
python -m pip install "rapids-dependency-file-generator==1.*"
pyenv rehash
EOF

RUN <<EOF
# Install OpenTelemetry instrumentation
pip install opentelemetry-distro[otlp] opentelemetry-exporter-prometheus
curl -L -o "otel-cli-${CPU_ARCH}.tar.gz" https://github.com/equinix-labs/otel-cli/releases/download/v0.4.5/otel-cli_0.4.5_linux_${CPU_ARCH}.tar.gz
tar -zxf  "otel-cli-${CPU_ARCH}.tar.gz"
mv otel-cli /usr/local/bin/
git clone -b add-conda-build-instrumentation https://github.com/msarahan/opentelemetry-python-contrib
pip install -e ./opentelemetry-python-contrib/instrumentation/opentelemetry-instrumentation-conda-build
opentelemetry-bootstrap -a install
EOF

# Install latest gha-tools
RUN wget https://github.com/rapidsai/gha-tools/releases/latest/download/tools.tar.gz -O - \
  | tar -xz -C /usr/local/bin

# git safe directory
RUN git config --system --add safe.directory '*'

# Add pip.conf
COPY pip.conf /etc/xdg/pip/pip.conf

CMD ["/bin/bash"]
