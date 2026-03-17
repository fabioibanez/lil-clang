#!/usr/bin/env python3
"""
apply-wasi-compat.py — Patch upstream LLVM to compile as a WASI target.

Upstream LLVM calls POSIX APIs (signals, fork/exec, mmap, etc.) that don't
exist in WASI Preview 1. This script applies targeted source modifications
to stub out or conditionalize those calls.

Based on the work from:
  - YoWASP project (whitequark): https://codeberg.org/YoWASP/llvm-project
  - LLVM RFC: https://discourse.llvm.org/t/rfc-building-llvm-for-webassembly/79073
  - PR #92677: "Conditionalize use of POSIX features missing on WASI/WebAssembly"

These patches have been proposed upstream but not yet merged. Once upstream
merges them, this script becomes unnecessary.

Target: LLVM 20.x (should work with minor adjustments on 19.x and 21.x)
"""

import os
import re
import sys
import textwrap

def patch_file(filepath, description, transformations):
    """Apply a list of transformations to a file.

    Each transformation is (pattern, replacement, flags) where pattern is a
    regex and replacement is the substitution string. flags is optional.
    """
    if not os.path.exists(filepath):
        print(f"  SKIP (not found): {filepath}")
        return False

    with open(filepath, "r") as f:
        content = f.read()

    original = content
    for transform in transformations:
        pattern, replacement = transform[0], transform[1]
        flags = transform[2] if len(transform) > 2 else 0
        content, count = re.subn(pattern, replacement, content, flags=flags)
        if count == 0:
            # Try to detect if already patched
            if "__wasi__" in replacement and "__wasi__" in original:
                print(f"  SKIP (already patched): {filepath}")
                return True

    if content != original:
        with open(filepath, "w") as f:
            f.write(content)
        print(f"  PATCHED: {filepath} — {description}")
        return True
    else:
        print(f"  NO CHANGE: {filepath} — pattern not found, may need manual review")
        return False


