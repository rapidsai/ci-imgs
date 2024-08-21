ARG CUDA_VER=notset
ARG LINUX_VER=notset
ARG PYTHON_VER=notset
ARG YQ_VER=notset
ARG AWS_CLI_VER=notset

FROM nvidia/cuda:${CUDA_VER}-base-${LINUX_VER} AS miniforge-cuda

ARG LINUX_VER
ARG PYTHON_VER
ARG DEBIAN_FRONTEND=noninteractive
ENV PATH=/opt/conda/bin:$PATH
ENV PYTHON_VERSION=${PYTHON_VER}

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Create a conda group and assign it as root's primary group
RUN <<EOF
groupadd conda
usermod -g conda root
EOF

# Ownership & permissions based on https://docs.anaconda.com/anaconda/install/multi-user/#multi-user-anaconda-installation-on-linux
COPY --from=condaforge/miniforge3:24.3.0-0 --chown=root:conda --chmod=770 /opt/conda /opt/conda

# Ensure new files are created with group write access & setgid. See https://unix.stackexchange.com/a/12845
RUN chmod g+ws /opt/conda

RUN <<EOF
# Ensure new files/dirs have group write permissions
umask 002
# install expected Python version
conda install -y -n base "python~=${PYTHON_VERSION}.0=*_cpython"
conda update --all -y -n base
if [[ "$LINUX_VER" == "rockylinux"* ]]; then
  yum install -y findutils
  yum clean all
fi
find /opt/conda -follow -type f -name '*.a' -delete
find /opt/conda -follow -type f -name '*.pyc' -delete
conda clean -afy
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
RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    apt-get update
    apt-get upgrade -y
    apt-get install -y --no-install-recommends \
      tzdata
    rm -rf "/var/lib/apt/lists/*"
    ;;
  "rockylinux"*)
    yum update -y
    yum clean all
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}" && exit 1
    ;;
esac
EOF

FROM mikefarah/yq:${YQ_VER} AS yq

FROM amazon/aws-cli:${AWS_CLI_VER} AS aws-cli

FROM miniforge-cuda

ARG TARGETPLATFORM=notset
ARG CUDA_VER=notset
ARG LINUX_VER=notset
ARG PYTHON_VER=notset

ARG DEBIAN_FRONTEND

# Set RAPIDS versions env variables
ENV RAPIDS_CUDA_VERSION="${CUDA_VER}"
ENV RAPIDS_PY_VERSION="${PYTHON_VER}"

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Install system packages depending on the LINUX_VER
RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    echo 'APT::Update::Error-Mode "any";' > /etc/apt/apt.conf.d/warnings-as-errors
    apt-get update
    apt-get upgrade -y
    apt-get install -y --no-install-recommends \
      curl \
      file \
      unzip \
      wget \
      gcc \
      g++
    rm -rf "/var/lib/apt/lists/*"
    ;;
  "centos"* | "rockylinux"*)
    yum -y update
    yum -y install --setopt=install_weak_deps=False \
      file \
      unzip \
      wget \
      which \
      yum-utils \
      gcc \
      gcc-c++
    yum clean all
    ;;
  *)
    echo "Unsupported LINUX_VER: ${LINUX_VER}"
    exit 1
    ;;
esac
EOF

