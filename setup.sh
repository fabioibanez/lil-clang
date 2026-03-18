#!/bin/bash
set -euo pipefail

# =============================================================================
# lil-clang setup: install prerequisites, clone LLVM (WASI-patched), clone wasi-libc
#
# Run this ONCE before running build.sh. It:
#   1. Checks/installs build dependencies (cmake, ninja, python3)
#   2. Clones WASI-patched LLVM 22 from YoWASP/llvm-project
#   3. Clones wasi-libc source
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OS="$(uname -s)"

LLVM_REPO="https://github.com/YoWASP/llvm-project.git"
LLVM_BRANCH="llvmorg-22.1.0+wasm"

echo "================================================================"
echo "lil-clang setup"
echo "================================================================"
echo ""
echo "This will clone LLVM (${LLVM_BRANCH}) with WASI patches and wasi-libc."
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
# Step 2: Clone WASI-patched LLVM
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "Step 2: Cloning LLVM (${LLVM_BRANCH}, WASI-patched)"
echo "================================================================"

if [ -d llvm-src ] && [ -f llvm-src/llvm/CMakeLists.txt ]; then
    echo "llvm-src already exists, skipping clone."
else
    git clone --depth 1 --branch "${LLVM_BRANCH}" \
        "${LLVM_REPO}" llvm-src
    echo "Cloned LLVM ${LLVM_BRANCH}."
fi

if [ -f llvm-src/cmake/Modules/LLVMVersion.cmake ]; then
    LLVM_VER=$(grep 'set(LLVM_VERSION_MAJOR' llvm-src/cmake/Modules/LLVMVersion.cmake | head -1 | grep -o '[0-9]*')
    echo "LLVM major version: ${LLVM_VER}"
fi

# ---------------------------------------------------------------------------
# Step 3: Clone wasi-libc source
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "Step 3: Cloning wasi-libc"
echo "================================================================"

if [ -d wasi-libc-src ] && [ -f wasi-libc-src/CMakeLists.txt ]; then
    echo "wasi-libc-src already exists, skipping clone."
else
    git clone --depth 1 https://github.com/WebAssembly/wasi-libc.git wasi-libc-src
    echo "Cloned wasi-libc."
fi

echo ""
echo "================================================================"
echo "Setup complete! WASI patches are already applied in the cloned repo."
echo ""
echo "Run:"
echo "  ./build.sh"
echo ""
echo "Disk space needed:   ~50 GB"
echo "================================================================"