def insert_after(filepath, anchor, insertion, description):
    """Insert text after the first occurrence of anchor."""
    if not os.path.exists(filepath):
        print(f"  SKIP (not found): {filepath}")
        return False

    with open(filepath, "r") as f:
        content = f.read()

    if insertion.strip() in content:
        print(f"  SKIP (already patched): {filepath}")
        return True

    if anchor not in content:
        print(f"  WARNING: anchor not found in {filepath}")
        return False

    content = content.replace(anchor, anchor + insertion, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print(f"  PATCHED: {filepath} — {description}")
    return True


def insert_before(filepath, anchor, insertion, description):
    """Insert text before the first occurrence of anchor."""
    if not os.path.exists(filepath):
        print(f"  SKIP (not found): {filepath}")
        return False

    with open(filepath, "r") as f:
        content = f.read()

    if insertion.strip() in content:
        print(f"  SKIP (already patched): {filepath}")
        return True

    if anchor not in content:
        print(f"  WARNING: anchor not found in {filepath}")
        return False

    content = content.replace(anchor, insertion + anchor, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print(f"  PATCHED: {filepath} — {description}")
    return True


def replace_block(filepath, start_marker, end_marker, replacement, description):
    """Replace everything between start_marker and end_marker (inclusive)."""
    if not os.path.exists(filepath):
        print(f"  SKIP (not found): {filepath}")
        return False

    with open(filepath, "r") as f:
        content = f.read()

    if "__wasi__" in replacement and "__wasi__" in content:
        print(f"  SKIP (already patched): {filepath}")
        return True

    start_idx = content.find(start_marker)
    end_idx = content.find(end_marker, start_idx)
    if start_idx == -1 or end_idx == -1:
        print(f"  WARNING: block markers not found in {filepath}")
        return False

    content = content[:start_idx] + replacement + content[end_idx + len(end_marker):]
    with open(filepath, "w") as f:
        f.write(content)
    print(f"  PATCHED: {filepath} — {description}")
    return True


def main():
    if len(sys.argv) < 2:
        print("Usage: apply-wasi-compat.py <llvm-source-dir>")
        sys.exit(1)

    llvm_dir = sys.argv[1]
    if not os.path.isdir(llvm_dir):
        print(f"Error: {llvm_dir} is not a directory")
        sys.exit(1)

    # Verify this looks like an LLVM source tree
    if not os.path.exists(os.path.join(llvm_dir, "llvm", "CMakeLists.txt")):
        print(f"Error: {llvm_dir} doesn't look like an LLVM monorepo")
        sys.exit(1)

    print(f"Applying WASI compatibility patches to {llvm_dir}...")
    print()

    success_count = 0
    fail_count = 0

    def track(result):
        nonlocal success_count, fail_count
        if result:
            success_count += 1
        else:
            fail_count += 1

    # =========================================================================
    # 1. Signals — llvm/lib/Support/Unix/Signals.inc
    #
    # WASI has no signal delivery mechanism. We add a complete set of stub
    # implementations guarded by #if defined(__wasi__) at the top of the file,
    # before the real Unix implementations.
    # =========================================================================
    print("[1/10] Signal handling stubs")

    signals_file = os.path.join(llvm_dir, "llvm", "lib", "Support", "Unix", "Signals.inc")
    wasi_signal_stubs = textwrap.dedent('''\

    #if defined(__wasi__)
    // WASI does not have signals. Provide empty stubs.
    void llvm::sys::RunInterruptHandlers() {}
    void llvm::sys::SetInterruptFunction(void (*IF)()) {}
    void llvm::sys::SetInfoSignalFunction(void (*Handler)()) {}
    void llvm::sys::SetOneShotPipeSignalFunction(void (*Handler)()) {}
    void llvm::sys::DefaultOneShotPipeSignalHandler() {}
    void llvm::sys::CallOneShotPipeSignalHandler() {}
    void llvm::sys::SetDefaultPipeSignalHandler() {}
    void llvm::sys::CleanupOnSignal(uintptr_t Context) {}
    bool llvm::sys::RemoveFileOnSignal(StringRef Filename, std::string *ErrMsg) {
      return false;
    }
    void llvm::sys::DontRemoveFileOnSignal(StringRef Filename) {}
    void llvm::sys::AddSignalHandler(sys::SignalHandlerCallback FnPtr,
                                     void *Cookie) {}
    void llvm::sys::DisableSystemDialogsOnCrash() {}
    void llvm::sys::PrintStackTrace(raw_ostream &OS, int Depth) {}
    void llvm::sys::PrintStackTraceOnErrorSignal(StringRef Argv0,
                                                 bool DisableCrashReporting) {}

    #else // !defined(__wasi__)
    ''')

    # Find the first function definition after includes to insert our stubs
    track(insert_before(
        signals_file,
        "static void SignalHandler(",
        wasi_signal_stubs,
        "Add WASI signal stubs"
    ))

    # We also need to close the #else at the end of the file
    if os.path.exists(signals_file):
        with open(signals_file, "r") as f:
            content = f.read()
        if "#else // !defined(__wasi__)" in content and not content.rstrip().endswith("#endif // !defined(__wasi__)"):
            content = content.rstrip() + "\n\n#endif // !defined(__wasi__)\n"
            with open(signals_file, "w") as f:
                f.write(content)

    # =========================================================================
    # 2. CrashRecoveryContext — llvm/lib/Support/CrashRecoveryContext.cpp
    #
    # Crash recovery uses setjmp/signals on Unix. WASI traps are always fatal.
    # =========================================================================
    print("[2/10] Crash recovery stubs")

    crash_file = os.path.join(llvm_dir, "llvm", "lib", "Support", "CrashRecoveryContext.cpp")
    # Add WASI section before the Unix section
    track(insert_before(
        crash_file,
        "#else // !_MSC_VER",
        textwrap.dedent('''\

        #elif defined(__wasi__)

        // WASI implementation.
        // WASI traps are always fatal; crash recovery is not possible.
        static void installExceptionOrSignalHandlers() {}
        static void uninstallExceptionOrSignalHandlers() {}

        bool CrashRecoveryContext::RunSafely(function_ref<void()> Fn) {
          Fn();
          return true;
        }

        '''),
        "Add WASI crash recovery stubs"
    ))

    # =========================================================================
    # 3. InitLLVM — llvm/lib/Support/InitLLVM.cpp
    #
    # Skip signal handler installation on WASI.
    # =========================================================================
    print("[3/10] InitLLVM signal handler skip")

    init_file = os.path.join(llvm_dir, "llvm", "lib", "Support", "InitLLVM.cpp")
    track(patch_file(
        init_file,
        "Guard signal handlers with __wasi__ check",
        [(
            r'([ \t]*)(if \(InstallPipeSignalExitHandler\)\s*\n\s*sys::SetOneShotPipeSignalFunction)',
            r'\1#if !defined(__wasi__)\n\1\2',
            re.MULTILINE
        ), (
            r'(install_out_of_memory_new_handler\(\);)',
            r'\1\n#endif // !defined(__wasi__)',
            0
        )]
    ))

    # =========================================================================
    # 4. Process — llvm/lib/Support/Unix/Process.inc
    #
    # WASI doesn't have getpid(), dup2(), or signal-safe close.
    # =========================================================================
    print("[4/10] Process stubs (getpid, dup2)")

    process_file = os.path.join(llvm_dir, "llvm", "lib", "Support", "Unix", "Process.inc")
    # Patch getpid
    track(patch_file(
        process_file,
        "Stub getpid() for WASI",
        [(
            r'(Process::Pid Process::getProcessId\(\) \{[^}]*?)(return Pid\(::getpid\(\)\);)',
            r'\1#if defined(__wasi__)\n  return Pid(0);\n#else\n  \2\n#endif',
            re.DOTALL
        )]
    ))

    # =========================================================================
    # 5. Program — llvm/lib/Support/Unix/Program.inc
    #
    # WASI cannot spawn subprocesses — no fork(), exec(), posix_spawn().
    # =========================================================================
    print("[5/10] Program spawning stubs")

    program_file = os.path.join(llvm_dir, "llvm", "lib", "Support", "Unix", "Program.inc")
    # Add early return in Execute() for WASI
    track(insert_after(
        program_file,
        "bool sys::commandLineFitsWithinSystemLimits(",
        "",  # We'll patch the Execute function instead
        "Stub subprocess spawning"
    ))
    # A more targeted approach: add WASI guard to the Execute function
    track(patch_file(
        program_file,
        "Return error for subprocess spawning on WASI",
        [(
            r'(static bool Execute\(ProcessInfo &PI.*?\{)',
            r'''\1
#if defined(__wasi__)
  if (ErrMsg)
    *ErrMsg = std::string("WASI does not support spawning subprocesses");
  return false;
#else''',
            re.DOTALL
        )]
    ))

    # =========================================================================
    # 6. Path — llvm/lib/Support/Unix/Path.inc
    #
    # WASI lacks pwd.h (password database), umask(), and file locking.
    # =========================================================================
    print("[6/10] Path operations (umask, home dir, file locking)")

    path_file = os.path.join(llvm_dir, "llvm", "lib", "Support", "Unix", "Path.inc")
    # Guard pwd.h include
    track(patch_file(
        path_file,
        "Guard pwd.h and umask for WASI",
        [(
            r'#include <pwd\.h>',
            '#if !defined(__wasi__)\n#include <pwd.h>\n#endif',
            0
        ), (
            # Patch getUmask or equivalent
            r'(unsigned getUmask\(\) \{)\s*\n\s*(unsigned Mask = ::umask\(0\);)',
            r'''\1
#if defined(__wasi__)
  return 0022;
#else
  \2''',
            0
        )]
    ))

    # =========================================================================
    # 7. Endianness — llvm/include/llvm/ADT/bit.h
    #
    # WASI/WASM needs endian.h included via the linux/emscripten path.
    # =========================================================================
    print("[7/10] Endianness detection for WASM")

    bit_file = os.path.join(llvm_dir, "llvm", "include", "llvm", "ADT", "bit.h")
    track(patch_file(
        bit_file,
        "Add __wasm__ to endian.h include guard",
        [(
            r'defined\(__EMSCRIPTEN__\)',
            'defined(__EMSCRIPTEN__) || defined(__wasm__)',
            0
        )]
    ))

    # =========================================================================
    # 8. CMake config — llvm/cmake/config-ix.cmake
    #
    # Add HAVE_SETJMP feature detection and native arch mapping for wasm32.
    # =========================================================================
    print("[8/10] CMake configuration (HAVE_SETJMP, native arch)")

    config_ix = os.path.join(llvm_dir, "llvm", "cmake", "config-ix.cmake")
    # Add wasm32/64 to native arch detection
    track(patch_file(
        config_ix,
        "Add wasm32/64 native arch mapping",
        [(
            r'(elseif \(LLVM_NATIVE_ARCH MATCHES "riscv64"\)\s*\n\s*set\(LLVM_NATIVE_ARCH RISCV\))',
            r'''\1
elseif (LLVM_NATIVE_ARCH MATCHES "wasm32")
  set(LLVM_NATIVE_ARCH WebAssembly)
elseif (LLVM_NATIVE_ARCH MATCHES "wasm64")
  set(LLVM_NATIVE_ARCH WebAssembly)''',
            0
        )]
    ))

    # =========================================================================
    # 9. Config header — llvm/include/llvm/Config/config.h.cmake
    #
    # Add HAVE_SETJMP macro.
    # =========================================================================
    print("[9/10] Config header (HAVE_SETJMP)")

    config_h = os.path.join(llvm_dir, "llvm", "include", "llvm", "Config", "config.h.cmake")
    track(insert_after(
        config_h,
        "#cmakedefine HAVE_SYS_MMAN_H ${HAVE_SYS_MMAN_H}",
        textwrap.dedent('''

/* Define to 1 if you have the `setjmp' function. */
#cmakedefine HAVE_SETJMP ${HAVE_SETJMP}
'''),
        "Add HAVE_SETJMP macro"
    ))

    # =========================================================================
    # 10. Clang Driver — clang/lib/Driver/Driver.cpp
    #
    # Guard getpid() call in Clang's driver.
    # =========================================================================
    print("[10/10] Clang driver getpid() guard")

    driver_file = os.path.join(llvm_dir, "clang", "lib", "Driver", "Driver.cpp")
    track(patch_file(
        driver_file,
        "Guard getpid() in Clang driver",
        [(
            r'  int PID =\n#if LLVM_ON_UNIX\n      getpid\(\);\n#else\n      0;\n#endif',
            '''  int PID =
#if defined(__wasi__)
      0;
#elif LLVM_ON_UNIX
      getpid();
#else
      0;
#endif''',
            0
        )]
    ))

    # =========================================================================
    # Summary
    # =========================================================================
    print()
    print(f"Done: {success_count} patches applied, {fail_count} issues.")
    if fail_count > 0:
        print("Some patches had issues — review the warnings above.")
        print("This may happen if the LLVM version differs from what this script targets.")
        sys.exit(1)
    else:
        print("All WASI compatibility patches applied successfully.")


if __name__ == "__main__":
    main()
