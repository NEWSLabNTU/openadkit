# Jetson Linux 6.2 (JP62) Base Layer

## Overview

This directory contains the JP62-specific files for building Autoware common images on NVIDIA Jetson Orin (JetPack 6.2). The corresponding Dockerfile is at `components/common/Dockerfile.jp62`.

JP62 images fulfill the same contract as x86 CUDA images (`common-base-cuda` / `common-devel-cuda`), so downstream component `Dockerfile.cuda` files work unmodified — they simply receive JP62 images as their `COMMON_BASE_CUDA_IMAGE` / `COMMON_DEVEL_CUDA_IMAGE` build args.

## Files

| File | Purpose |
|------|---------|
| `../Dockerfile.jp62` | Multi-stage Dockerfile: `jp62-setup` → `common-base-jp62` → `common-devel-jp62` |
| `opencv-preferences` | APT pin to prefer Ubuntu OpenCV 4.5.4 over L4T's 4.8.0 |
| `patch-cuda-arch.sh` | Patches Autoware CMakeLists.txt files to gate unsupported CUDA architectures (see below) |

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

### Resolved: `nvcc fatal: Unsupported gpu architecture 'compute_101'` (Autoware 1.7.1)

Autoware 1.7.1 hardcodes `CUDA_NVCC_FLAGS` with `-gencode arch=compute_101,code=sm_101` and `compute_120` in 14 CMakeLists.txt files across perception, sensing, and e2e packages. These architectures require CUDA 12.8+ (Blackwell), but the JP62 L4T base provides CUDA 12.6 which only supports up to `compute_90` (Hopper).

The `CUDAARCHS=87` env var set in `Dockerfile.jp62` controls CMake's `CMAKE_CUDA_ARCHITECTURES`, but the affected packages use the legacy `find_package(CUDA)` / `cuda_add_library()` path with `CUDA_NVCC_FLAGS` directly — bypassing `CMAKE_CUDA_ARCHITECTURES` entirely.

**Fix:** Gate the `compute_101`+ gencode flags behind `CUDA_VERSION VERSION_GREATER_EQUAL "12.8"` so they are only added when the toolkit actually supports them. The existing `compute_86/87/89` flags remain unconditional.

Before (upstream):
```cmake
list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_86,code=sm_86")
list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_87,code=sm_87")
list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_89,code=sm_89")
if(CUDA_VERSION VERSION_LESS "13.0")
  list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_101,code=sm_101")
else()  # CUDA 13.0 renamed SM101 to SM110
  list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_110,code=sm_110")
endif()
list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_120,code=sm_120")
list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_120,code=compute_120")
```

After (patched):
```cmake
list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_86,code=sm_86")
list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_87,code=sm_87")
list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_89,code=sm_89")
# Only add newer architectures if the CUDA toolkit actually supports them
if(CUDA_VERSION VERSION_GREATER_EQUAL "12.8")
  if(CUDA_VERSION VERSION_LESS "13.0")
    list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_101,code=sm_101")
  else()  # CUDA 13.0 renamed SM101 to SM110
    list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_110,code=sm_110")
  endif()
  list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_120,code=sm_120")
  list(APPEND CUDA_NVCC_FLAGS "-gencode arch=compute_120,code=compute_120")
endif()
```

**Affected packages (14 files):**
- `universe/autoware_universe/e2e/autoware_tensorrt_vad`
- `universe/autoware_universe/perception/autoware_bevfusion`
- `universe/autoware_universe/perception/autoware_ground_segmentation_cuda`
- `universe/autoware_universe/perception/autoware_image_projection_based_fusion`
- `universe/autoware_universe/perception/autoware_lidar_centerpoint`
- `universe/autoware_universe/perception/autoware_lidar_frnet`
- `universe/autoware_universe/perception/autoware_lidar_transfusion`
- `universe/autoware_universe/perception/autoware_probabilistic_occupancy_grid_map`
- `universe/autoware_universe/perception/autoware_ptv3`
- `universe/autoware_universe/perception/autoware_tensorrt_classifier`
- `universe/autoware_universe/perception/autoware_tensorrt_plugins`
- `universe/autoware_universe/perception/autoware_tensorrt_yolox`
- `universe/autoware_universe/sensing/autoware_calibration_status_classifier`
- `universe/autoware_universe/sensing/autoware_cuda_pointcloud_preprocessor`

**Applying the patch:** Run `components/common/jp62/patch-cuda-arch.sh` after cloning Autoware sources and before building:
```bash
./components/common/jp62/patch-cuda-arch.sh autoware/src
```

This patch is only needed for CUDA < 12.8 (i.e., JP62 with CUDA 12.6). On x86 with CUDA 12.8+ the upstream CMakeLists.txt files work as-is.

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
