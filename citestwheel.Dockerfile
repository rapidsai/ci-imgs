ARG CUDA_VER=notset
ARG LINUX_VER=notset

ARG BASE_IMAGE=nvcr.io/nvidia/cuda:${CUDA_VER}-devel-${LINUX_VER}
ARG AWS_CLI_VER

FROM amazon/aws-cli:${AWS_CLI_VER} as aws-cli

FROM ${BASE_IMAGE}

ARG CUDA_VER
ARG PYTHON_VER

# Set RAPIDS versions env variables
ENV RAPIDS_CUDA_VERSION="${CUDA_VER}"
ENV RAPIDS_PY_VERSION="${PYTHON_VER}"

# RAPIDS pip index
ENV PIP_EXTRA_INDEX_URL="https://pypi.anaconda.org/rapidsai-wheels-nightly/simple"

ARG DEBIAN_FRONTEND=noninteractive

ENV PYENV_ROOT="/pyenv"
ENV PATH="/pyenv/bin:/pyenv/shims:$PATH"

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN <<EOF
set -e
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

# Install latest gha-tools
RUN wget https://github.com/rapidsai/gha-tools/releases/latest/download/tools.tar.gz -O - \
  | tar -xz -C /usr/local/bin

# git safe directory
RUN git config --system --add safe.directory '*'

CMD ["/bin/bash"]
