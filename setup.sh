#!/bin/bash
set -euo pipefail

# =============================================================================
# lil-clang setup: install prerequisites, clone LLVM 20, and apply WASI patches
#
# Run this ONCE before running build.sh. It:
#   1. Checks/installs build dependencies (cmake, ninja, python3)
#   2. Clones upstream LLVM 20 from the official repository
#   3. Applies WASI compatibility patches (no third-party forks needed)
#   4. Clones wasi-libc source
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OS="$(uname -s)"

# LLVM release to target. Change this to update LLVM version.
LLVM_RELEASE_TAG="llvmorg-20.1.0"
LLVM_BRANCH="release/20.x"

echo "================================================================"
echo "lil-clang setup"
echo "================================================================"
echo ""
echo "This will set up everything needed to build Clang as a .wasm file."
echo "LLVM version: ${LLVM_RELEASE_TAG}"
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
echo ""
echo "This is a shallow clone (~500 MB) of the official LLVM monorepo."
echo "We clone upstream directly — no third-party forks."
echo ""

if [ -d llvm-src ] && [ -f llvm-src/llvm/CMakeLists.txt ]; then
    echo "llvm-src already exists, skipping clone."
else
    git clone --depth 1 --branch "${LLVM_RELEASE_TAG}" \
        https://github.com/llvm/llvm-project.git llvm-src
    echo "Cloned LLVM ${LLVM_RELEASE_TAG}"
fi

# Show LLVM version
if [ -f llvm-src/cmake/Modules/LLVMVersion.cmake ]; then
    LLVM_VER=$(grep 'LLVM_VERSION_MAJOR' llvm-src/cmake/Modules/LLVMVersion.cmake | head -1 | grep -o '[0-9]*')
    echo "LLVM major version: ${LLVM_VER}"
fi

# ---------------------------------------------------------------------------
# Step 3: Apply WASI compatibility patches
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "Step 3: Applying WASI compatibility patches"
echo "================================================================"
echo ""
echo "Upstream LLVM uses POSIX APIs (signals, fork, exec, etc.) that"
echo "don't exist in WASI. We apply targeted patches to stub these out."
echo ""
echo "See patches/apply-wasi-compat.py for details on each modification."
echo "Based on work from the LLVM RFC for WebAssembly self-hosting:"
echo "  https://discourse.llvm.org/t/rfc-building-llvm-for-webassembly/79073"
echo ""

python3 "${SCRIPT_DIR}/patches/apply-wasi-compat.py" llvm-src

# Tag the patched state so we can verify/diff later
cd llvm-src
git add -A
git -c user.email="lil-clang@local" -c user.name="lil-clang" \
    commit -m "Apply WASI compatibility patches (lil-clang)" --allow-empty 2>/dev/null || true
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Step 4: Clone wasi-libc source
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "Step 4: Cloning wasi-libc source"
echo "================================================================"
echo ""
echo "wasi-libc is the C standard library for WASI (based on musl)."
echo "It provides printf, malloc, file I/O, etc."
echo ""

if [ -d wasi-libc-src ] && [ -f wasi-libc-src/Makefile ]; then
    echo "wasi-libc-src already exists, skipping clone."
else
    git clone --depth 1 https://github.com/WebAssembly/wasi-libc.git wasi-libc-src
    echo "Cloned wasi-libc."
fi

echo ""
echo "================================================================"
echo "Setup complete! Now run:"
echo "  ./build.sh"
echo ""
echo "Expected build time: ~45-90 min on Apple M1 (8 GB RAM)"
echo "Disk space needed:   ~50 GB"
echo "================================================================"
