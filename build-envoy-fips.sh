#!/usr/bin/env bash
set -euo pipefail

# --- configuration -----------------------------------------------------------

REPO_URL="${REPO_URL:-https://github.com/envoyproxy/envoy}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/gardenlinux/gardenlinux/fips:1877.22}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
WORKDIR="${WORKDIR:-${PROJECT_ROOT}/.build/envoy-fips-build}"
IMAGE_NAME="${IMAGE_NAME:-gl-fips-envoy}"
ARCH="${ARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
VERSION="${VERSION:-1.40.1}"
UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA:-86af01fdec40c31d025c495a4aa303c4126b2fd0}"
BUILD_IMAGE="${BUILD_IMAGE:-docker.io/envoyproxy/envoy-build@sha256:0ec8c3295229234f5a5663b858d9e217fd409e2eba22afe7a9c6e4f634bd7ea8}"

# --- prerequisites -----------------------------------------------------------

check_tool() { command -v "$1" &>/dev/null || { echo "error: $1 not found" >&2; exit 1; }; }
check_tool git
check_tool docker
docker buildx version &>/dev/null || { echo "error: docker buildx not available" >&2; exit 1; }

# --- buildx driver -----------------------------------------------------------

if ! docker buildx inspect fips-builder &>/dev/null; then
    docker buildx create --name fips-builder --driver docker-container
fi
docker buildx use fips-builder

# --- clone / checkout --------------------------------------------------------

CLONE_DIR="${PROJECT_ROOT}/.build/fips-port-envoy"
if [ ! -d "${CLONE_DIR}" ]; then
    git clone "${REPO_URL}" "${CLONE_DIR}"
fi
( cd "${CLONE_DIR}" && git checkout "v${VERSION}" )

# --- build envoy binary with Bazel + --config=openssl ------------------------

mkdir -p "${WORKDIR}"

# Run bazel build inside the envoy-build container.
# A named Docker volume is used for the Bazel cache so incremental rebuilds
# are fast.  The source tree is bind-mounted read-write so Bazel can write
# its bazel-bin symlink forest.
#
# The entrypoint of envoy-build expects USER_UID and then drops to the
# envoybuild (uid 1000) user via gosu.  The cache volume must be owned by
# uid 1000 before the first run, so we initialise it with --entrypoint override.
# --jobs=HOST_CPUS overrides the .bazelrc default of HOST_CPUS-1, which would
# evaluate to 0 in single-CPU containers and cause Bazel to reject the build.
docker run --rm \
    --entrypoint /bin/bash \
    -v "envoy-bazel-cache-${ARCH}:/home/envoybuild/.cache/bazel" \
    "${BUILD_IMAGE}" \
    -c "mkdir -p /home/envoybuild/.cache/bazel && chown -R $(id -u):$(id -g) /home/envoybuild/.cache/bazel"

docker run --rm \
    --platform "linux/${ARCH}" \
    -e USER_UID="$(id -u)" \
    -v "${CLONE_DIR}:/source" \
    -v "envoy-bazel-cache-${ARCH}:/home/envoybuild/.cache/bazel" \
    -w /source \
    "${BUILD_IMAGE}" \
    bash -c "
        git config --global --add safe.directory /source
        sed -i 's/^build --jobs=HOST_CPUS-1/build --jobs=HOST_CPUS/' .bazelrc
        bazel build \
            --config=openssl \
            -c opt \
            --remote_download_toplevel \
            //source/exe:envoy-static \
            @su-exec
    "

# Copy artifacts out of the build container (bazel-bin is a symlink into the
# Docker volume which is not accessible on the host filesystem directly).
docker run --rm \
    -v "${CLONE_DIR}:/source" \
    -v "envoy-bazel-cache-${ARCH}:/home/envoybuild/.cache/bazel" \
    -v "${WORKDIR}:/out" \
    --entrypoint /bin/bash \
    "${BUILD_IMAGE}" \
    -c "
        cp /source/bazel-bin/source/exe/envoy-static /out/envoy
        SU_EXEC=\$(find /source/bazel-bin/external -name 'su-exec' -not -path '*.runfiles*' -type f | head -1)
        if [ -z \"\${SU_EXEC}\" ]; then echo 'error: su-exec not found' >&2; exit 1; fi
        cp \"\${SU_EXEC}\" /out/su-exec
        chmod 755 /out/envoy /out/su-exec
    "

cp "${CLONE_DIR}/distribution/docker/docker-entrypoint.sh" "${WORKDIR}/docker-entrypoint.sh"
cp "${CLONE_DIR}/configs/envoyproxy_io_proxy.yaml" "${WORKDIR}/envoy.yaml"

# --- generate Dockerfile.fips ------------------------------------------------

cat > "${WORKDIR}/Dockerfile.fips" <<DOCKERFILE
FROM ${BASE_IMAGE}
ARG UPSTREAM_GIT_SHA
LABEL org.opencontainers.image.description="A FIPS-enabled Envoy image"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.revision="\${UPSTREAM_GIT_SHA}"

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system envoy \\
    && useradd --system --gid envoy --no-create-home --shell /sbin/nologin envoy

RUN mkdir -p /etc/envoy
COPY envoy.yaml /etc/envoy/envoy.yaml
COPY envoy /usr/local/bin/envoy
COPY su-exec /usr/local/bin/su-exec
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod 755 /usr/local/bin/envoy /usr/local/bin/su-exec /docker-entrypoint.sh \
    && chown envoy:envoy /dev/stdout /dev/stderr || true

EXPOSE 10000
EXPOSE 9901
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["envoy", "-c", "/etc/envoy/envoy.yaml"]
DOCKERFILE

# --- build -------------------------------------------------------------------

docker buildx build \
    --platform "linux/${ARCH}" \
    --build-arg UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA}" \
    --load \
    --tag "${IMAGE_NAME}:${VERSION}-${ARCH}" \
    -f "${WORKDIR}/Dockerfile.fips" \
    "${WORKDIR}"

# --- report ------------------------------------------------------------------

echo "Built: ${IMAGE_NAME}:${VERSION}-${ARCH}"
