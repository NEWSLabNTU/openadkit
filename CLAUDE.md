# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Open AD Kit provides containerized, microservice-based components for the [Autoware](https://github.com/autowarefoundation/autoware) autonomous driving stack. It packages Autoware into independent Docker images for modular deployment across cloud and edge (amd64/arm64). This is a SOAFEE Blueprint project under the Autoware Foundation.

## Build Commands

### Build container images (requires Docker buildx)

```bash
# Build all component images (default target) for current platform, ROS Humble
./build.sh

# Build options
./build.sh --platform linux/arm64        # Cross-build for ARM
./build.sh --platform jp62              # Jetson Linux 6.2 (arm64, CUDA always included)
./build.sh --ros-distro jazzy            # Use ROS Jazzy (default: humble)
./build.sh --no-cuda                     # Skip CUDA image variants
./build.sh --target common               # Build only base images (stage 1)
./build.sh --target components           # Build components (stages 1+2, default)
./build.sh --target universe             # Build everything (stages 1+2+3)
```

The build script first clones the Autoware repo and imports source via `vcs`, then runs `docker buildx bake` through three stages.

### Setup runtime environment

```bash
./setup.sh  # Installs Docker, NVIDIA Container Toolkit
```

### Documentation (MkDocs)

```bash
make prepare  # Build the MkDocs dev container
make serve    # Serve docs locally at localhost:8000
make build    # Build static site
make clean    # Remove site/ directory
```

## Architecture

### Three-stage image hierarchy

The build produces layered Docker images defined in `components/docker-bake.hcl`:

1. **Common** (`components/common/`): Base and devel images built on top of ROS. Each has a CUDA variant and a JP62 variant.
   - `common-base` / `common-base-cuda` / `common-base-jp62` — runtime base
   - `common-devel` / `common-devel-cuda` / `common-devel-jp62` — build-time with Autoware dependencies
2. **Components** (7 independent images): Each built from `common-devel`, installed onto `common-base`. Each has its own Dockerfile under `components/<name>/`:
   - `sensing-perception` (has CUDA variant), `localization-mapping`, `planning-control`, `vehicle-system`, `api`, `visualizer`, `simulator`
3. **Universe** (`components/universe/`): Merges all component install spaces into a single image. Has a CUDA variant.

### Platform variants

The image matrix spans `{platform} x {ros-distro}`:

| Platform       | Arch        | CUDA     | Base image                                  | Dockerfile                 |
|----------------|-------------|----------|---------------------------------------------|----------------------------|
| `amd64`        | linux/amd64 | optional | `ros:{distro}-ros-base-{ubuntu}`            | `Dockerfile`               |
| `arm64`        | linux/arm64 | no       | `ros:{distro}-ros-base-{ubuntu}`            | `Dockerfile`               |
| `amd64` + cuda | linux/amd64 | yes      | `ros:{distro}-ros-base-{ubuntu}`            | `Dockerfile` (cuda stages) |
| `jp62`         | linux/arm64 | always   | `nvcr.io/nvidia/l4t-tensorrt:r10.3.0-devel` | `Dockerfile.jp62`          |

JP62 images fulfill the same contract as CUDA images (`common-base-cuda` / `common-devel-cuda`), so downstream `Dockerfile.cuda` component files work unmodified by receiving JP62 images as their `COMMON_BASE_CUDA_IMAGE` / `COMMON_DEVEL_CUDA_IMAGE` args.

**JP62-specific concerns** (`components/common/Dockerfile.jp62`):
- L4T base has no ROS — installed from apt (`ros-humble-desktop`)
- L4T OpenCV 4.8.0 replaced with Ubuntu 4.5.4 (apt pin in `components/common/jp62/opencv-preferences`)
- L4T CMake 3.14 replaced with system CMake >= 3.22
- NVIDIA packages from L4T repos (not `ubuntu2204/sbsa`) — `setup-dev-env.sh` must use `--no-nvidia --no-cuda-drivers` to avoid conflicts
- `CUDAARCHS=87` (Orin) set to avoid native detection failures under QEMU
- spconv/cumm installed from pre-built Jetson ARM `.deb` packages
- colcon mixin index must be explicitly registered (not inherited from ros: Docker base image)

### Deployment samples

- `deployments/samples/planning-simulation/` — planning stack with AWSIM simulator
- `deployments/samples/logging-simulation/` — end-to-end replay with rosbag
- `deployments/demos/zenoh-bridge/` — remote visualization via Zenoh bridge

### Platform configurations

- `platforms/autosd/` — Automotive-grade Linux (CentOS Stream AutoSD)

### Tag scheme

CI tags images as `{variant}-{platform}-{distro}[-{date}]`:
- `base-amd64-humble`, `devel-cuda-amd64-humble`, `base-jp62-humble`
- Component/universe: `sensing-perception-amd64-humble`, `universe-jp62-humble`

Multi-arch manifests (amd64+arm64) strip the platform: `base-humble-{date}`. CUDA and JP62 images are single-arch.

## CI/CD

GitHub Actions workflows in `.github/workflows/`:

- **build-all-images.yaml**: Main CI. Builds all images for amd64+arm64, humble+jazzy. Triggered on push to main, monthly schedule, or manual dispatch. Pushes to `ghcr.io`.
- **release-all-images.yaml**: Runs every 6 hours. Detects latest Autoware release tag and publishes versioned images.
- **deploy-docs.yaml**: Builds and deploys MkDocs site to GitHub Pages on push to main.
- **semantic-pull-request.yaml**: Enforces conventional commit style on PR titles.

## Key Conventions

- Image registry: `ghcr.io/autowarefoundation/openadkit`
- ROS distributions: `humble` (Ubuntu Jammy) and `jazzy` (Ubuntu Noble)
- PR titles must follow [Conventional Commits](https://www.conventionalcommits.org/) (enforced by CI)
- The `autoware/` directory is git-ignored — it's cloned at build time by `build.sh`
- No unit test suite; validation happens through Docker build success in CI
