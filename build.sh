#!/bin/bash
set -euo pipefail

# =============================================================================
# lil-clang: Build LLVM/Clang → WebAssembly (wasm32-wasip1)
#
# Cross-compiles a modern LLVM/Clang toolchain into a single .wasm binary
# that can run in the browser via a WASI runtime (Wasmer, Wasmtime, etc.)
#
# Prerequisites: run ./setup.sh first
#
# Host requirements:
#   - macOS (ARM64 or x86_64) or Linux (x86_64)
#   - CMake ≥ 3.20, Ninja, Python 3
#   - ccache (optional, recommended)
#   - ~50 GB disk space, 8+ GB RAM
#
# Usage:
#   ./build.sh          # Full build
#   ./build.sh clean    # Remove all build artifacts
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Use locally-installed CMake if available (wasi-libc requires ≥ 3.26)
if [ -d "$HOME/cmake-3.31.6-linux-x86_64/bin" ]; then
    export PATH="$HOME/cmake-3.31.6-linux-x86_64/bin:$PATH"
fi

# Reproducible builds: use the git commit timestamp
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct 2>/dev/null || date +%s)

# ---------------------------------------------------------------------------
# Handle 'clean' subcommand
# ---------------------------------------------------------------------------
if [ "${1:-}" = "clean" ]; then
    echo "Cleaning all build artifacts..."
    rm -rf wasi-sdk-* llvm-tblgen-build llvm-build compiler-rt-build \
           wasi-libc-build libcxx-build wasi-prefix output \
           Toolchain-WASI.cmake Toolchain-WASI-LLVM.cmake
    echo "Done. (llvm-src/ and wasi-libc-src/ preserved)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Verify setup was run
# ---------------------------------------------------------------------------
if [ ! -d llvm-src ] || [ ! -f llvm-src/llvm/CMakeLists.txt ]; then
    echo "Error: llvm-src not found. Run ./setup.sh first." >&2
    exit 1
fi
if [ ! -d wasi-libc-src ]; then
    echo "Error: wasi-libc-src not found. Run ./setup.sh first." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# wasi-sdk version — the native cross-compiler that outputs wasm32 code.
WASI_VER=32

# Detect host platform
OS="$(uname -s)"
ARCH="$(uname -m)"
if [ "$OS" = "Darwin" ]; then
    if [ "$ARCH" = "arm64" ]; then
        WASI_SDK="wasi-sdk-${WASI_VER}.0-arm64-macos"
    else
        WASI_SDK="wasi-sdk-${WASI_VER}.0-x86_64-macos"
    fi
elif [ "$OS" = "Linux" ]; then
    WASI_SDK="wasi-sdk-${WASI_VER}.0-x86_64-linux"
else
    echo "Unsupported OS: $OS" >&2
    exit 1
fi
WASI_SDK_URL="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_VER}/${WASI_SDK}.tar.gz"

# Parallelism — auto-adjust based on available RAM
TOTAL_RAM_GB=$(
    if [ "$OS" = "Darwin" ]; then
        sysctl -n hw.memsize | awk '{print int($1/1073741824)}'
    else
        awk '/MemTotal/ {print int($2/1048576)}' /proc/meminfo
    fi
)
if [ "$TOTAL_RAM_GB" -le 8 ]; then
    JOBS=4
elif [ "$TOTAL_RAM_GB" -le 16 ]; then
    JOBS=8
else
    JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
fi
echo "Detected ${TOTAL_RAM_GB} GB RAM → using -j${JOBS}"

# Target triple
WASI_TARGET="wasm32-wasip1"

# =============================================================================
# STAGE 0: Download wasi-sdk (the cross-compiler)
# =============================================================================
#
# wasi-sdk is a pre-built Clang that runs natively but outputs wasm32 code.
# We use it to compile LLVM's source into WebAssembly — Clang compiling Clang.
# =============================================================================

echo ""
echo "================================================================"
echo "STAGE 0: Downloading wasi-sdk ${WASI_VER}"
echo "================================================================"

if ! [ -d "${WASI_SDK}" ]; then
    echo "Downloading ${WASI_SDK_URL}..."
    curl -L "${WASI_SDK_URL}" | tar xzf -
