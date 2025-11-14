# SPDX-FileCopyrightText: Copyright (c) 2023-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

ARG CUDA_VER=notset
ARG LINUX_VER=notset
ARG PYTHON_VER=notset
ARG MINIFORGE_VER=notset

FROM condaforge/miniforge3:${MINIFORGE_VER} AS miniforge-upstream
FROM nvidia/cuda:${CUDA_VER}-base-${LINUX_VER} AS miniforge-cuda

ARG CUDA_VER
ARG LINUX_VER
ARG PYTHON_VER
ARG DEBIAN_FRONTEND=noninteractive
ENV PATH=/opt/conda/bin:$PATH
ENV PYTHON_VERSION=${PYTHON_VER}

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

# Create a conda group and assign it as root's primary group
RUN <<EOF
groupadd conda
usermod -g conda root
EOF

# Ownership & permissions based on https://docs.anaconda.com/anaconda/install/multi-user/#multi-user-anaconda-installation-on-linux
COPY --from=miniforge-upstream --chown=root:conda --chmod=770 /opt/conda /opt/conda

# Ensure new files are created with group write access & setgid. See https://unix.stackexchange.com/a/12845
RUN chmod g+ws /opt/conda

# Copy in `mirrored_channels` to mimic upstream change in 25.9.1-0
COPY <<EOF /opt/conda/.condarc
channels:
  - conda-forge
mirrored_channels:
  conda-forge:
    - https://conda.anaconda.org/conda-forge
    - https://prefix.dev/conda-forge
EOF

RUN mamba install mamba=2.3.3

RUN <<EOF
# Ensure new files/dirs have group write permissions
umask 002

# Temporary workaround for unstable libxml2 packages
# xref: https://github.com/conda-forge/libxml2-feedstock/issues/145
echo 'libxml2<2.14.0' >> /opt/conda/conda-meta/pinned

# Temporary workaround for deadlocks in unpacking libcurl
# we hardcode this to match the versions in the upstream `miniforge3` image
echo 'libcurl==8.14.1' >> /opt/conda/conda-meta/pinned

# update everything before other environment changes, to ensure mixing
# an older conda with newer packages still works well
rapids-mamba-retry update --all -y -n base

# install expected Python version
PYTHON_MAJOR_VERSION=${PYTHON_VERSION%%.*}
PYTHON_MINOR_VERSION=${PYTHON_VERSION#*.}
PYTHON_UPPER_BOUND="${PYTHON_MAJOR_VERSION}.$((PYTHON_MINOR_VERSION+1)).0a0"
PYTHON_MINOR_PADDED=$(printf "%02d" "$PYTHON_MINOR_VERSION")
PYTHON_VERSION_PADDED="${PYTHON_MAJOR_VERSION}.${PYTHON_MINOR_PADDED}"
if [[ "$PYTHON_VERSION_PADDED" > "3.12" ]]; then
    PYTHON_ABI_TAG="cp${PYTHON_MAJOR_VERSION}${PYTHON_MINOR_VERSION}"
else
    PYTHON_ABI_TAG="cpython"
fi
rapids-mamba-retry install -y -n base "python>=${PYTHON_VERSION},<${PYTHON_UPPER_BOUND}=*_${PYTHON_ABI_TAG}"
rapids-mamba-retry update --all -y -n base
if [[ "$LINUX_VER" == "rockylinux"* ]]; then
  dnf install -y findutils
  dnf clean all
fi
find /opt/conda -follow -type f -name '*.a' -delete
find /opt/conda -follow -type f -name '*.pyc' -delete
# recreate missing libstdc++ symlinks
conda clean -aiptfy
EOF

# Reassign root's primary group to root
RUN usermod -g root root

RUN <<EOF
# ensure conda environment is always activated
ln -s /opt/conda/etc/profile.d/conda.sh /etc/profile.d/conda.sh
echo ". /opt/conda/etc/profile.d/conda.sh; conda activate base" >> /etc/skel/.bashrc
echo ". /opt/conda/etc/profile.d/conda.sh; conda activate base" >> ~/.bashrc
EOF

# tzdata is needed by the ORC library used by pyarrow, because it provides /etc/localtime
# On Ubuntu 24.04 and newer, we also need tzdata-legacy
RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2)
    if [[ "${os_version}" > "24.04" ]] || [[ "${os_version}" == "24.04" ]]; then
        tzdata_pkgs=(tzdata tzdata-legacy)
    else
        tzdata_pkgs=(tzdata)
    fi

    rapids-retry apt-get update -y
    apt-get upgrade -y
    apt-get install -y --no-install-recommends \
      "${tzdata_pkgs[@]}"

    rm -rf "/var/lib/apt/lists/*"
    ;;
  "rockylinux"*)
    dnf update -y
    dnf clean all
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}" && exit 1
    ;;
esac
EOF

FROM miniforge-cuda

ARG TARGETPLATFORM=notset
ARG CUDA_VER=notset
ARG LINUX_VER=notset
ARG PYTHON_VER=notset
ARG PYTHON_VER_UPPER_BOUND=notset
ARG CONDA_ARCH=notset