# Install CUDA packages, only for CUDA 11 (CUDA 12+ should fetch from conda)
RUN <<EOF
case "${CUDA_VER}" in
  "11"*)
    PKG_CUDA_VER="$(echo ${CUDA_VER} | cut -d '.' -f1,2 | tr '.' '-')"
    echo "Attempting to install CUDA Toolkit ${PKG_CUDA_VER}"
    case "${LINUX_VER}" in
      "ubuntu"*)
        apt-get update
        apt-get upgrade -y
        apt-get install -y --no-install-recommends \
          cuda-gdb-${PKG_CUDA_VER} \
          cuda-cudart-dev-${PKG_CUDA_VER} \
          cuda-cupti-dev-${PKG_CUDA_VER}
        # ignore the build-essential package since it installs dependencies like gcc/g++
        # we don't need them since we use conda compilers, so this keeps our images smaller
        apt-get download cuda-nvcc-${PKG_CUDA_VER}
        dpkg -i --ignore-depends="build-essential" ./cuda-nvcc-*.deb
        rm ./cuda-nvcc-*.deb
        # apt will not work correctly if it thinks it needs the build-essential dependency
        # so we patch it out with a sed command
        sed -i 's/, build-essential//g' /var/lib/dpkg/status
        rm -rf "/var/lib/apt/lists/*"
        ;;
      "centos"* | "rockylinux"*)
        yum -y update
        yum -y install --setopt=install_weak_deps=False \
          cuda-cudart-devel-${PKG_CUDA_VER} \
          cuda-driver-devel-${PKG_CUDA_VER} \
          cuda-gdb-${PKG_CUDA_VER} \
          cuda-cupti-${PKG_CUDA_VER}
        rpm -Uvh --nodeps $(repoquery --location cuda-nvcc-${PKG_CUDA_VER})
        yum clean all
        ;;
      *)
        echo "Unsupported LINUX_VER: ${LINUX_VER}"
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Skipping CUDA Toolkit installation for CUDA ${CUDA_VER}"
    ;;
esac
EOF

# Install gha-tools
RUN wget https://github.com/rapidsai/gha-tools/releases/latest/download/tools.tar.gz -O - \
  | tar -xz -C /usr/local/bin

# Install prereq for envsubst
RUN <<EOF
rapids-mamba-retry install -y \
  gettext
conda clean -aipty
EOF

# Create condarc file from env vars
ENV RAPIDS_CONDA_BLD_ROOT_DIR=/tmp/conda-bld-workspace
ENV RAPIDS_CONDA_BLD_OUTPUT_DIR=/tmp/conda-bld-output
COPY condarc.tmpl /tmp/condarc.tmpl
RUN cat /tmp/condarc.tmpl | envsubst | tee /opt/conda/.condarc; \
    rm -f /tmp/condarc.tmpl

# Install CI tools using mamba
RUN <<EOF
rapids-mamba-retry install -y \
  anaconda-client \
  boa \
  dunamai \
  git \
  jq \
  "python=${PYTHON_VERSION}.*=*_cpython" \
  "rapids-dependency-file-generator==1.*"
conda clean -aipty
EOF

# Install sccache and gh cli
ARG SCCACHE_VER=notset
ARG REAL_ARCH=notset
ARG GH_CLI_VER=notset
ARG CPU_ARCH=notset
RUN <<EOF
curl -o /tmp/sccache.tar.gz \
  -L "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VER}/sccache-v${SCCACHE_VER}-"${REAL_ARCH}"-unknown-linux-musl.tar.gz"
tar -C /tmp -xvf /tmp/sccache.tar.gz
mv "/tmp/sccache-v${SCCACHE_VER}-"${REAL_ARCH}"-unknown-linux-musl/sccache" /usr/bin/sccache
chmod +x /usr/bin/sccache

wget https://github.com/cli/cli/releases/download/v${GH_CLI_VER}/gh_${GH_CLI_VER}_linux_${CPU_ARCH}.tar.gz
tar -xf gh_*.tar.gz
mv gh_*/bin/gh /usr/local/bin
rm -rf gh_*
EOF

# Install codecov from source distribution
ARG CODECOV_VER=notset
RUN <<EOF
# temporary workaround for discovered codecov binary install issue. See rapidsai/ci-imgs/issues/142
pip install codecov-cli==${CODECOV_VER}
EOF

RUN /opt/conda/bin/git config --system --add safe.directory '*'

COPY --from=yq /usr/bin/yq /usr/local/bin/yq
COPY --from=aws-cli /usr/local/aws-cli/ /usr/local/aws-cli/
COPY --from=aws-cli /usr/local/bin/ /usr/local/bin/

# Add pip.conf
COPY pip.conf /etc/xdg/pip/pip.conf

CMD ["/bin/bash"]