else
    echo "wasi-sdk already present, skipping."
fi
WASI_SDK_PATH="${SCRIPT_DIR}/${WASI_SDK}"

# ---------------------------------------------------------------------------
# Compiler and linker flags for cross-compiling to WASM
# ---------------------------------------------------------------------------

# Base flags for sysroot builds (conservative)
WASI_CFLAGS="--sysroot ${WASI_SDK_PATH}/share/wasi-sysroot -mcpu=lime1"
WASI_LDFLAGS="--sysroot ${WASI_SDK_PATH}/share/wasi-sysroot"

# Aggressive flags for building LLVM itself
WASI_CFLAGS_LLVM="${WASI_CFLAGS}"
WASI_LDFLAGS_LLVM="${WASI_LDFLAGS}"

# Stub mmap emulation (LLVM has unreachable mmap calls)
WASI_CFLAGS_LLVM="${WASI_CFLAGS_LLVM} -D_WASI_EMULATED_MMAN"
WASI_LDFLAGS_LLVM="${WASI_LDFLAGS_LLVM} -lwasi-emulated-mman"

# Allow WASM linear memory up to 4 GB (wasm32 max)
WASI_LDFLAGS_LLVM="${WASI_LDFLAGS_LLVM} -Wl,--max-memory=4294967296"

# 8 MB stack (C++ compilation needs lots of stack space)
# --stack-first traps on overflow instead of silently corrupting the heap
WASI_LDFLAGS_LLVM="${WASI_LDFLAGS_LLVM} -Wl,-z,stack-size=8388608,--stack-first"

# LTO: removes dead code (including unreachable WASI thread imports that
# would cause instantiation failures) and shrinks binary ~40%
WASI_CFLAGS_LLVM="${WASI_CFLAGS_LLVM} -flto"
WASI_LDFLAGS_LLVM="${WASI_LDFLAGS_LLVM} -flto -Wl,--strip-all"

# ---------------------------------------------------------------------------
# Generate CMake toolchain files
# ---------------------------------------------------------------------------

cat >Toolchain-WASI.cmake <<END
include(${WASI_SDK_PATH}/share/cmake/wasi-sdk-p1.cmake)
set(CMAKE_C_FLAGS "${WASI_CFLAGS}")
set(CMAKE_CXX_FLAGS "${WASI_CFLAGS}")
set(CMAKE_EXE_LINKER_FLAGS "${WASI_LDFLAGS}")
END

cat >Toolchain-WASI-LLVM.cmake <<END
include(${WASI_SDK_PATH}/share/cmake/wasi-sdk-p1.cmake)
set(CMAKE_C_FLAGS "${WASI_CFLAGS_LLVM}")
set(CMAKE_CXX_FLAGS "${WASI_CFLAGS_LLVM}")
set(CMAKE_EXE_LINKER_FLAGS "${WASI_LDFLAGS_LLVM}")
END

echo "Toolchain files generated."

# =============================================================================
# STAGE 1: Build native TableGen tools
# =============================================================================
#
# TableGen generates C++ from .td files during the build. It must run on the
# HOST (your machine), not the target (WASM). Standard cross-compilation
# pattern: build host tools first, then point the cross-build at them.
# =============================================================================

echo ""
echo "================================================================"
echo "STAGE 1: Building native TableGen tools"
echo "================================================================"

if [ -f llvm-tblgen-build/bin/llvm-tblgen ] && [ -f llvm-tblgen-build/bin/clang-tblgen ]; then
    echo "TableGen tools already built, skipping."
else
    mkdir -p llvm-tblgen-build
    cmake -G Ninja -B llvm-tblgen-build -S llvm-src/llvm \
        -DLLVM_CCACHE_BUILD=ON \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DLLVM_BUILD_RUNTIME=OFF \
        -DLLVM_BUILD_TOOLS=OFF \
        -DLLVM_INCLUDE_UTILS=OFF \
        -DLLVM_INCLUDE_RUNTIMES=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_DOCS=OFF \
        -DLLVM_TARGETS_TO_BUILD=WebAssembly \
        -DLLVM_DEFAULT_TARGET_TRIPLE=${WASI_TARGET} \
        -DLLVM_ENABLE_PROJECTS="clang" \
        -DCLANG_BUILD_EXAMPLES=OFF \
        -DCLANG_BUILD_TOOLS=OFF \
        -DCLANG_INCLUDE_TESTS=OFF
    cmake --build llvm-tblgen-build -j${JOBS} --target llvm-tblgen --target clang-tblgen
    echo "TableGen tools built."
