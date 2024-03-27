ARG CUDA_VER=notset
ARG LINUX_VER=notset
ARG PYTHON_VER=notset
ARG YQ_VER
ARG AWS_CLI_VER

FROM mikefarah/yq:${YQ_VER} as yq

FROM amazon/aws-cli:${AWS_CLI_VER} as aws-cli

FROM rapidsai/miniforge-cuda:cuda${CUDA_VER}-base-${LINUX_VER}-py${PYTHON_VER}

ARG TARGETPLATFORM
ARG CUDA_VER
ARG LINUX_VER
ARG PYTHON_VER

ARG DEBIAN_FRONTEND=noninteractive

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
  -c rapidsai \
  anaconda-client \
  boa \
  dunamai \
  gettext \
  git \
  jq \
  "python=${PYTHON_VERSION}.*=*_cpython" \
  "rapids-dependency-file-generator==1.*"
conda clean -aipty
EOF

# Install sccache and gh cli
ARG SCCACHE_VER
ARG REAL_ARCH
ARG GH_CLI_VER=notset
ARG CPU_ARCH
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

# Install codecov binary
ARG CODECOV_VER
RUN <<EOF
curl https://uploader.codecov.io/verification.gpg --max-time 10 --retry 5 | gpg --no-default-keyring --keyring trustedkeys.gpg --import

case "${TARGETPLATFORM}" in
  "linux/amd64") codecov_url="https://uploader.codecov.io/v${CODECOV_VER}/linux/codecov" ;;
  "linux/arm64") codecov_url="https://uploader.codecov.io/v${CODECOV_VER}/aarch64/codecov" ;;
  *) echo 'Unsupported platform' && exit 1 ;;
esac

curl -Os --max-time 10 --retry 5 ${codecov_url}
curl -Os --max-time 10 --retry 5 ${codecov_url}.SHA256SUM
curl -Os --max-time 10 --retry 5 ${codecov_url}.SHA256SUM.sig

gpgv codecov.SHA256SUM.sig codecov.SHA256SUM
shasum -a 256 -c codecov.SHA256SUM
chmod +x codecov
mv codecov /usr/local/bin
rm -f codecov.SHA256SUM codecov.SHA256SUM.sig
EOF

# Create condarc file from env vars
ENV RAPIDS_CONDA_BLD_ROOT_DIR=/tmp/conda-bld-workspace
ENV RAPIDS_CONDA_BLD_OUTPUT_DIR=/tmp/conda-bld-output
COPY condarc.tmpl /tmp/condarc.tmpl
RUN cat /tmp/condarc.tmpl | envsubst | tee /opt/conda/.condarc; \
    rm -f /tmp/condarc.tmpl

RUN /opt/conda/bin/git config --system --add safe.directory '*'

COPY --from=yq /usr/bin/yq /usr/local/bin/yq
COPY --from=aws-cli /usr/local/aws-cli/ /usr/local/aws-cli/
COPY --from=aws-cli /usr/local/bin/ /usr/local/bin/

CMD ["/bin/bash"]
