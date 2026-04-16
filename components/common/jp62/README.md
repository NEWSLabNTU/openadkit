# Jetson Linux 6.2 (JP62) Base Layer

## Overview

This directory contains the JP62-specific files for building Autoware common images on NVIDIA Jetson Orin (JetPack 6.2). The corresponding Dockerfile is at `components/common/Dockerfile.jp62`.

JP62 images fulfill the same contract as x86 CUDA images (`common-base-cuda` / `common-devel-cuda`), so downstream component `Dockerfile.cuda` files work unmodified — they simply receive JP62 images as their `COMMON_BASE_CUDA_IMAGE` / `COMMON_DEVEL_CUDA_IMAGE` build args.

## Files

| File | Purpose |
|------|---------|
| `../Dockerfile.jp62` | Multi-stage Dockerfile: `jp62-setup` → `common-base-jp62` → `common-devel-jp62` |
| `opencv-preferences` | APT pin to prefer Ubuntu OpenCV 4.5.4 over L4T's 4.8.0 |

## Architecture

```
nvcr.io/nvidia/l4t-tensorrt:r10.3.0-devel   (L4T base with CUDA 12.6, cuDNN 9.3, TensorRT 10.3)
  └─ jp62-setup                               (locale, OpenCV swap, CMake upgrade, ROS 2, L4T NVIDIA pkgs, CUDA env, spconv/cumm)
       └─ common-base-jp62                    (Autoware scripts + setup-dev-env.sh --module base)
            └─ common-devel-jp62              (setup-dev-env.sh --module all + dev-tools, rosdep, colcon build)
```

## How to build

```bash
# Local build (requires Docker buildx + arm64 QEMU or native Jetson)
./build.sh --platform jp62 --target common

# Or directly via docker buildx bake
docker buildx bake -f components/docker-bake.hcl \
  --set "*.context=." \
  --set "*.platform=linux/arm64" \
  --set "*.args.ROS_DISTRO=humble" \
  --set "common-base-jp62.tags=openadkit-common:base-jp62" \
  common-base-jp62
```

## Progress

### What works (validated 2026-04-13)

- **jp62-setup** (15 steps): All pass. L4T base image bootstrapping, OpenCV 4.8→4.5.4 swap, CMake 3.14→3.22 upgrade, ROS 2 Humble desktop installation from apt, NVIDIA L4T package installation, CUDA environment configuration (CUDAARCHS=87), spconv/cumm Jetson ARM debs.
- **common-base-jp62** (9 steps): All pass. Autoware setup scripts copied, `setup-dev-env.sh --module base --no-nvidia --no-cuda-drivers` completes successfully via ansible.
- **common-devel-jp62** all pre-build steps pass:
  - `setup-dev-env.sh --module all --no-nvidia --no-cuda-drivers` + `--module dev-tools`: Pass.
  - colcon mixin registration: Pass (with retry for GitHub CDN flakiness).
  - rosdep dependency resolution and install: Pass (with retry for GitHub CDN 503s).
- **colcon build**: Blocked on x86 by QEMU bug (see below). **Must be validated on native Jetson.**

### Resolved: cmake 3.22 `find_library` bug (fixed with cmake 3.28)

The colcon build step failed with cmake 3.22 (Ubuntu 22.04 system default):
```
Package 'builtin_interfaces' exports the library
'builtin_interfaces__rosidl_generator_c' which couldn't be found
```

**Root cause (confirmed 2026-04-15):** cmake 3.22's `find_library()` fails when the result variable is pre-set to `"NOTFOUND"`. The `ament_cmake_export_libraries` template does exactly this:
```cmake
set(_lib "NOTFOUND")
find_library(_lib NAMES "${_library}" PATHS "..." NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
```

On cmake 3.22, `find_library` sees `_lib` is "already set" and skips the search, even though the `.so` file exists on disk (confirmed via cmake `if(EXISTS)` and `ls` in the same cmake invocation). This is NOT a QEMU bug — cmake's `find_library` genuinely fails to search.