ARG DEBIAN_FRONTEND

# Set RAPIDS versions env variables
ENV RAPIDS_CUDA_VERSION="${CUDA_VER}"
ENV RAPIDS_PY_VERSION="${PYTHON_VER}"
ENV RAPIDS_DEPENDENCIES="latest"
ENV RAPIDS_CONDA_ARCH="${CONDA_ARCH}"

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Install system packages depending on the LINUX_VER
RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    rapids-retry apt-get update -y
    apt-get upgrade -y
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      file \
      unzip \
      wget \
      gcc \
      g++
    update-ca-certificates
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/*
    ;;
  "rockylinux"*)
    dnf -y update
    dnf -y install --setopt=install_weak_deps=False \
      ca-certificates \
      file \
      unzip \
      wget \
      which \
      yum-utils \
      gcc \
      gcc-c++
    update-ca-trust extract
    dnf clean all
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}"
    exit 1
    ;;
esac
EOF

# Install prereq for envsubst
RUN <<EOF
rapids-mamba-retry install -y \
  gettext
conda clean -aiptfy
EOF

# Create condarc file from env vars
ENV RAPIDS_CONDA_BLD_ROOT_DIR=/tmp/conda-bld-workspace
ENV RAPIDS_CONDA_BLD_OUTPUT_DIR=/tmp/conda-bld-output
COPY condarc.tmpl /tmp/condarc.tmpl
RUN cat /tmp/condarc.tmpl | envsubst | tee /opt/conda/.condarc; \
    rm -f /tmp/condarc.tmpl

# Install CI tools using mamba
RUN <<EOF
PYTHON_MAJOR_VERSION=${PYTHON_VERSION%%.*}
PYTHON_MINOR_VERSION=${PYTHON_VERSION#*.}
PYTHON_UPPER_BOUND="${PYTHON_MAJOR_VERSION}.$((PYTHON_MINOR_VERSION+1)).0a0"
PYTHON_MINOR_PADDED=$(printf "%02d" "$PYTHON_MINOR_VERSION")
PYTHON_VERSION_PADDED="${PYTHON_MAJOR_VERSION}.${PYTHON_MINOR_PADDED}"
if [[ "$PYTHON_VERSION_PADDED" > "3.12" ]]; then
    PYTHON_ABI_TAG="cp${PYTHON_MAJOR_VERSION}${PYTHON_MINOR_VERSION}"
else
    PYTHON_ABI_TAG="cpython"
fi

rapids-mamba-retry install -y \
  anaconda-client \
  ca-certificates \
  certifi \
  conda-build \
  conda-package-handling \
  dunamai \
  git \
  jq \
  packaging \
  "python>=${PYTHON_VERSION},<${PYTHON_UPPER_BOUND}=*_${PYTHON_ABI_TAG}" \
  "rapids-dependency-file-generator==1.*" \
  rattler-build \
;
conda clean -aiptfy
EOF

# Install sccache, gh cli, yq, and awscli
ARG SCCACHE_VER=notset
ARG REAL_ARCH=notset
ARG GH_CLI_VER=notset
ARG CPU_ARCH=notset
ARG YQ_VER=notset
ARG AWS_CLI_VER=notset
RUN <<EOF
rapids-retry curl -o /tmp/sccache.tar.gz \
  -L "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VER}/sccache-v${SCCACHE_VER}-"${REAL_ARCH}"-unknown-linux-musl.tar.gz"
tar -C /tmp -xvf /tmp/sccache.tar.gz
mv "/tmp/sccache-v${SCCACHE_VER}-"${REAL_ARCH}"-unknown-linux-musl/sccache" /usr/bin/sccache
chmod +x /usr/bin/sccache
rm -rf /tmp/sccache.tar.gz "/tmp/sccache-v${SCCACHE_VER}-"${REAL_ARCH}"-unknown-linux-musl"

rapids-retry wget -q https://github.com/cli/cli/releases/download/v${GH_CLI_VER}/gh_${GH_CLI_VER}_linux_${CPU_ARCH}.tar.gz
tar -xf gh_*.tar.gz
mv gh_*/bin/gh /usr/local/bin
rm -rf gh_*

rapids-retry wget -q https://github.com/mikefarah/yq/releases/download/v${YQ_VER}/yq_linux_${CPU_ARCH} -O /tmp/yq
mv /tmp/yq /usr/bin/yq
chmod +x /usr/bin/yq

# ref: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#getting-started-install-instructions
rapids-retry curl -o /tmp/awscliv2.zip \
  -L "https://awscli.amazonaws.com/awscli-exe-linux-${REAL_ARCH}-${AWS_CLI_VER}.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip
EOF

# Install codecov from source distribution
ARG CODECOV_VER=notset
RUN <<EOF
rapids-pip-retry install codecov-cli==${CODECOV_VER}
pip cache purge
EOF

RUN /opt/conda/bin/git config --system --add safe.directory '*'

# Add pip.conf
COPY pip.conf /etc/xdg/pip/pip.conf

CMD ["/bin/bash"]
