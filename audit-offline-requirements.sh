#!/bin/bash
# audit-offline-requirements.sh
#
# Run on the AIRGAPPED target where hpc-ai-envs is checked out. Doesn't
# download or install anything — produces a report of what's needed for
# an offline build.
#
# Usage:
#   ./audit-offline-requirements.sh [-v|--verbose] [-s|--self] <hpc-ai-envs-checkout-dir>
#
# Modes:
#   (default)    Concise SYSADMIN list: bare `git clone` and `wget` commands
#                for the site-dependent (Slingshot-version-tied) sources to
#                fetch on a connected system. Suitable to hand to sysadmins.
#   -s, --self   Concise DEVELOPER report: the prep-base-image Dockerfile
#                approach, showing what to pre-bake into the container image
#                (SS-independent) vs what to ship as a small on-site source
#                bundle (SS-version-tied).
#   -v, --verbose  Full detail: OS-level requirements on airgapped build host,
#                version pins, raw URL and apt-get extracts, .deb list,
#                bundle assembly layout, host SHS package inventory.

set -eu

VERBOSE=0
SELF=0
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose) VERBOSE=1; shift ;;
        -s|--self)    SELF=1; shift ;;
        -h|--help)
            # Print only the leading header comment block (skip shebang, stop at first blank line)
            awk 'NR==1 && /^#!/{next} /^#/{sub(/^# ?/,""); print; next} /^$/{exit}' "$0"
            exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *)  POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]:-}"

HPC_AI_ENVS="${1:?Usage: $0 [-v|--verbose|-s|--self] <hpc-ai-envs-checkout-dir>}"
DFS="$HPC_AI_ENVS/dockerfile_scripts"

if [ ! -d "$HPC_AI_ENVS" ]; then
    echo "ERROR: not a directory: $HPC_AI_ENVS" >&2
    exit 1
fi

# --- Detect version pins from the source tree ------------------------------
get() { grep -m1 "$2" "$1" 2>/dev/null | head -1 | sed -E 's/.*=[[:space:]]*"?([^"[:space:]]+)"?.*/\1/'; }

BASE_IMAGE_DEFAULT="docker.io/vllm/vllm-openai:v0.23.0-aarch64-cu129-ubuntu2404"
BASE_IMAGE="${BASE_IMAGE:-$BASE_IMAGE_DEFAULT}"

SHS_VERSION=$(get "$DFS/cray-libs.sh" '^SHS_VERSION=')
LIBFABRIC_VERSION=$(grep -m1 '^LIBFABRIC_VERSION' "$HPC_AI_ENVS/Makefile" | sed -E 's/.*[:=]+[[:space:]]*//')
PMIX_VERSION=$(grep -m1 'PMIX_VERSION=' "$DFS/build_pmix.sh" | sed -E 's/.*:-([0-9.]+).*/\1/')
OMPI_VER=$(get "$DFS/ompi.sh" 'OMPI_VER_NUM=')
AWS_VER=$(get "$DFS/build_aws.sh" '^AWS_VER_NUM=')
NCCL_TESTS_VER=$(get "$DFS/build_tests.sh" 'NCCL_VER=')
OSU_VER=$(get "$DFS/build_tests.sh" 'OSU_VER=')
NCCL_VER=$(get "$DFS/build_nccl.sh" 'git checkout' | awk '{print $NF}' | tr -d ')')
PMIX_VERSION_DFL=$(get "$DFS/build_pmix.sh" 'PMIX_VERSION=')

# --- Derived URLs ----------------------------------------------------------
OMPI_MAJOR_MINOR="${OMPI_VER%.*}"
URL_LIBFABRIC="https://github.com/ofiwg/libfabric/releases/download/v${LIBFABRIC_VERSION}/libfabric-${LIBFABRIC_VERSION}.tar.bz2"
URL_PMIX="https://github.com/openpmix/openpmix/releases/download/v${PMIX_VERSION:-$PMIX_VERSION_DFL}/pmix-${PMIX_VERSION:-$PMIX_VERSION_DFL}.tar.gz"
URL_OMPI="https://download.open-mpi.org/release/open-mpi/v${OMPI_MAJOR_MINOR}/openmpi-${OMPI_VER}.tar.gz"
URL_AWS="https://github.com/aws/aws-ofi-nccl/releases/download/v${AWS_VER}/aws-ofi-nccl-${AWS_VER}.tar.gz"
URL_OSU="https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VER}.tar.gz"

