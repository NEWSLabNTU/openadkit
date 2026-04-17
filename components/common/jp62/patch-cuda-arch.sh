#!/usr/bin/env bash
# patch-cuda-arch.sh — Gate CUDA compute_101+ gencode flags behind CUDA >= 12.8
#
# Autoware 1.7.1 hardcodes -gencode arch=compute_101 and compute_120 in 14
# CMakeLists.txt files. These architectures require CUDA 12.8+ (Blackwell),
# but JP62 provides CUDA 12.6 which only supports up to compute_90.
#
# This script wraps the compute_101/110/120 flags in a CUDA version check so
# they are only added when the toolkit supports them.
#
# Usage:
#   ./components/common/jp62/patch-cuda-arch.sh <autoware-src-dir>
#
# Example:
#   ./components/common/jp62/patch-cuda-arch.sh autoware/src

set -euo pipefail

SRC_DIR="${1:?Usage: $0 <autoware-src-dir>}"

if [ ! -d "$SRC_DIR" ]; then
  echo "Error: directory '$SRC_DIR' does not exist" >&2
  exit 1
fi

# Find all CMakeLists.txt files that reference compute_101
FILES=$(grep -rl "compute_101" "$SRC_DIR" --include="CMakeLists.txt" || true)

if [ -z "$FILES" ]; then
  echo "No files with compute_101 found in $SRC_DIR — nothing to patch."
  exit 0
fi

PATCHED=0
SKIPPED=0

for f in $FILES; do
  # Skip already-patched files
  if grep -q "VERSION_GREATER_EQUAL.*12.8" "$f" 2>/dev/null; then
    echo "SKIP (already patched): $f"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  python3 -c "
import re, sys

with open('$f', 'r') as fh:
    content = fh.read()

# Match the block with quoted gencode args (2-space indent)
patterns = [
    # Pattern 1: 2-space indent, quoted args (most common)
    (r'  if\(CUDA_VERSION VERSION_LESS \"13\.0\"\)\n'
     r'    list\(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_101,code=sm_101\"\)\n'
     r'  else\(\)  # CUDA 13\.0 renamed SM101 to SM110\n'
     r'    list\(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_110,code=sm_110\"\)\n'
     r'  endif\(\)\n'
     r'  list\(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_120,code=sm_120\"\)\n'
     r'  list\(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_120,code=compute_120\"\)',
     '  # Only add newer architectures if the CUDA toolkit actually supports them\n'
     '  if(CUDA_VERSION VERSION_GREATER_EQUAL \"12.8\")\n'
     '    if(CUDA_VERSION VERSION_LESS \"13.0\")\n'
     '      list(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_101,code=sm_101\")\n'
     '    else()  # CUDA 13.0 renamed SM101 to SM110\n'
     '      list(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_110,code=sm_110\")\n'
     '    endif()\n'
     '    list(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_120,code=sm_120\")\n'
     '    list(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_120,code=compute_120\")\n'
     '  endif()'),
    # Pattern 2: no indent, quoted args
    (r'if\(CUDA_VERSION VERSION_LESS \"13\.0\"\)\n'
     r'  list\(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_101,code=sm_101\"\)\n'
     r'else\(\)  # CUDA 13\.0 renamed SM101 to SM110\n'
     r'  list\(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_110,code=sm_110\"\)\n'
     r'endif\(\)\n'
     r'list\(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_120,code=sm_120\"\)\n'
     r'list\(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_120,code=compute_120\"\)',
     '# Only add newer architectures if the CUDA toolkit actually supports them\n'
     'if(CUDA_VERSION VERSION_GREATER_EQUAL \"12.8\")\n'
     '  if(CUDA_VERSION VERSION_LESS \"13.0\")\n'
     '    list(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_101,code=sm_101\")\n'
     '  else()  # CUDA 13.0 renamed SM101 to SM110\n'
     '    list(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_110,code=sm_110\")\n'
     '  endif()\n'
     '  list(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_120,code=sm_120\")\n'
     '  list(APPEND CUDA_NVCC_FLAGS \"-gencode arch=compute_120,code=compute_120\")\n'
     'endif()'),
    # Pattern 3: 4-space indent, unquoted args
    (r'  if\(CUDA_VERSION VERSION_LESS \"13\.0\"\)\n'
     r'    list\(APPEND CUDA_NVCC_FLAGS -gencode arch=compute_101,code=sm_101\)\n'
     r'  else\(\)  # CUDA 13\.0 renamed SM101 to SM110\n'
     r'    list\(APPEND CUDA_NVCC_FLAGS -gencode arch=compute_110,code=sm_110\)\n'
     r'  endif\(\)\n'
     r'  list\(APPEND CUDA_NVCC_FLAGS -gencode arch=compute_120,code=sm_120\)\n'
     r'  list\(APPEND CUDA_NVCC_FLAGS -gencode arch=compute_120,code=compute_120\)',
     '  # Only add newer architectures if the CUDA toolkit actually supports them\n'
     '  if(CUDA_VERSION VERSION_GREATER_EQUAL \"12.8\")\n'
     '    if(CUDA_VERSION VERSION_LESS \"13.0\")\n'
     '      list(APPEND CUDA_NVCC_FLAGS -gencode arch=compute_101,code=sm_101)\n'
     '    else()  # CUDA 13.0 renamed SM101 to SM110\n'
     '      list(APPEND CUDA_NVCC_FLAGS -gencode arch=compute_110,code=sm_110)\n'
     '    endif()\n'
     '    list(APPEND CUDA_NVCC_FLAGS -gencode arch=compute_120,code=sm_120)\n'
     '    list(APPEND CUDA_NVCC_FLAGS -gencode arch=compute_120,code=compute_120)\n'
     '  endif()'),
]

for old_pat, new_str in patterns:
    result = re.sub(old_pat, new_str, content)
    if result != content:
        with open('$f', 'w') as fh:
            fh.write(result)
        print('PATCHED: $f')
        sys.exit(0)

print('NO MATCH: $f (may need manual patching)', file=sys.stderr)
sys.exit(1)
" && PATCHED=$((PATCHED + 1)) || {
    echo "WARNING: Failed to patch $f — check manually" >&2
  }
done

echo ""
echo "Done: $PATCHED patched, $SKIPPED skipped (already patched)."
echo "Total files with compute_101: $(echo "$FILES" | wc -l)"
