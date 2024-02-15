ARG CUDA_VER=notset
ARG LINUX_VER=notset
ARG PYTHON_VER=notset
ARG YQ

FROM mikefarah/yq:${YQ} as yq

FROM rapidsai/miniforge-cuda:cuda${CUDA_VER}-base-${LINUX_VER}-py${PYTHON_VER}

ARG TARGETPLATFORM
ARG CUDA_VER
ARG LINUX_VER
ARG PYTHON_VER
ARG CODECOV

ARG DEBIAN_FRONTEND=noninteractive

# Set RAPIDS versions env variables
ENV RAPIDS_CUDA_VERSION="${CUDA_VER}"
ENV RAPIDS_PY_VERSION="${PYTHON_VER}"

# Add sccache/build variables
ENV CMAKE_CUDA_COMPILER_LAUNCHER=sccache
ENV CMAKE_CXX_COMPILER_LAUNCHER=sccache
ENV CMAKE_C_COMPILER_LAUNCHER=sccache
ENV SCCACHE_BUCKET=rapids-sccache-east
ENV SCCACHE_REGION=us-east-2
ENV SCCACHE_IDLE_TIMEOUT=32768
ENV SCCACHE_S3_USE_SSL=true
ENV SCCACHE_S3_NO_CREDENTIALS=false

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Install system packages depending on the LINUX_VER
RUN <<EOF
case "${LINUX_VER}" in
  "ubuntu"*)
    echo 'APT::Update::Error-Mode "any";' > /etc/apt/apt.conf.d/warnings-as-errors
    apt-get update
    apt-get upgrade -y
    apt-get install -y --no-install-recommends \
      file \
      unzip \
      wget
    rm -rf "/var/lib/apt/lists/*"
    ;;
  "centos"* | "rockylinux"*)
    yum -y update
    yum -y install --setopt=install_weak_deps=False \
      file \
      unzip \
      wget \
      which \
      yum-utils
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

# Install CI tools using mamba
RUN <<EOF
rapids-mamba-retry install -y \
  anaconda-client \
  boa \
  gettext \
  gh \
  git \
  jq \
  "sccache==0.7.6" \
  "python=${PYTHON_VERSION}.*=*_cpython"
conda clean -aipty
EOF

# Install codecov binary
RUN <<EOF
case "${TARGETPLATFORM}" in
  "linux/amd64")
    CODECOV_VERSION=v${CODECOV}
    curl https://uploader.codecov.io/verification.gpg --max-time 10 --retry 5 \
      | gpg --no-default-keyring --keyring trustedkeys.gpg --import
    curl -Os --max-time 10 --retry 5 https://uploader.codecov.io/${CODECOV_VERSION}/linux/codecov
    curl -Os --max-time 10 --retry 5 https://uploader.codecov.io/${CODECOV_VERSION}/linux/codecov.SHA256SUM
    curl -Os --max-time 10 --retry 5 https://uploader.codecov.io/${CODECOV_VERSION}/linux/codecov.SHA256SUM.sig
    gpgv codecov.SHA256SUM.sig codecov.SHA256SUM
    shasum -a 256 -c codecov.SHA256SUM
    chmod +x codecov
    mv codecov /usr/local/bin
    rm -f codecov*
    ;;
  *)
    echo 'Codecov is only supported on "linux/amd64" machines'
    ;;
esac
EOF

# Create condarc file from env vars
ENV RAPIDS_CONDA_BLD_ROOT_DIR=/tmp/conda-bld-workspace
ENV RAPIDS_CONDA_BLD_OUTPUT_DIR=/tmp/conda-bld-output
COPY condarc.tmpl /tmp/condarc.tmpl
RUN cat /tmp/condarc.tmpl | envsubst | tee /opt/conda/.condarc; \
    rm -f /tmp/condarc.tmpl

RUN /opt/conda/bin/git config --system --add safe.directory '*'

# Install CI tools using pip
RUN pip install dunamai "rapids-dependency-file-generator==1.*" \
    && pip cache purge

COPY --from=yq /usr/bin/yq /usr/local/bin/yq
COPY --from=amazon/aws-cli /usr/local/aws-cli/ /usr/local/aws-cli/
COPY --from=amazon/aws-cli /usr/local/bin/ /usr/local/bin/

CMD ["/bin/bash"]
