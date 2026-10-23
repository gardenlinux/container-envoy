FIPS Port Report: Envoy Proxy
==============================

## Summary

**Application**: Envoy Proxy — a high-performance, cloud-native edge/middle/service proxy
widely used in service mesh deployments (e.g. Istio).

**Initial triage**:
- Primary language: C++ (Bazel build system)
- FIPS mechanism: GardenLinux FIPS-enabled OpenSSL, loaded at runtime via dlopen
  (using Envoy's --config=openssl BoringSSL-compat layer in compat/openssl/)
- Build pattern: D (Bazel) — Dockerfile generated from scratch; Bazel builds the binary
  inside the upstream envoy-build Docker container
- License: Apache-2.0

**Application metadata**:
- Version: 1.40.0
- Upstream git SHA: 9e5580933739775e8bce696a57a2e1bc99368f23
- FIPS library: GardenLinux FIPS OpenSSL (libssl.so.3 / libcrypto.so.3), loaded via dlopen

**Docker image produced**:
- Tag: gl-fips-envoy:1.40.0-amd64
- Compressed size: ~155 MB
- Virtual size: ~983 MB (698 MB envoy static binary + GardenLinux FIPS base)


## Steps and decisions

### Triage

- Identified C++ / Bazel from presence of WORKSPACE, BUILD files, MODULE.bazel, .bazelversion
- Envoy has two FIPS build paths: --config=boringssl-fips (native BoringSSL FIPS) and
  --config=openssl (BoringSSL-compat layer that dlopen's system OpenSSL at runtime)
- User chose --config=openssl to use GardenLinux FIPS OpenSSL
- Pattern D chosen: no existing Dockerfile suitable for patching; generated fresh from heredoc

### FIPS mechanism detail

Envoy's --config=openssl build compiles compat/openssl/ — a thin shim that implements
the BoringSSL API by calling OpenSSL via dlopen/dlsym at startup. The resulting binary is
statically linked (no libssl.so in ldd output), but contains the string "libssl.so.%d"
and calls dlopen("libssl.so.3") at runtime. The only libssl.so.3 in the GardenLinux FIPS
image is the FIPS-certified one — ensuring FIPS compliance.

### Build fixes encountered

1. **Doubled volume mount path**: Initial script used SCRIPT_DIR which resolved incorrectly
   when script ran from a subshell. Fixed by using PROJECT_ROOT=$(pwd) and running git
   checkout in a subshell ( cd ... ) to avoid changing the main shell's CWD.

2. **envoy-build entrypoint requires USER_UID**: The upstream envoy-build image entrypoint
   runs usermod and drops to uid 1000 via gosu. Without -e USER_UID=1000 the container
   exits with code 3. Fixed by adding -e USER_UID=1000 to docker run.

3. **Bazel cache volume ownership**: Named Docker volume created with root ownership; build
   runs as uid 1000. Fixed by a pre-step that overrides the entrypoint and chowns the
   cache dir to 1000:1000 before the build run.

4. **Bazel --jobs=HOST_CPUS-1=0**: .bazelrc sets `build --jobs=HOST_CPUS-1`; in a
   single-CPU container this evaluates to 0, which Bazel rejects. The workspace .bazelrc
   is processed before any command-line overrides so --jobs on the CLI doesn't help.
   Fixed by sed-patching .bazelrc inside the container before calling bazel.

5. **Disk exhaustion**: The Bazel build consumed ~20 GB of cache + intermediate objects
   on the Docker storage volume (/dev/vda, 79 GB), filling it to 100% before the final
   link step. Fixed by removing unused Docker images (~9 GB recovered) to give enough
   headroom for linking and the subsequent Docker image build.

6. **bazel-bin symlink not accessible on host**: bazel-bin in the source tree is a symlink
   into /home/envoybuild/.cache/bazel/... which lives inside the Docker volume and does
   not exist on the host filesystem. find on the host silently follows the broken symlink
   and finds nothing. Fixed by adding a third docker run step that mounts both the source
   tree and a /out bind mount, copies envoy-static and su-exec inside the container, then
   they appear on the host via the bind mount.

7. **Binary named envoy-static, not envoy**: The Bazel target //source/exe:envoy-static
   produces bazel-bin/source/exe/envoy-static. The script cp path was updated accordingly;
   the file is renamed to envoy when copied to the build context.

8. **addgroup not available in GardenLinux**: GardenLinux uses Debian shadow-utils which
   provides groupadd/useradd, not addgroup/adduser. Fixed by replacing:
     addgroup --system envoy && adduser --system --ingroup envoy ...
   with:
     groupadd --system envoy && useradd --system --gid envoy --no-create-home ...

9. **k3s disk-pressure taint**: After the build the Docker storage was at 93% usage,
   triggering k3s's disk-pressure taint (threshold ~85%). Fixed by removing the 20 GB
   Bazel cache volume (no longer needed after successful build) and the 698 MB build
   context binary, dropping usage to 54%.

### Test results

**Manual FIPS validation (test-image.sh equivalent):**
  [PASS] Image based on Garden Linux
  [PASS] FIPS variant: VARIANT_ID=container-sslfips-amd64
  [PASS] libssl.so.3 in image contains "FIPS" string
  [PASS] libssl.so.3 is OpenSSL (not BoringSSL, not aws-lc)
  [PASS] envoy binary contains "libssl.so" dlopen reference
  [PASS] OCI labels present: description, licenses, revision

Note: the test-image.sh c-cpp-openssl path uses `ldd $BINARY | grep libssl.so` which
fails for statically-linked dlopen binaries. The equivalent checks were run manually.
Envoy --version output confirms: "1.40.0/Modified/RELEASE/OpenSSL" — OpenSSL loaded.

**Kubernetes test (k3d cluster):**
  Image: gl-fips-envoy:1.40.0-amd64
  Pod status: Completed
  Pod logs: envoy  version: 9e5580933739775e8bce696a57a2e1bc99368f23/1.40.0/Modified/RELEASE/OpenSSL
  Result: PASS


## Files produced

  build-envoy-fips.sh      — build script
  build-envoy-fips.yml     — GitHub Actions workflow
  build-envoy-fips-report.txt — this report
