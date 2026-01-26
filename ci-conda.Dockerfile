# SPDX-FileCopyrightText: Copyright (c) 2023-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

################################ build and update miniforge-upstream ###############################

ARG CUDA_VER=notset
ARG LINUX_VER=notset
ARG MINIFORGE_VER=notset

FROM condaforge/miniforge3:${MINIFORGE_VER} AS miniforge-upstream

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG LINUX_VER=notset
RUN \
  --mount=type=bind,source=scripts,target=/tmp/build-scripts \
<<EOF
# Ensure new files/dirs have group write permissions
umask 002

# install gha-tools for rapids-mamba-retry
LINUX_VER=${LINUX_VER} \
  /tmp/build-scripts/install-tools \
    --gha-tools

# Example of pinned package in case you require an override
# echo '<PACKAGE_NAME>==<VERSION>' >> /opt/conda/conda-meta/pinned

# update everything before other environment changes, to ensure mixing
# an older conda with newer packages still works well
#
# NOTE: 'PATH' is set locally here (instead of 'ENV') because this target is just an intermediate
#       build that files are copied out of.
PATH="/opt/conda/bin:$PATH" \
  rapids-mamba-retry update --all -y -n base
EOF

FROM nvidia/cuda:${CUDA_VER}-base-${LINUX_VER} AS ci-conda

ARG CONDA_ARCH=notset
ARG CUDA_VER=notset
ARG DEBIAN_FRONTEND=noninteractive
ARG PYTHON_VER=notset
ARG PYTHON_VER_UPPER_BOUND=notset

ENV PATH=/opt/conda/bin:$PATH
ENV PYTHON_VERSION=${PYTHON_VER}

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Install all the tools that are just "download a binary and stick it on PATH".
#
# These can be together, and earlier, because they're very cache-friendly... the versions are
# pinned so the layer content shouldn't change.
#
# And safe here because they're unaffected by conda or conda packages.
ARG AWS_CLI_VER=notset
ARG CPU_ARCH=notset
ARG LINUX_VER=notset
ARG GH_CLI_VER=notset
ARG REAL_ARCH=notset
ARG SCCACHE_VER=notset
ARG YQ_VER=notset
RUN \
  --mount=type=secret,id=GH_TOKEN,env=GH_TOKEN \
  --mount=type=bind,source=scripts,target=/tmp/build-scripts \
<<EOF
# configure apt (do this first because it affects installs in later scripts)
LINUX_VER=${LINUX_VER} \
  /tmp/build-scripts/configure-apt

# install AWS CLI, gh CLI, gha-tools, sccache, and yq
AWS_CLI_VER=${AWS_CLI_VER} \
CPU_ARCH=${CPU_ARCH} \
GH_CLI_VER=${GH_CLI_VER} \
LINUX_VER=${LINUX_VER} \
REAL_ARCH=${REAL_ARCH} \
SCCACHE_VER=${SCCACHE_VER} \
YQ_VER=${YQ_VER} \
  /tmp/build-scripts/install-tools \
    --aws-cli \
    --gh-cli \
    --gha-tools \
    --sccache \
    --yq

# Create a conda group and assign it as root's primary group
groupadd conda
usermod -g conda root
EOF

# Ownership & permissions based on https://docs.anaconda.com/anaconda/install/multi-user/#multi-user-anaconda-installation-on-linux
COPY --from=miniforge-upstream --chown=root:conda --chmod=770 /opt/conda /opt/conda

RUN <<EOF
# Ensure new files are created with group write access & setgid. See https://unix.stackexchange.com/a/12845
chmod g+ws /opt/conda

# Ensure new files/dirs have group write permissions
umask 002

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

# Reassign root's primary group to root
usermod -g root root

# ensure conda environment is always activated
ln -s /opt/conda/etc/profile.d/conda.sh /etc/profile.d/conda.sh
echo ". /opt/conda/etc/profile.d/conda.sh; conda activate base" >> /etc/skel/.bashrc
echo ". /opt/conda/etc/profile.d/conda.sh; conda activate base" >> ~/.bashrc
EOF

# Set RAPIDS versions env variables
ENV RAPIDS_CONDA_ARCH="${CONDA_ARCH}"
ENV RAPIDS_CUDA_VERSION="${CUDA_VER}"
ENV RAPIDS_DEPENDENCIES="latest"
ENV RAPIDS_PY_VERSION="${PYTHON_VER}"

