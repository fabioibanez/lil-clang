# lil-clang

Compile LLVM/Clang into a single `.wasm` binary that runs in the browser via Wasmer (or any WASI runtime).

## Quick start

```bash
./setup.sh   # install deps, clone LLVM 20, apply WASI patches (~500 MB download)
./build.sh   # cross-compile everything (~45-90 min on M1, 8 GB RAM)
```

## Output

After building, `output/` contains:

- **`clang.wasm`** (~73 MB) — multicall LLVM binary that acts as clang, clang++, lld, llvm-ar, llvm-nm, etc.
- **`sysroot.tar.gz`** — C/C++ headers and libraries to mount in the WASI virtual filesystem

## Usage

```bash
# Run with Wasmer
wasmer run --mapdir /usr::./sysroot clang.wasm -- hello.c -o hello.wasm

# Run with Wasmtime
wasmtime --dir /usr::./sysroot clang.wasm -- hello.c -o hello.wasm
```

In the browser, use Wasmer-JS or a similar WASI runtime to instantiate `clang.wasm` with the sysroot mounted at `/usr`.

## Why patches are needed

Upstream LLVM calls POSIX APIs that don't exist in WASI Preview 1:

- **Signals** (`signal()`, `raise()`, `alarm()`) — WASI has no signal delivery
- **Process spawning** (`fork()`, `exec()`, `posix_spawn()`) — WASI is single-process
- **Process identity** (`getpid()`) — no process IDs in WASI
- **File metadata** (`umask()`, `fchown()`) — limited file permission model
- **Password database** (`getpwnam_r()`) — no user accounts

For now, we are using the patched [`llvm-src`](https://github.com/YoWASP/llvm-project/tree/97196c8eeb1d495fa43bb8af2fb26af5ef5b89fb) maintained by [whitequark] (https://github.com/whitequark)

Once upstream merges these changes, the patches become unnecessary. There is an open [patch](https://github.com/llvm/llvm-project/pull/92677) for this.

## Cleaning up

```bash
./build.sh clean   # removes build artifacts (~40 GB), preserves source
rm -rf llvm-src wasi-libc-src   # remove source clones too
```