**Evidence:**
1. cmake `if(EXISTS "/opt/ros/humble/lib/libbuiltin_interfaces__rosidl_generator_c.so")` → YES
2. `find_library(_lib ...)` in the same cmake run → `_lib-NOTFOUND`
3. Upgrading to cmake 3.28 from Kitware PPA → `find_library` succeeds, colcon build passes

**Root cause detail:** The `ament_cmake_export_libraries-extras.cmake` template uses a shared cache variable name `_lib` across ALL packages. When `find_package(A)` processes A's export template and caches `_lib = /path/to/libA.so`, then `find_package(B)`'s template does `set(_lib "NOTFOUND")` + `find_library(_lib ...)`. The `set()` creates a normal variable but does NOT clear the cache entry. `find_library` sees the cache entry is "already set" and skips the search, leaving `_lib` pointing to A's library instead of B's. This is a known ament_cmake design flaw (see [ament_cmake#182](https://github.com/ament/ament_cmake/issues/182), [ament_cmake#365](https://github.com/ament/ament_cmake/issues/365)).

**Fix:** Two-part:
1. Install cmake 3.28 from Kitware APT (3.24+ handles NOTFOUND re-search better). Pinned to 3.28.x: >= 3.24 for find_library fix, < 3.29 for FindPythonLibs compat, < 4.0 for cmake_minimum_required compat.
2. Patch all ament export templates to `unset(_lib CACHE)` before `find_library`, clearing the stale cache entry from previous packages. This is applied via a RUN step in the Dockerfile.

**Also required for building:**
- Build against a pinned Autoware release tag (e.g., `1.7.1`), not `main`. Autoware `main` removed `.env` files referenced by the existing x86 `Dockerfile` COPY. The release workflow (`release-all-images.yaml`) already pins to semver tags.
- `apt-mark manual` for all ROS packages before `cleanup_apt.sh` to prevent `apt-get autoremove` from removing ROS libraries installed as dependencies of `ros-humble-desktop`.

### Remaining work (not yet implemented)

1. **CI workflow** (`build-all-images.yaml`): Add JP62 to the build matrix — new `include:` entries for `jp62` platform in `build-common`, `build-components`, and `build-universe` jobs.
2. **Release workflow** (`release-all-images.yaml`): Same JP62 matrix additions.
3. **Manifest action** (`combine-multi-arch-images/action.yaml`): Handle `jp62` as single-arch (arm64), similar to how `*cuda*` is handled as single-arch (amd64).

## Key design decisions

### `--no-nvidia --no-cuda-drivers` for setup-dev-env.sh

The Autoware ansible `cuda` role detects arm64 as `sbsa` architecture and installs CUDA packages from `developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/sbsa/`. These are server-grade ARM CUDA packages that **conflict** with L4T's pre-installed CUDA from `repo.download.nvidia.com/jetson/`. Using `--no-nvidia` skips both the `cuda` and `tensorrt` ansible roles entirely, relying on the L4T base image for the full NVIDIA stack.

### ros-humble-desktop instead of ros-humble-ros-base

The x86 path starts from the `ros:humble-ros-base-jammy` Docker image (built by OSRF), which includes all ROS message generation libraries as shared objects. Installing `ros-humble-ros-base` via apt on L4T does not produce an identical installation — some development `.so` files are treated as auto-removable. Using `ros-humble-desktop` (which the reference JP62 Dockerfile also uses) provides a superset that includes all required libraries.

### colcon mixin explicit registration

The official `ros:humble-ros-base-jammy` Docker image pre-configures the colcon mixin index. Since JP62 installs ROS from apt on a bare L4T image, the mixin index must be registered explicitly:
```dockerfile
RUN colcon mixin add default https://raw.githubusercontent.com/colcon/colcon-mixin-repository/master/index.yaml; \
    for i in 1 2 3; do colcon mixin update default && break || sleep 10; done
```

### rosdep update retry

GitHub CDN `raw.githubusercontent.com` frequently returns HTTP 503 during Docker builds (parallel requests from buildkit). Both the `jp62-setup` stage and the devel rosdep step use retry logic:
```dockerfile
# Base stage: tolerate failure entirely
RUN rosdep init || true; rosdep update || true

# Devel stage: retry up to 3 times
&& for i in 1 2 3; do rosdep update && break || sleep 10; done
```