# --- Auto-extract deb list from build scripts ------------------------------
DEB_LIST=$(awk '/\\$/{sub(/\\$/,""); printf "%s ", $0; next} {print}' \
    "$HPC_AI_ENVS/Dockerfile-ngc-hpc" \
    "$DFS"/*.sh 2>/dev/null \
  | grep -oE 'apt-get install[^;&|]*' \
  | sed -E 's/apt-get install//; s/-y|--no-install-recommends|-o [^ ]+|DEBIAN_FRONTEND=[^ ]+//g' \
  | tr ' ' '\n' \
  | grep -E '^[a-z0-9][a-z0-9._+-]*$' \
  | grep -vE '^(true|false)$' \
  | sort -u)

# ============================================================================
#   MODE: concise sysadmin (default)
#   Just the site-dependent fetch commands, shell-ready.
# ============================================================================
if [ "$VERBOSE" -eq 0 ] && [ "$SELF" -eq 0 ]; then
cat <<EOF
#!/bin/bash
# hpc-ai-envs offline source fetch — run on a connected system.
# Produces ./offline-sources/{git,tar}/ ready to drop into the
# hpc-ai-envs checkout root before building.
set -eu

mkdir -p offline-sources/git offline-sources/tar
cd offline-sources/git

git clone --depth 1 -b ${SHS_VERSION:-<unset>} https://github.com/HewlettPackard/shs-cassini-headers.git
git clone --depth 1 -b ${SHS_VERSION:-<unset>} https://github.com/HewlettPackard/shs-cxi-driver.git
git clone --depth 1 -b ${SHS_VERSION:-<unset>} https://github.com/HewlettPackard/shs-libcxi.git
git clone --depth 1 -b ${SHS_VERSION:-<unset>} https://github.com/HewlettPackard/shs-libfabric.git
git clone --depth 1 -b ${NCCL_TESTS_VER:-<unset>} https://github.com/NVIDIA/nccl-tests.git
git clone https://github.com/nvidia/nccl.git
( cd nccl && git checkout ${NCCL_VER:-<unset>} )

cd ../tar
wget $URL_LIBFABRIC
wget $URL_PMIX
wget $URL_OMPI
wget $URL_AWS
wget $URL_OSU

echo "Done. Copy ./offline-sources/ into the hpc-ai-envs checkout root."
EOF
exit 0
fi

# ============================================================================
#   MODE: concise self (developer prep-base approach)
# ============================================================================
if [ "$SELF" -eq 1 ] && [ "$VERBOSE" -eq 0 ]; then
cat <<EOF
================================================================
  hpc-ai-envs offline build — self / developer view
  Checkout: $HPC_AI_ENVS
================================================================

STRATEGY: Pre-bake Slingshot-INDEPENDENT parts into a prepared base image on
the connected side. Only ship SS-version-tied source and a small bundle
to the airgapped side.

--- Version pins (auto-detected) ---
  BASE_IMAGE         = $BASE_IMAGE
  SHS_VERSION        = ${SHS_VERSION:-<unset>}
  LIBFABRIC_VERSION  = ${LIBFABRIC_VERSION:-<unset>}
  PMIX_VERSION       = ${PMIX_VERSION:-<unset>}
  OMPI_VER           = ${OMPI_VER:-<unset>}
  AWS_VER            = ${AWS_VER:-<unset>}
  NCCL_TESTS_VER     = ${NCCL_TESTS_VER:-<unset>}
  OSU_VER            = ${OSU_VER:-<unset>}

============================================================
  Bake into the prepared base image (SS-independent)
============================================================
Build once on a connected system, save as vllm-prepared.tar, ship over.

Dockerfile.vllm-prepared:

  FROM $BASE_IMAGE

  # cuda-nvml-dev provides nvml.h — libfabric's hmem_cuda code needs it
  # (auto-detected in the vLLM base image; missing header breaks build later)
  RUN apt-get update && apt-get install -y --no-install-recommends \\
      cuda-nvml-dev-12-9 && rm -rf /var/lib/apt/lists/*

  # All other apt packages the build scripts install (auto-extracted)
  RUN apt-get update && apt-get install -y --no-install-recommends \\
$(echo "$DEB_LIST" | awk '{if(NR>1)print prev" \\"; prev="        "$0} END{if(prev!="")print prev}')
      && rm -rf /var/lib/apt/lists/*

  # Pre-build PMIx (no Slingshot dep)
  ARG PMIX_VERSION=${PMIX_VERSION:-5.0.3}
  RUN cd /tmp && wget -q $URL_PMIX && \\
      tar xzf pmix-\${PMIX_VERSION}.tar.gz && cd pmix-\${PMIX_VERSION} && \\
      ./configure --prefix=/container/hpc --with-libevent --with-hwloc && \\
      make -j\$(nproc) && make install && cd / && rm -rf /tmp/pmix-*

  # Pre-build NCCL (no Slingshot dep; network plugin comes later)
  RUN git clone --depth 1 https://github.com/NVIDIA/nccl.git /tmp/nccl && \\
      cd /tmp/nccl && \\
      make -j\$(nproc) src.build CUDA_HOME=/usr/local/cuda BUILDDIR=/container/nccl && \\
      cd / && rm -rf /tmp/nccl

  # Blank sources.list so 'apt-get update' on airgapped side is a no-op
  RUN > /etc/apt/sources.list && \\
      rm -rf /etc/apt/sources.list.d/* && \\
      apt-get update

  ENV PATH=/container/nccl/bin:\$PATH \\
      LD_LIBRARY_PATH=/container/hpc/lib:/container/nccl/lib:\$LD_LIBRARY_PATH \\
      NCCL_HOME=/container/nccl \\
      PMIX_HOME=/container/hpc

Build & save:

  podman build -f Dockerfile.vllm-prepared -t vllm-prepared:v0.23.0 .
  podman save -o vllm-prepared.tar vllm-prepared:v0.23.0

Use as USER_IMAGE on the airgapped side (skips apt work + NCCL + PMIx):

  podman load -i vllm-prepared.tar
  make ngc USER_IMAGE=vllm-prepared:v0.23.0 DOCKER=podman

============================================================
  Ship separately (SS-version-tied source bundle)
============================================================

Small source bundle (~50 MB) for on-site compilation against target SHS.

  git clone --depth 1 -b ${SHS_VERSION:-<unset>} https://github.com/HewlettPackard/shs-cassini-headers.git
  git clone --depth 1 -b ${SHS_VERSION:-<unset>} https://github.com/HewlettPackard/shs-cxi-driver.git
  git clone --depth 1 -b ${SHS_VERSION:-<unset>} https://github.com/HewlettPackard/shs-libcxi.git
  git clone --depth 1 -b ${SHS_VERSION:-<unset>} https://github.com/HewlettPackard/shs-libfabric.git
  git clone --depth 1 -b ${NCCL_TESTS_VER:-<unset>} https://github.com/NVIDIA/nccl-tests.git

  wget $URL_LIBFABRIC
  wget $URL_OMPI
  wget $URL_AWS
  wget $URL_OSU

Package layout:

  offline-bundle/
    base-image/vllm-prepared.tar          (from Dockerfile above)
    git/{shs-*,nccl-tests}/               (branch-pinned)
    tar/{libfabric,openmpi,aws-ofi-nccl,osu}.tar.*

  tar czf offline-bundle.tgz offline-bundle/

============================================================
  On-site (airgapped) workflow
============================================================

  cd hpc-ai-envs
  tar xzf offline-bundle.tgz
  ln -s offline-bundle offline-sources        # patched scripts prefer this
  podman load -i offline-bundle/base-image/vllm-prepared.tar

  WITH_MPI=1 WITH_OFI=1 WITH_NCCL=1 MPI_TYPE=openmpi \\
    make ngc USER_IMAGE=vllm-prepared:v0.23.0 DOCKER=podman 2>&1 | tee build.log

EOF
exit 0
fi

# ============================================================================
#   MODE: verbose
# ============================================================================
cat <<EOF
================================================================
  hpc-ai-envs offline build — requirements audit (verbose)
  Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
  Checkout:  $HPC_AI_ENVS
================================================================

================================================================
  1. HOST OS PACKAGES REQUIRED ON THE AIRGAPPED BUILD HOST
================================================================

These must be installed on the build host itself (not the container):

  podman           - container build engine
  git              - to check out the hpc-ai-envs sources
  tar / gzip       - to unpack the offline bundle
  make             - to invoke the Makefile targets
  coreutils        - basic tools (mktemp, install, etc.)

Optional but useful:
  apptainer or singularity  - only if converting the built image to .sif
                              for WLM-based execution

Slingshot userspace (already present per SHS install, listed for reference):
$(rpm -qa 2>/dev/null | grep -iE "cxi|cassini|slingshot|shs|libfabric" | sort | sed 's/^/  /' || \
  dpkg -l 2>/dev/null | grep -iE "cxi|cassini|slingshot|shs|libfabric" | sed 's/^/  /' || \
  echo "  (no rpm/dpkg available or no SHS packages found)")

Kernel & OS:
  $(uname -r)   $(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo unknown)

================================================================
  2. FILES TO DOWNLOAD ON A CONNECTED SYSTEM AND SHIP OVER
================================================================

Detected version pins from checkout:
  BASE_IMAGE         = $BASE_IMAGE
  SHS_VERSION        = ${SHS_VERSION:-<unset>}       (branch of shs-* repos)
  LIBFABRIC_VERSION  = ${LIBFABRIC_VERSION:-<unset>}
  PMIX_VERSION       = ${PMIX_VERSION:-<unset>}
  OMPI_VER           = ${OMPI_VER:-<unset>}
  AWS_VER            = ${AWS_VER:-<unset>}
  NCCL_TESTS_VER     = ${NCCL_TESTS_VER:-<unset>}
  OSU_VER            = ${OSU_VER:-<unset>}

--- 2a. Base container image (podman save on connected side) ---
  $BASE_IMAGE
    -> Fetch with: podman pull $BASE_IMAGE
    -> Save with:  podman save -o vllm-base.tar $BASE_IMAGE

--- 2b. Git repos to clone (shallow --depth 1 is sufficient) ---
  https://github.com/HewlettPackard/shs-cassini-headers.git   (branch: ${SHS_VERSION:-release/shs-14.0.0})
  https://github.com/HewlettPackard/shs-cxi-driver.git        (branch: ${SHS_VERSION:-release/shs-14.0.0})
  https://github.com/HewlettPackard/shs-libcxi.git            (branch: ${SHS_VERSION:-release/shs-14.0.0})
  https://github.com/HewlettPackard/shs-libfabric.git         (branch: ${SHS_VERSION:-release/shs-14.0.0})
  https://github.com/NVIDIA/nccl.git                          (main)
  https://github.com/NVIDIA/nccl-tests.git                    (tag: ${NCCL_TESTS_VER:-v2.15.0})

--- 2c. Source tarballs to wget ---
  https://github.com/ofiwg/libfabric/releases/download/v${LIBFABRIC_VERSION:-2.3.1}/libfabric-${LIBFABRIC_VERSION:-2.3.1}.tar.bz2
  https://github.com/openpmix/openpmix/releases/download/v${PMIX_VERSION:-5.0.3}/pmix-${PMIX_VERSION:-5.0.3}.tar.gz
  https://download.open-mpi.org/release/open-mpi/v${OMPI_VER%.*}/openmpi-${OMPI_VER:-<see-ompi.sh>}.tar.gz
  https://github.com/aws/aws-ofi-nccl/releases/download/v${AWS_VER:-<see-build_aws.sh>}/aws-ofi-nccl-${AWS_VER:-<see>}.tar.gz
  https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VER:-<see-build_tests.sh>}.tar.gz

--- 2d. .deb packages that get installed INTO the container ---
Union of every 'apt-get install' across Dockerfile-ngc-hpc and
dockerfile_scripts/*.sh. Auto-extracted from the checkout:

$(awk '/\\$/{sub(/\\$/,""); printf "%s ", \$0; next} {print}' \
    "$HPC_AI_ENVS/Dockerfile-ngc-hpc" \
    "$DFS"/*.sh 2>/dev/null \
  | grep -oE 'apt-get install[^;&|]*' \
  | sed -E 's/apt-get install//; s/-y|--no-install-recommends|-o [^ ]+|DEBIAN_FRONTEND=[^ ]+//g' \
  | tr ' ' '\n' \
  | grep -E '^[a-z0-9][a-z0-9._+-]*\$' \
  | grep -vE '^(true|false)\$' \
  | sort -u \
  | sed 's/^/  /')

Fetch these inside the same base image so arch/versions match. On the
connected system:

  mkdir debs
  podman run --rm -v \$PWD/debs:/debs \\
    $BASE_IMAGE \\
    bash -c "apt-get update && \\
             apt-get install -y --no-install-recommends --download-only \\
               -o Dir::Cache::archives=/debs \\
               \$(<list-of-packages-above>)"

Then ship debs/ over as part of the bundle.

NOTE: cuda-nvml-dev-12-9 (from developer.download.nvidia.com/compute/cuda)
requires the NVIDIA CUDA apt repo to already be configured in the base
image. The vLLM/NGC base images ship with it configured. If it's not there,
add libnvidia-ml-dev from Ubuntu universe as a fallback.

================================================================
  3. RAW EXTRACT FROM SCRIPTS (for verification / reproducibility)
================================================================

--- URLs referenced in the build scripts ---
$(awk '/\\$/{sub(/\\$/,""); printf "%s", \$0; next} {print}' \
    "$HPC_AI_ENVS/Dockerfile-ngc-hpc" \
    "$HPC_AI_ENVS/Makefile" \
    "$DFS"/*.sh 2>/dev/null \
  | grep -oE 'https?://[^" '"'"']+' \
  | grep -vE '^https?://(hub\.docker\.com|github\.com/ROCm|github\.com/thomas-bouvier)' \
  | sort -u \
  | sed 's/^/  /')

--- apt-get commands referenced ---
$(awk '/\\$/{sub(/\\$/,""); printf "%s", \$0; next} {print}' \
    "$HPC_AI_ENVS/Dockerfile-ngc-hpc" \
    "$DFS"/*.sh 2>/dev/null \
  | grep -E 'apt-get (install|update)' \
  | grep -v '^\s*#' \
  | sed 's/^/  /' \
  | head -20)

================================================================
  4. ASSEMBLY LAYOUT (for the shipped bundle)
================================================================

On the connected system, produce a bundle with this layout:

  offline-bundle/
    base-image/
      vllm-base.tar                    (podman save output)
    git/
      shs-cassini-headers/             (git clone --depth 1 -b <SHS_VERSION>)
      shs-cxi-driver/
      shs-libcxi/
      shs-libfabric/
      nccl/
      nccl-tests/                      (branch ${NCCL_TESTS_VER:-v2.15.0})
    tar/
      libfabric-*.tar.bz2
      pmix-*.tar.gz
      openmpi-*.tar.gz
      aws-ofi-nccl-*.tar.gz
      osu-micro-benchmarks-*.tar.gz
    debs/
      *.deb

  Then: tar czf offline-bundle.tgz offline-bundle/

On the airgapped system, extract to \$HPC_AI_ENVS/offline-sources/ and apply
the offline-helper.sh patches so cray-libs.sh / ompi.sh / build_pmix.sh /
build_aws.sh / build_tests.sh check /offline-sources/ before hitting the
network.

EOF