fi

# =============================================================================
# STAGE 2: Cross-compile LLVM + Clang + LLD → WebAssembly
# =============================================================================
#
# The main event. Key decisions:
#
# LLVM_TARGETS_TO_BUILD=WebAssembly
#   Only the WASM backend. Each extra target adds megabytes to the binary.
#
# LLVM_TOOL_LLVM_DRIVER_BUILD=ON
#   Creates a single multicall binary (like BusyBox). One llvm-driver.wasm
#   acts as clang, clang++, lld, llvm-ar, etc. ~23 MB instead of ~100+ MB.
#
# CMAKE_BUILD_TYPE=MinSizeRel
#   Optimize for size. Do NOT use Debug — WASM validation will fail.
#
# LLVM_ENABLE_THREADS=OFF
#   WASI doesn't have pthreads. LLVM works fine single-threaded.
#
# DEFAULT_SYSROOT=/usr
#   Where Clang looks for headers/libs at runtime inside the WASI filesystem.
# =============================================================================

echo ""
echo "================================================================"
echo "STAGE 2: Cross-compiling LLVM/Clang/LLD → WebAssembly"
echo "         (expect 45-90 min on M1/8GB)"
echo "================================================================"

mkdir -p llvm-build
cmake -G Ninja -B llvm-build -S llvm-src/llvm \
    -DCMAKE_TOOLCHAIN_FILE=../Toolchain-WASI-LLVM.cmake \
    -DLLVM_CCACHE_BUILD=ON \
    -DLLVM_NATIVE_TOOL_DIR="$(pwd)/llvm-tblgen-build/bin" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DLLVM_BUILD_SHARED_LIBS=OFF \
    -DLLVM_ENABLE_PIC=OFF \
    -DLLVM_BUILD_STATIC=ON \
    -DLLVM_ENABLE_THREADS=OFF \
    -DLLVM_BUILD_RUNTIME=OFF \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_INCLUDE_UTILS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_INCLUDE_RUNTIMES=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_TARGETS_TO_BUILD=WebAssembly \
    -DLLVM_DEFAULT_TARGET_TRIPLE=${WASI_TARGET} \
    -DLLVM_TOOL_BUGPOINT_BUILD=OFF \
    -DLLVM_TOOL_BUGPOINT_PASSES_BUILD=OFF \
    -DLLVM_TOOL_DSYMUTIL_BUILD=OFF \
    -DLLVM_TOOL_DXIL_DIS_BUILD=OFF \
    -DLLVM_TOOL_GOLD_BUILD=OFF \
    -DLLVM_TOOL_LLC_BUILD=OFF \
    -DLLVM_TOOL_LLI_BUILD=OFF \
    -DLLVM_TOOL_LLVM_AR_BUILD=ON \
    -DLLVM_TOOL_LLVM_AS_BUILD=OFF \
    -DLLVM_TOOL_LLVM_AS_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_BCANALYZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_CAT_BUILD=OFF \
    -DLLVM_TOOL_LLVM_CFI_VERIFY_BUILD=OFF \
    -DLLVM_TOOL_LLVM_CONFIG_BUILD=OFF \
    -DLLVM_TOOL_LLVM_COV_BUILD=OFF \
    -DLLVM_TOOL_LLVM_CVTRES_BUILD=OFF \
    -DLLVM_TOOL_LLVM_CXXDUMP_BUILD=OFF \
    -DLLVM_TOOL_LLVM_CXXFILT_BUILD=ON \
    -DLLVM_TOOL_LLVM_CXXMAP_BUILD=OFF \
    -DLLVM_TOOL_LLVM_C_TEST_BUILD=OFF \
    -DLLVM_TOOL_LLVM_DEBUGINFOD_BUILD=OFF \
    -DLLVM_TOOL_LLVM_DEBUGINFOD_FIND_BUILD=OFF \
    -DLLVM_TOOL_LLVM_DEBUGINFO_ANALYZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_DIFF_BUILD=OFF \
    -DLLVM_TOOL_LLVM_DIS_BUILD=OFF \
    -DLLVM_TOOL_LLVM_DIS_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_DLANG_DEMANGLE_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_DRIVER_BUILD=ON \
    -DLLVM_TOOL_LLVM_DWARFDUMP_BUILD=ON \
    -DLLVM_TOOL_LLVM_DWARFUTIL_BUILD=OFF \
    -DLLVM_TOOL_LLVM_DWP_BUILD=OFF \
    -DLLVM_TOOL_LLVM_EXEGESIS_BUILD=OFF \
    -DLLVM_TOOL_LLVM_EXTRACT_BUILD=OFF \
    -DLLVM_TOOL_LLVM_GSYMUTIL_BUILD=OFF \
    -DLLVM_TOOL_LLVM_IFS_BUILD=OFF \
    -DLLVM_TOOL_LLVM_ISEL_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_ITANIUM_DEMANGLE_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_JITLINK_BUILD=OFF \
    -DLLVM_TOOL_LLVM_JITLISTENER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_LIBTOOL_DARWIN_BUILD=OFF \
    -DLLVM_TOOL_LLVM_LINK_BUILD=OFF \
    -DLLVM_TOOL_LLVM_LIPO_BUILD=OFF \
    -DLLVM_TOOL_LLVM_LTO2_BUILD=OFF \
    -DLLVM_TOOL_LLVM_LTO_BUILD=OFF \
    -DLLVM_TOOL_LLVM_MCA_BUILD=OFF \
    -DLLVM_TOOL_LLVM_MC_ASSEMBLE_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_MC_BUILD=OFF \
    -DLLVM_TOOL_LLVM_MC_DISASSEMBLE_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_MICROSOFT_DEMANGLE_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_ML_BUILD=OFF \
    -DLLVM_TOOL_LLVM_MODEXTRACT_BUILD=OFF \
    -DLLVM_TOOL_LLVM_MT_BUILD=OFF \
    -DLLVM_TOOL_LLVM_NM_BUILD=ON \
    -DLLVM_TOOL_LLVM_OBJCOPY_BUILD=ON \
    -DLLVM_TOOL_LLVM_OBJDUMP_BUILD=ON \
    -DLLVM_TOOL_LLVM_OPT_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_OPT_REPORT_BUILD=OFF \
    -DLLVM_TOOL_LLVM_PDBUTIL_BUILD=OFF \
    -DLLVM_TOOL_LLVM_PROFDATA_BUILD=OFF \
    -DLLVM_TOOL_LLVM_PROFGEN_BUILD=OFF \
    -DLLVM_TOOL_LLVM_RC_BUILD=OFF \
    -DLLVM_TOOL_LLVM_READOBJ_BUILD=ON \
    -DLLVM_TOOL_LLVM_READTAPI_BUILD=OFF \
    -DLLVM_TOOL_LLVM_REDUCE_BUILD=OFF \
    -DLLVM_TOOL_LLVM_REMARKUTIL_BUILD=OFF \
    -DLLVM_TOOL_LLVM_RTDYLD_BUILD=OFF \
    -DLLVM_TOOL_LLVM_RUST_DEMANGLE_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_SHLIB_BUILD=OFF \
    -DLLVM_TOOL_LLVM_SIM_BUILD=OFF \
    -DLLVM_TOOL_LLVM_SIZE_BUILD=ON \
    -DLLVM_TOOL_LLVM_SPECIAL_CASE_LIST_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_SPLIT_BUILD=OFF \
    -DLLVM_TOOL_LLVM_STRESS_BUILD=OFF \
    -DLLVM_TOOL_LLVM_STRINGS_BUILD=OFF \
    -DLLVM_TOOL_LLVM_SYMBOLIZER_BUILD=ON \
    -DLLVM_TOOL_LLVM_TLI_CHECKER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_UNDNAME_BUILD=OFF \
    -DLLVM_TOOL_LLVM_XRAY_BUILD=OFF \
    -DLLVM_TOOL_LLVM_YAML_NUMERIC_PARSER_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LLVM_YAML_PARSER_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_LTO_BUILD=OFF \
    -DLLVM_TOOL_OBJ2YAML_BUILD=OFF \
    -DLLVM_TOOL_OPT_BUILD=OFF \
    -DLLVM_TOOL_OPT_VIEWER_BUILD=OFF \
    -DLLVM_TOOL_REDUCE_CHUNK_LIST_BUILD=OFF \
    -DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF \
    -DLLVM_TOOL_SANCOV_BUILD=OFF \
    -DLLVM_TOOL_SANSTATS_BUILD=OFF \
    -DLLVM_TOOL_SPIRV_TOOLS_BUILD=OFF \
    -DLLVM_TOOL_VERIFY_USELISTORDER_BUILD=OFF \
    -DLLVM_TOOL_VFABI_DEMANGLE_FUZZER_BUILD=OFF \
    -DLLVM_TOOL_XCODE_TOOLCHAIN_BUILD=OFF \
    -DLLVM_TOOL_YAML2OBJ_BUILD=OFF \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DCLANG_ENABLE_OBJC_REWRITER=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DCLANG_BUILD_TOOLS=OFF \
    -DCLANG_TOOL_CLANG_SCAN_DEPS_BUILD=OFF \
    -DCLANG_TOOL_CLANG_INSTALLAPI_BUILD=OFF \
    -DCLANG_BUILD_EXAMPLES=OFF \
    -DCLANG_INCLUDE_DOCS=OFF \
    -DCLANG_LINKS_TO_CREATE="clang;clang++" \
    -DLLD_BUILD_TOOLS=OFF \
    -DCMAKE_INSTALL_PREFIX=llvm-prefix \
    -DDEFAULT_SYSROOT=/usr \
    -DCLANG_RESOURCE_DIR=/usr

