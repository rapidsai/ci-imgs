ARG CUDA_VER=11.5.1
ARG LINUX_VER=ubuntu18.04
ARG PY_VER=3.8
FROM rapidsai/mambaforge-cuda:${CUDA_VER}-base-${LINUX_VER}-py${PY_VER}

ARG CUDA_VER
ARG LINUX_VER

ARG DEBIAN_FRONTEND=noninteractive

# Add sccache variables
ENV CMAKE_CUDA_COMPILER_LAUNCHER=sccache
ENV CMAKE_CXX_COMPILER_LAUNCHER=sccache
ENV CMAKE_C_COMPILER_LAUNCHER=sccache

# Copy condarc to configure conda build
COPY condarc /opt/conda/.condarc

# Install system packages depending on the LINUX_VER
RUN case "${LINUX_VER}" in \
      "ubuntu"*) \
        PKG_CUDA_VER="$(echo ${CUDA_VER} | cut -d '.' -f1,2 | tr '.' '-')" \
        && apt-get update \
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
      "centos"*) \
        PKG_CUDA_VER="$(echo ${CUDA_VER} | cut -d '.' -f1,2 | tr '.' '-')" \
        && yum -y update \
        && yum -y install --setopt=install_weak_deps=False \
          cuda-cudart-devel-${PKG_CUDA_VER} \
          cuda-driver-devel-${PKG_CUDA_VER} \
          cuda-gdb-${PKG_CUDA_VER} \
          cuda-cupti-${PKG_CUDA_VER} \
          wget \
          which \
        && rpm -Uvh --nodeps $(repoquery --location cuda-nvcc-${PKG_CUDA_VER}) \
        && yum clean all; \
        ;; \
      *) \
        echo "Unsupported LINUX_VER: ${LINUX_VER}" && exit 1; \
        ;; \
    esac

# Install gpuci-tools
RUN wget https://github.com/rapidsai/gpuci-tools/releases/latest/download/tools.tar.gz -O - \
  | tar -xz -C /usr/local/bin

# Install CI tools using conda
RUN gpuci_mamba_retry install -y \
    anaconda-client \
    awscli \
    boa \
    git \
    jq \
    ninja \
    sccache \
  && conda clean -aipty

CMD ["/bin/bash"]
