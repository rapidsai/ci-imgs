ARG LOCKFILE
FROM mambaorg/micromamba:1.5.8 as conda_env_creator
ARG LOCKFILE
COPY --chown=$MAMBA_USER:$MAMBA_USER ${LOCKFILE} /tmp/env.lock
RUN cat /tmp/env.lock

RUN micromamba install --name base --yes conda-lock
RUN conda-lock install --prefix /opt/conda /tmp/env.lock

FROM
COPY --from conda_env_creator /opt/conda /opt/conda

ARG TARGETPLATFORM
ARG CUDA_VER
ARG LINUX_VER

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

# Create condarc file from env vars
ENV RAPIDS_CONDA_BLD_ROOT_DIR=/tmp/conda-bld-workspace
ENV RAPIDS_CONDA_BLD_OUTPUT_DIR=/tmp/conda-bld-output
COPY context/condarc.tmpl /tmp/condarc.tmpl
RUN cat /tmp/condarc.tmpl | envsubst | tee /opt/conda/.condarc; \
    rm -f /tmp/condarc.tmpl

RUN /opt/conda/bin/git config --system --add safe.directory '*'

CMD ["/bin/bash"]