# Build only what we need — "all" pulls in too much
cmake --build llvm-build -j${JOBS} --target llvm-driver
cmake --build llvm-build -j${JOBS} --target clang-resource-headers

echo ""
echo "LLVM/Clang/LLD cross-compilation complete!"
ls -lh llvm-build/bin/llvm.wasm 2>/dev/null || echo "(check llvm-build/bin/ for output)"

# =============================================================================
# STAGE 3: Build the sysroot (C/C++ standard libraries)
# =============================================================================
#
# The .wasm binary can parse C/C++ and emit WASM, but needs headers and
# pre-compiled libraries (the "sysroot") to make #include <stdio.h> work.
#
#   3a. compiler-rt  — low-level builtins (64-bit multiply on 32-bit, etc.)
#   3b. wasi-libc    — C standard library (printf, malloc, etc.)
#   3c. libc++       — C++ standard library (std::vector, etc.)
# =============================================================================

echo ""
echo "================================================================"
echo "STAGE 3a: Building compiler-rt builtins"
echo "================================================================"

mkdir -p wasi-prefix/usr/
rm -rf wasi-prefix/usr/include
cp -v -r llvm-build/usr/include wasi-prefix/usr/

mkdir -p compiler-rt-build
cmake -G Ninja -B compiler-rt-build -S llvm-src/compiler-rt \
    -DCMAKE_TOOLCHAIN_FILE=../Toolchain-WASI.cmake \
    -DCOMPILER_RT_BAREMETAL_BUILD=ON \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_INCLUDE_TESTS=OFF \
    -DCOMPILER_RT_HAS_FPIC_FLAG=OFF \
    -DCOMPILER_RT_ENABLE_IOS=OFF \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
    -DCMAKE_INSTALL_PREFIX=wasi-prefix/usr
