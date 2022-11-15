ARG CUDA_VER=11.5.1
ARG LINUX_VER=ubuntu18.04
ARG PYTHON_VER=3.8
FROM rapidsai/mambaforge-cuda:cuda${CUDA_VER}-base-${LINUX_VER}-py${PYTHON_VER}

ARG CUDA_VER
ARG LINUX_VER
ARG PYTHON_VER

ARG DEBIAN_FRONTEND=noninteractive

# Set RAPIDS versions env variables
ENV RAPIDS_CUDA_VERSION="${CUDA_VER}"
ENV RAPIDS_PY_VERSION="${PYTHON_VER}"

# Add sccache/build variables
ENV CMAKE_CUDA_COMPILER_LAUNCHER=sccache
ENV CMAKE_CXX_COMPILER_LAUNCHER=sccache
ENV CMAKE_C_COMPILER_LAUNCHER=sccache
ENV SCCACHE_BUCKET=rapids-sccache
ENV SCCACHE_REGION=us-west-2
ENV SCCACHE_IDLE_TIMEOUT=32768

# Install system packages depending on the LINUX_VER
RUN \
    PKG_CUDA_VER="$(echo ${CUDA_VER} | cut -d '.' -f1,2 | tr '.' '-')"; \
    case "${LINUX_VER}" in \
      "ubuntu"*) \
        apt-get update \
        && apt-get upgrade -y \
        && apt-get install -y --no-install-recommends \
          cuda-gdb-${PKG_CUDA_VER} \
          cuda-cudart-dev-${PKG_CUDA_VER} \
          cuda-cupti-dev-${PKG_CUDA_VER} \
          wget \
        # ignore the build-essential package since it installs dependencies like gcc/g++
        # we don't need them since we use conda compilers, so this keeps our images smaller
        && apt-get download cuda-nvcc-${PKG_CUDA_VER} \
        && dpkg -i --ignore-depends="build-essential" ./cuda-nvcc-*.deb \
        && rm ./cuda-nvcc-*.deb \
        # apt will not work correctly if it thinks it needs the build-essential dependency
        # so we patch it out with a sed command
        && sed -i 's/, build-essential//g' /var/lib/dpkg/status \
        && rm -rf "/var/lib/apt/lists/*"; \
        ;; \
      "centos"* | "rockylinux"*) \
        yum -y update \
        && yum -y install --setopt=install_weak_deps=False \
          cuda-cudart-devel-${PKG_CUDA_VER} \
          cuda-driver-devel-${PKG_CUDA_VER} \
          cuda-gdb-${PKG_CUDA_VER} \
          cuda-cupti-${PKG_CUDA_VER} \
          wget \
          which \
          yum-utils \
        && rpm -Uvh --nodeps $(repoquery --location cuda-nvcc-${PKG_CUDA_VER}) \
        && yum clean all; \
        ;; \
      *) \
        echo "Unsupported LINUX_VER: ${LINUX_VER}" && exit 1; \
        ;; \
    esac

# Install gha-tools
RUN wget https://github.com/rapidsai/gha-tools/releases/latest/download/tools.tar.gz -O - \
  | tar -xz -C /usr/local/bin

# Install CI tools using mamba
RUN rapids-mamba-retry install -y \
    anaconda-client \
    awscli \
    boa \
    gettext \
    gh \
    git \
    jq \
    sccache \
  && conda clean -aipty

# Create condarc file from env vars
ENV RAPIDS_CONDA_BLD_ROOT_DIR=/tmp/conda-bld-workspace
ENV RAPIDS_CONDA_BLD_OUTPUT_DIR=/tmp/conda-bld-output
COPY condarc.tmpl /tmp/condarc.tmpl
RUN cat /tmp/condarc.tmpl | envsubst | tee /opt/conda/.condarc; \
    rm -f /tmp/condarc.tmpl

RUN /opt/conda/bin/git config --system --add safe.directory '*'

# Install CI tools using pip
RUN pip install rapids-dependency-file-generator \
    && pip cache purge

CMD ["/bin/bash"]
