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

### What works (validated 2026-04-09)

- **jp62-setup** (15 steps): All pass. L4T base image bootstrapping, OpenCV 4.8→4.5.4 swap, CMake 3.14→3.22 upgrade, ROS 2 Humble desktop installation from apt, NVIDIA L4T package installation, CUDA environment configuration (CUDAARCHS=87), spconv/cumm Jetson ARM debs.
- **common-base-jp62** (9 steps): All pass. Autoware setup scripts copied, `setup-dev-env.sh --module base --no-nvidia --no-cuda-drivers` completes successfully via ansible.
- **common-devel-jp62** partial:
  - `setup-dev-env.sh --module all --no-nvidia --no-cuda-drivers` + `--module dev-tools`: Pass. Ansible roles complete including acados (blasfeo arm64 assembly builds under QEMU with `POCF` binfmt flags).
  - colcon mixin registration: Pass (with retry for GitHub CDN flakiness).
  - rosdep dependency resolution and install: Pass (with retry for GitHub CDN 503s).

### Blocker: colcon build — `builtin_interfaces` cmake error

The final colcon build step (`build_and_clean.sh`) fails with:

```
Package 'builtin_interfaces' exports the library
'builtin_interfaces__rosidl_generator_c' which couldn't be found
```

**Root cause analysis:**
- The `.so` file exists at `/opt/ros/humble/lib/libbuiltin_interfaces__rosidl_generator_c.so` (verified: valid ELF 64-bit ARM aarch64).
- CMake `find_library` in script mode (`cmake -P`) finds it correctly.
- CMake `find_library` within a colcon project context fails — the ament cmake export macro cannot locate the library despite it being at the expected path.
- This is **not JP62-specific**: the existing x86 `components/common/Dockerfile` also cannot build against current Autoware `main` (fails earlier on missing `autoware/amd64.env` files that were removed upstream). Even if that COPY were fixed, the same colcon build issue would likely surface.

**Likely resolution:** Pin the Autoware checkout to a specific release tag (e.g., the release the CI last built successfully against) rather than `main`. The x86 CI presumably builds against a known-good Autoware ref.

### Remaining work (not yet implemented)

1. **CI workflow** (`build-all-images.yaml`): Add JP62 to the build matrix — new `include:` entries for `jp62` platform in `build-common`, `build-components`, and `build-universe` jobs.
2. **Release workflow** (`release-all-images.yaml`): Same JP62 matrix additions.
3. **Manifest action** (`combine-multi-arch-images/action.yaml`): Handle `jp62` as single-arch (arm64), similar to how `*cuda*` is handled as single-arch (amd64).
4. **Pin Autoware ref**: Determine the correct Autoware release tag for JP62 builds and resolve the colcon `builtin_interfaces` issue.

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