# Install system packages depending on the LINUX_VER
RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    rapids-retry apt-get update -y
    apt-get upgrade -y
    PACKAGES_TO_INSTALL=(
      ca-certificates
      curl
      file
      tzdata
      unzip
      wget
    )

    # tzdata is needed by the ORC library used by pyarrow, because it provides /etc/localtime
    # On Ubuntu 24.04 and newer, we also need tzdata-legacy.
    os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2)
    # 'shellcheck' is unhappy with the use of '>' to compare decimals here, but it works as expected for the 'bash' version in these
    # images, and installing 'bc' or using a Python interpreter seem heavy for this purpose.
    #
    # shellcheck disable=SC2072
    if [[ "${os_version}" > "24.04" ]] || [[ "${os_version}" == "24.04" ]]; then
        PACKAGES_TO_INSTALL+=(tzdata-legacy)
    fi

    apt-get install -y --no-install-recommends \
      "${PACKAGES_TO_INSTALL[@]}"
    update-ca-certificates
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/*
    ;;
  "rockylinux"*)
    dnf -y update
    PACKAGES_TO_INSTALL=(
      ca-certificates
      file
      unzip
      wget
      which
      yum-utils
    )
    dnf -y install --setopt=install_weak_deps=False \
      "${PACKAGES_TO_INSTALL[@]}"
    update-ca-trust extract
    dnf clean all
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}"
    exit 1
    ;;
esac
EOF

# Create condarc file from env vars
ENV RAPIDS_CONDA_BLD_ROOT_DIR=/tmp/conda-bld-workspace
ENV RAPIDS_CONDA_BLD_OUTPUT_DIR=/tmp/conda-bld-output
COPY condarc.tmpl /tmp/condarc.tmpl

# Install CI tools using mamba
RUN <<EOF
# Install prereq for envsubst
rapids-mamba-retry install -y \
  gettext

# create condarc file from env vars
cat /tmp/condarc.tmpl | envsubst | tee /opt/conda/.condarc; \
rm -f /tmp/condarc.tmpl

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

PACKAGES_TO_INSTALL=(
  'anaconda-client>=1.13.1'
  'ca-certificates>=2026.1.4'
  'certifi>=2026.1.4'
  'conda-build>=25.11.1'
  'conda-package-handling>=2.4.0'
  'dunamai>=1.25.0'
  'git>=2.52.0'
  'jq>=1.8.1'
  'packaging>=25.0'
  "python>=${PYTHON_VERSION},<${PYTHON_UPPER_BOUND}=*_${PYTHON_ABI_TAG}"
  'rapids-dependency-file-generator==1.*'
  'rattler-build>=0.55.0'
)

rapids-mamba-retry install -y \
  "${PACKAGES_TO_INSTALL[@]}"

conda clean -aiptfy
EOF

# Install codecov-cli
ARG CODECOV_VER=notset
RUN <<EOF
# codecov-cli
#
# codecov-cli is a noarch Python package, but some of its dependencies require compilation.
# compilers are installed defensively here to prevent issues like "a dependency of codecov-cli
# doesn't support CPU_ARCH / LINUX_VER / PYTHON_VER" from slowing down updates to RAPIDS CI.
#
case "${LINUX_VER}" in
  "ubuntu"*)
    COMPILER_PACKAGES=(
      gcc
      g++
    )
    rapids-retry apt-get update -y
    apt-get install -y --no-install-recommends \
      "${COMPILER_PACKAGES[@]}"
    ;;
  "rockylinux"*)
    COMPILER_PACKAGES=(
      gcc
      gcc-c++
    )
    dnf install -y \
      "${COMPILER_PACKAGES[@]}"
    ;;
esac

rapids-pip-retry install --prefer-binary \
  "codecov-cli==${CODECOV_VER}"

# remove compiler packages... conda-based CI should use conda-forge's compilers
case "${LINUX_VER}" in
  "ubuntu"*)
    apt-get purge -y \
      "${COMPILER_PACKAGES[@]}"
    apt-get autoremove -y
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/*
    ;;
  "rockylinux"*)
    dnf remove -y \
      "${COMPILER_PACKAGES[@]}"
    dnf clean all
    ;;
esac

# clear the pip cache, to shrink image size and prevent unintentionally
# pinning CI to older versions of things
pip cache purge
EOF

RUN /opt/conda/bin/git config --system --add safe.directory '*'

# Add pip.conf
COPY pip.conf /etc/xdg/pip/pip.conf

CMD ["/bin/bash"]
