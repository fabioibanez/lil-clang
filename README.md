# lil-clang

Compile LLVM/Clang into a single `.wasm` binary that runs in the browser via Wasmer (or any WASI runtime).

**No third-party forks.** Uses upstream LLVM 20 with a small, auditable patch set for WASI compatibility.

## Quick start

```bash
./setup.sh   # install deps, clone LLVM 20, apply WASI patches (~500 MB download)
./build.sh   # cross-compile everything (~45-90 min on M1, 8 GB RAM)
```

## Output

After building, `output/` contains:

- **`clang.wasm`** (~23 MB) — multicall LLVM binary that acts as clang, clang++, lld, llvm-ar, llvm-nm, etc.
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

The patch script (`patches/apply-wasi-compat.py`) wraps these calls in `#if !defined(__wasi__)` guards and provides stub implementations. This is the same approach used by the [LLVM RFC for WebAssembly self-hosting](https://discourse.llvm.org/t/rfc-building-llvm-for-webassembly/79073) (PR #92677), which has been proposed but not yet merged upstream.

Once upstream merges these changes, the patches become unnecessary.

## Requirements

- macOS (ARM64 or x86_64) or Linux x86_64
- CMake >= 3.20, Ninja, Python 3
- 8+ GB RAM (parallelism auto-adjusts)
- ~50 GB free disk space

## Cleaning up

```bash
./build.sh clean   # removes build artifacts (~40 GB), preserves source
rm -rf llvm-src wasi-libc-src   # remove source clones too
```

## Updating LLVM version

1. Edit `LLVM_RELEASE_TAG` in `setup.sh`
2. Re-run `./setup.sh` (delete `llvm-src/` first)
3. If the patch script fails, check the warnings — the affected files may have changed between versions

## License

The build scripts in this repo are MIT-licensed. LLVM itself is under the Apache 2.0 License with LLVM Exceptions.