cmake --build compiler-rt-build -j${JOBS} --target install

echo ""
echo "================================================================"
echo "STAGE 3b: Building wasi-libc"
echo "================================================================"

cmake -G Ninja -B wasi-libc-build -S wasi-libc-src \
    -DCMAKE_C_COMPILER="${WASI_SDK_PATH}/bin/clang" \
    -DCMAKE_AR="${WASI_SDK_PATH}/bin/ar" \
    -DCMAKE_NM="${WASI_SDK_PATH}/bin/nm" \
    -DCMAKE_RANLIB="${WASI_SDK_PATH}/bin/ranlib" \
    -DTARGET_TRIPLE="${WASI_TARGET}" \
    -DBUILTINS_LIB="$(pwd)/wasi-prefix/usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a" \
    -DCMAKE_INSTALL_PREFIX=wasi-prefix/usr
cmake --build wasi-libc-build -j${JOBS} --target install

echo ""
echo "================================================================"
echo "STAGE 3c: Building libc++ and libc++abi"
echo "================================================================"

mkdir -p libcxx-build
cmake -G Ninja -B libcxx-build -S llvm-src/runtimes \
    -DCMAKE_TOOLCHAIN_FILE=../Toolchain-WASI.cmake \
    -DLLVM_ENABLE_RUNTIMES:STRING="libcxx;libcxxabi" \
    -DLIBCXX_ENABLE_THREADS:BOOL=ON \
    -DLIBCXX_BUILD_EXTERNAL_THREAD_LIBRARY:BOOL=ON \
    -DLIBCXX_ENABLE_SHARED:BOOL=OFF \
    -DLIBCXX_ENABLE_EXCEPTIONS:BOOL=OFF \
    -DLIBCXX_ENABLE_FILESYSTEM:BOOL=ON \
    -DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY:BOOL=OFF \
    -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT:BOOL=OFF \
    -DLIBCXX_CXX_ABI=libcxxabi \
    -DLIBCXX_CXX_ABI_INCLUDE_PATHS="$(pwd)/llvm-src/libcxxabi/include" \
    -DLIBCXX_HAS_MUSL_LIBC:BOOL=ON \
    -DLIBCXX_ABI_VERSION=2 \
    -DLIBCXXABI_ENABLE_THREADS:BOOL=ON \
    -DLIBCXXABI_BUILD_EXTERNAL_THREAD_LIBRARY:BOOL=ON \
    -DLIBCXXABI_ENABLE_PIC:BOOL=OFF \
    -DLIBCXXABI_ENABLE_SHARED:BOOL=OFF \
    -DLIBCXXABI_ENABLE_EXCEPTIONS:BOOL=OFF \
    -DLIBCXXABI_USE_LLVM_UNWINDER:BOOL=OFF \
    -DLIBCXXABI_SILENT_TERMINATE:BOOL=ON \
    -DLIBCXX_LIBDIR_SUFFIX="/${WASI_TARGET}" \
    -DLIBCXXABI_LIBDIR_SUFFIX="/${WASI_TARGET}" \
    -DCMAKE_INSTALL_PREFIX=wasi-prefix/usr
