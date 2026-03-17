#!/bin/bash
set -euo pipefail

# =============================================================================
# lil-clang setup: install prerequisites, clone upstream LLVM, clone wasi-libc
#
# Run this ONCE before running build.sh. It:
#   1. Checks/installs build dependencies (cmake, ninja, python3)
#   2. Clones upstream LLVM 20 from the official repo
#   3. Clones wasi-libc source
#
# After running this, you need to manually apply WASI compatibility patches
# to llvm-src/ before building. See PATCHING.md for a file-by-file guide.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OS="$(uname -s)"

LLVM_RELEASE_TAG="llvmorg-20.1.0"

echo "================================================================"
echo "lil-clang setup"
echo "================================================================"
echo ""
echo "This will clone upstream LLVM ${LLVM_RELEASE_TAG} and wasi-libc."
echo ""
echo "After setup, you must manually patch llvm-src/ for WASI."
echo "See PATCHING.md for exactly what to change."
echo ""

# ---------------------------------------------------------------------------
# Step 1: Check build dependencies
# ---------------------------------------------------------------------------
echo "================================================================"
echo "Step 1: Checking build dependencies"
echo "================================================================"

MISSING=()

command -v cmake   >/dev/null 2>&1 || MISSING+=(cmake)
command -v ninja   >/dev/null 2>&1 || MISSING+=(ninja)
command -v python3 >/dev/null 2>&1 || MISSING+=(python3)

if ! command -v ccache >/dev/null 2>&1; then
    echo "NOTE: ccache not found. Builds will work but be slower on rebuilds."
    echo "      Install with: brew install ccache (macOS) or apt install ccache (Linux)"
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Missing required tools: ${MISSING[*]}"
    if [ "$OS" = "Darwin" ]; then
        echo "Installing via Homebrew..."
        brew install "${MISSING[@]}"
    elif [ "$OS" = "Linux" ]; then
        echo "Installing via apt..."
        sudo apt-get update && sudo apt-get install -y "${MISSING[@]}"
    else
        echo "Please install: ${MISSING[*]}" >&2
        exit 1
    fi
else
    echo "All required tools found."
fi

# ---------------------------------------------------------------------------
# Step 2: Clone upstream LLVM
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "Step 2: Cloning upstream LLVM ${LLVM_RELEASE_TAG}"
echo "================================================================"

if [ -d llvm-src ] && [ -f llvm-src/llvm/CMakeLists.txt ]; then
    echo "llvm-src already exists, skipping clone."
else
    git clone --depth 1 --branch "${LLVM_RELEASE_TAG}" \
        https://github.com/llvm/llvm-project.git llvm-src
    echo "Cloned LLVM ${LLVM_RELEASE_TAG}."
fi

if [ -f llvm-src/cmake/Modules/LLVMVersion.cmake ]; then
    LLVM_VER=$(grep 'LLVM_VERSION_MAJOR' llvm-src/cmake/Modules/LLVMVersion.cmake | head -1 | grep -o '[0-9]*')
    echo "LLVM major version: ${LLVM_VER}"
fi

# ---------------------------------------------------------------------------
# Step 3: Clone wasi-libc source
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "Step 3: Cloning wasi-libc"
echo "================================================================"

if [ -d wasi-libc-src ] && [ -f wasi-libc-src/Makefile ]; then
    echo "wasi-libc-src already exists, skipping clone."
else
    git clone --depth 1 https://github.com/WebAssembly/wasi-libc.git wasi-libc-src
    echo "Cloned wasi-libc."
fi

echo ""
echo "================================================================"
echo "Setup complete!"
echo ""
echo "Run:"
echo "  ./build.sh"
echo ""
echo "Expected build time: ~45-90 min on Apple M1 (8 GB RAM)"
echo "Disk space needed:   ~50 GB"
echo "================================================================"