cmake --build libcxx-build -j${JOBS} --target install

# =============================================================================
# STAGE 4: Package outputs
# =============================================================================

echo ""
echo "================================================================"
echo "STAGE 4: Packaging outputs"
echo "================================================================"

OUTPUT_DIR="${SCRIPT_DIR}/output"
mkdir -p "${OUTPUT_DIR}"

if [ -f llvm-build/bin/llvm.wasm ]; then
    cp llvm-build/bin/llvm.wasm "${OUTPUT_DIR}/clang.wasm"
    echo "Clang binary: ${OUTPUT_DIR}/clang.wasm ($(du -h "${OUTPUT_DIR}/clang.wasm" | cut -f1))"
fi

tar czf "${OUTPUT_DIR}/sysroot.tar.gz" -C wasi-prefix .
echo "Sysroot:      ${OUTPUT_DIR}/sysroot.tar.gz ($(du -h "${OUTPUT_DIR}/sysroot.tar.gz" | cut -f1))"

echo ""
echo "================================================================"
echo "BUILD COMPLETE!"
echo ""
echo "Outputs in: ${OUTPUT_DIR}/"
echo "  clang.wasm     — multicall LLVM binary (~23 MB)"
echo "                   acts as: clang, clang++, lld, llvm-ar, etc."
echo "  sysroot.tar.gz — C/C++ headers and libraries"
echo ""
echo "Usage with Wasmer:"
echo "  wasmer run --mapdir /usr::./sysroot clang.wasm -- hello.c -o hello.wasm"
echo "================================================================"
