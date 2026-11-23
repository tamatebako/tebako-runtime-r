#!/usr/bin/env bash
# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# ci/check_symbol_provenance.sh — the symbol-provenance assert for a built
# tebako R runtime (tebako-runtime-php's script, R edition). This
# factory's shadow class is the QUIETLY PLAIN interpreter: a link that
# dropped src/main/tebako_r_main.o still yields a working R that fails
# nothing until the first image boot. The fingerprints:
#
#   1. nm: the exe defines the driver's C ABI (tebako_driver_boot,
#      tebako_mount_point, tebako_driver_contract_version) as text/data
#      symbols — libtebako_driver.a was pulled in.
#   2. nm: the exe defines `main` — never stripped (Builder#finalize
#      copies, never strips: the symbol table IS this evidence).
#   3. nm: the exe defines `r_main` — the interpreter's entry point was
#      renamed at compile time (the -Dmain=r_main substitution), so the
#      fs TU owns main.
#   4. the disassembly of `main` references tebako_driver_boot — the fs
#      TU (build/resources/tebako_r_main.c) is the entry point that
#      forwards to the driver, not Rmain.c's own main.
#   5. the exe's runtime closure is system-only (the audience rule — ELF:
#      no libz/libbz2/liblzma/libpcre2/libgfortran/libgomp/libzstd/
#      libcurl may appear; Mach-O: every otool -L row is /usr/lib/* or
#      /System/Library/*, macOS's own dylibs only, and the recorded
#      minos IS contract.yml's macos_deployment_target pin — configure
#      links non-system libraries dynamically when given the chance, and
#      RBuild's static pins + the deps stage exist to stop it; a leak
#      here means a build-host dependency escaped) — and the exe EXPORTS
#      the gfortran chain: libRlapack carries its gfortran references
#      undefined and binds them from the exe at dlopen (RBuild's FLIBS
#      pin carries the chain statically; --export-dynamic on ELF, the
#      global-scope default on Mach-O, publishes it).
#   6. --image-tree: every shared object INSIDE the staged env image
#      (the modules: lapack.so, internet.so, ...; lib/R/lib/libRlapack
#      + libRblas; the preload shim) passes the same system-only
#      closure gate, with ONE image-internal exception: a dependency
#      whose basename exists elsewhere in the tree (libRlapack for
#      lapack.so) is allowed only when the importer's rpath names
#      $ORIGIN (ELF) or @loader_path (Mach-O) — the exec_closure walk
#      resolves bare dependency names through the importing object's
#      own rpaths, root-agnostically. A shared object with ZERO
#      dependency rows is genuinely self-contained (its dynamic section
#      reads clean; --disable-nls compiles a package shlib's last libc
#      reference out and --as-needed drops the NEEDED — splines.so on
#      gnu) and passes: the empty closure is system-only. Zero rows
#      with an UNREADABLE dynamic section stays a failure (the probe
#      cannot run).
#   7. lapack.so NEEDs libRblas DIRECTLY — the closure walk
#      materializes only the dlopen'd object's direct dependencies,
#      so the BLAS libRlapack needs must ride lapack.so's own
#      dependency set. On ELF the toolchain's spec-default --as-needed
#      would drop the reference-free -lRblas; substitution 5 wraps it
#      --no-as-needed. On Mach-O ld64 records every linked dylib — the
#      row is direct by construction (substitution 5 is verify-only).
#
# Usage: ci/check_symbol_provenance.sh --exe PATH [--image-tree DIR]
set -euo pipefail

EXE=""
IMAGE_TREE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --exe) EXE="$2"; shift 2 ;;
    --image-tree) IMAGE_TREE="$2"; shift 2 ;;
    *) echo "check_symbol_provenance: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$EXE" ] || { echo "check_symbol_provenance: --exe PATH is required" >&2; exit 2; }
[ -s "$EXE" ] || { echo "::error::provenance: exe $EXE is missing or empty"; exit 1; }
[ -n "$IMAGE_TREE" ] || IMAGE_TREE="$(cd "$(dirname "$0")/.." && pwd)/.build/image-tree"
[ -d "$IMAGE_TREE" ] || { echo "::error::provenance: image tree $IMAGE_TREE is missing — the in-image closure audit cannot run"; exit 1; }

failures=0
fail() { echo "::error::provenance: $*"; failures=$((failures + 1)); }
note() { echo "provenance: $*"; }

# The object format (one file(1) call per object, memoized per call site).
is_macho() { printf '%s' "$(file "$1" 2>/dev/null)" | grep -q 'Mach-O'; }

# The system allowlist (the audience rule). ELF: glibc's own family plus
# the musl forms. Mach-O: macOS's own dylibs — /usr/lib/* and
# /System/Library/* — and nothing else (a Homebrew /opt/homebrew/* or
# /usr/local/* row is tebako-runtime-python#80's class). Anything else an
# object NEEDs — libz, libbz2, liblzma, libpcre2-8, libgfortran, libgomp,
# libzstd, libcurl, libssl, libcrypto, libintl, ... — is a runtime
# dependency a bare system cannot satisfy (tebako-runtime-python#76's
# class).
needed_allowed() {
  case "$1" in
    libc.musl-*.so.1 | ld-musl-*.so.1 | \
    libc.so.6 | libm.so.6 | libdl.so.2 | librt.so.2 | libpthread.so.0 | \
    libutil.so.1 | ld-linux-*.so.2 | ld-linux-*.so.1 | libgcc_s.so.1 | \
    /usr/lib/* | /System/Library/*) return 0 ;;
    *) return 1 ;;
  esac
}

# readelf/llvm-readelf cascade (an ELF harness must carry binutils).
readelf_d() {
  if command -v readelf >/dev/null 2>&1; then
    readelf -d "$1" 2>/dev/null || true
  elif command -v llvm-readelf >/dev/null 2>&1; then
    llvm-readelf -d "$1" 2>/dev/null || true
  fi
}

# Echo the object's direct dependency rows (one per line); empty when
# unauditable. Mach-O: otool -L's first data row for a dylib is its OWN
# install name (LC_ID_DYLIB), never a dependency — rows matching the
# object's basename are dropped here so every caller sees dependencies
# only (R's libR*.dylib carry @rpath install names after RBuild's
# fixup; the image-internal exception in audit_needed covers the
# references to them, not the id row).
needed_rows() {
  if is_macho "$1"; then
    otool -L "$1" 2>/dev/null | awk -v base="$(basename "$1")" 'NR > 1 { n = split($1, seg, "/"); if (seg[n] != base) print $1 }'
  else
    readelf_d "$1" | awk '/NEEDED/ { gsub(/[][]/, ""); print $NF }'
  fi
}

# Echo the object's rpath entries (one per line), if any. Mach-O reads
# the LC_RPATH load commands (the line after `cmd LC_RPATH` is
# `path <value> (offset N)`).
runpath_rows() {
  if is_macho "$1"; then
    otool -l "$1" 2>/dev/null | awk '/cmd LC_RPATH/ { getline; getline; print $2 }'
  else
    readelf_d "$1" | awk -F'[][]' '/RUNPATH|RPATH/ { print $2 }'
  fi
}

# The auditability probe behind the zero-row carve-out: the object HAS
# a readable dynamic section, so zero dependency rows mean a genuinely
# self-contained object (the --disable-nls pin compiled splines.so's
# last libc reference out and the toolchain's --as-needed dropped the
# NEEDED — the empty closure is system-only), never a probe failure.
# ELF: readelf's "Dynamic section" marker. Mach-O: otool -L lists at
# least the object's own install name.
object_is_dynamic() {
  if is_macho "$1"; then
    [ -n "$(otool -L "$1" 2>/dev/null)" ]
  else
    readelf_d "$1" | grep -q 'Dynamic section'
  fi
}

# audit_needed <object> <tree-or-empty>: the system-only closure gate,
# with the image-internal exception when a tree is given (arm 6).
audit_needed() {
  obj="$1"; tree="${2:-}"
  rows="$(needed_rows "$obj")"
  if [ -z "$rows" ]; then
    if object_is_dynamic "$obj"; then
      note "$obj: no dependency rows — a self-contained object (the empty closure is system-only)"
    else
      fail "the dynamic section of $obj is unreadable (a static object? the probe cannot run)"
    fi
    return
  fi
  obj_failures_before=$failures
  while IFS= read -r lib; do
    [ -z "$lib" ] && continue
    if needed_allowed "$lib"; then
      continue
    fi
    if [ -n "$tree" ] && [ -n "$(find "$tree" -name "$(basename "$lib")" -print -quit 2>/dev/null)" ]; then
      rp="$(runpath_rows "$obj")"
      case "$rp" in
        *'$ORIGIN'* | *'@loader_path'*) : ;; # root-agnostic — the closure walk resolves it
        *) fail "$obj NEEDs the in-image $lib but its rpath (${rp:-none}) names neither \$ORIGIN nor @loader_path — the closure walk cannot resolve it root-agnostically (RBuild's SHLIB/DYLIB LDFLAGS pins)" ;;
      esac
    else
      fail "$obj NEEDs $lib — a runtime dependency a bare system cannot satisfy (the audience rule; tebako-runtime-python#76)"
    fi
  done <<< "$rows"
  [ "$failures" -eq "$obj_failures_before" ] && note "$obj: dependency set is closed ($(printf '%s\n' "$rows" | tr '\n' ' '))"
}

# --- arms 1-3: the symbol table -----------------------------------------
# capture-then-test everywhere (never nm | grep -q under pipefail: grep's
# early exit SIGPIPEs nm into a false negative). An empty capture earns
# nm's own diagnostic as evidence — a silent nm failure must not read as
# "stripped".
symbols="$(nm "$EXE" 2>/dev/null || true)"
if [ -z "$symbols" ]; then
  echo "provenance: nm yielded no symbol table for $EXE; nm's own diagnostic:"
  nm "$EXE" 2>&1 | head -5 || true
fi

for sym in tebako_driver_boot tebako_mount_point tebako_driver_contract_version main r_main; do
  line="$(printf '%s\n' "$symbols" | grep -E "[TtWwDd] _?${sym}\$" || true)"
  if [ -z "$line" ]; then
    fail "$sym is not a defined symbol in $EXE — the driver stack / fs TU was never linked (the plain-interpreter shadow)"
    echo "nm evidence (all tebako-ish symbols):"
    printf '%s\n' "$symbols" | grep -i tebako || echo "(none — stripped? Builder#finalize never strips)"
  else
    note "$sym defined in the exe: $line"
  fi
done

# --- arm 4: main forwards to tebako_driver_boot --------------------------
# Output-driven tool selection (tebako-runtime-ruby's cascade): an
# objdump that cannot honor --disassemble=<sym> yields no body and the
# llvm-objdump spelling is tried next; neither producing the body is a
# failure — never a silently skipped provenance check.
dis=""
if command -v objdump >/dev/null 2>&1; then
  dis="$(objdump -d --disassemble=main "$EXE" 2>/dev/null || true)"
fi
if [ -z "$(printf '%s\n' "$dis" | grep 'main>:' || true)" ] && command -v llvm-objdump >/dev/null 2>&1; then
  dis="$(llvm-objdump -d --disassemble-symbols=main "$EXE" 2>/dev/null || true)"
fi
if [ -z "$(printf '%s\n' "$dis" | grep 'main>:' || true)" ] && command -v otool >/dev/null 2>&1; then
  # darwin last resort: /usr/bin/objdump is a deprecation shim and
  # llvm-objdump sits behind xcrun (off PATH) — otool (cctools) is
  # always there. Mach-O labels are bare `_symbol:` lines; take the body
  # up to the next label (a tail call has no ret).
  dis="$(otool -tV "$EXE" 2>/dev/null | awk '/^_main:/{f=1; next} f && /^[_a-zA-Z].*:$/{exit} f{print}' || true)"
fi
if [ -z "$dis" ]; then
  fail "no objdump could disassemble main in $EXE — the forwarding check cannot run"
elif [ -n "$(printf '%s\n' "$dis" | grep tebako_driver_boot || true)" ]; then
  note "main forwards to tebako_driver_boot (the fs TU is the entry point)"
else
  fail "main in $EXE does not reference tebako_driver_boot — Rmain.c's own main, not the fs TU (the Makefile substitution never landed)"
  echo "disassembly evidence:"; printf '%s\n' "$dis"
fi

# --- arm 5: the exe's runtime library closure is system-only -------------
# The audience rule in executable form (the header).
if is_macho "$EXE"; then
  if ! command -v otool >/dev/null 2>&1; then
    fail "a Mach-O exe and no otool to audit its dylib rows — the harness must carry cctools"
  else
    audit_needed "$EXE" ""
  fi
  # libRlapack.dylib's gfortran references are left undefined in the
  # dylib (-undefined dynamic_lookup) and bind from the exe at dlopen —
  # the same mechanism the modules use for R's own symbols under
  # --disable-R-shlib. The exe carries the chain statically (RBuild's
  # FLIBS pin) and Mach-O's global-scope default publishes it; no
  # export, no LAPACK. Darwin nm prints defined text symbols as
  # `<addr> T _name`.
  if [ -z "$(printf '%s\n' "$symbols" | grep -E '[Tt] __gfortran_concat_string$' || true)" ]; then
    fail "the exe does not define _gfortran_concat_string — libRlapack.dylib's undefined gfortran reference has no binding partner (RBuild's FLIBS pin)"
  else
    note "the exe defines _gfortran_concat_string (libRlapack.dylib's gfortran binding partner)"
  fi
  # The support floor is a pinned product decision (contract.yml's
  # macos_deployment_target), never the runner image's accident — the
  # python factory's floor floated with the build host's OS and the Intel
  # exe refused to load on macOS 14 (tebako-runtime-python#81). The
  # recorded LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX minos must BE the
  # pin. The contract sits beside this script's ci/ directory.
  floor=$(sed -n 's/^macos_deployment_target: *"\([^"]*\)".*/\1/p' "$(cd "$(dirname "$0")/.." && pwd)/contract.yml")
  [ -z "$floor" ] && fail "contract.yml carries no macos_deployment_target pin — the floor cannot float (tebako-runtime-python#81)"
  minos="$(otool -l "$EXE" 2>/dev/null | awk '/cmd LC_VERSION_MIN_MACOSX|cmd LC_BUILD_VERSION/ {found=1} found && /^    minos / {print $2; exit}' || true)"
  [ -z "$minos" ] && fail "otool -l on $EXE yielded no minos record — a Mach-O without a support floor cannot be gated"
  [ "$minos" = "$floor" ] || fail "$EXE records minos $minos but contract.yml pins $floor — the macOS floor floated with the runner image (tebako-runtime-python#81)"
  note "the exe's recorded support floor is the pinned $floor"
else
  if ! command -v readelf >/dev/null 2>&1 && ! command -v llvm-readelf >/dev/null 2>&1; then
    fail "an ELF exe and no readelf/llvm-readelf to audit its NEEDED rows — the harness must carry binutils"
  else
    audit_needed "$EXE" ""
  fi
  # libRlapack.so's single gfortran reference (_gfortran_concat_string)
  # is left undefined in the module and binds from the exe at dlopen —
  # the same mechanism the modules use for R's own symbols under
  # --disable-R-shlib. The exe carries the chain statically (RBuild's
  # FLIBS pin) and --export-dynamic publishes it; no export, no LAPACK.
  if [ -z "$(nm -D --defined-only "$EXE" 2>/dev/null | grep ' _gfortran_concat_string$' || true)" ]; then
    fail "the exe does not export _gfortran_concat_string — libRlapack.so's undefined gfortran reference has no binding partner (RBuild's FLIBS pin)"
  else
    note "the exe exports _gfortran_concat_string (libRlapack.so's gfortran binding partner)"
  fi
fi

# --- arm 6: the in-image shared-object closure ---------------------------
# Every shared object the env image carries (the modules, lib/R/lib, the
# preload shim): the same audience-rule gate, plus the image-internal
# exception (the header). The boot smoke alone would miss this — the CI
# build host is NOT bare, so a leaked dependency boots green here and
# dies on the target system. (*.so* catches the ELF objects and R's
# darwin module bundles — SHLIB_EXT is .so there too; *.dylib catches
# the darwin libR*.)
so_count=0
while IFS= read -r so; do
  so_count=$((so_count + 1))
  audit_needed "$so" "$IMAGE_TREE"
done < <(find "$IMAGE_TREE" -type f \( -name '*.so*' -o -name '*.dylib' \) | sort)
[ "$so_count" -gt 0 ] || fail "no shared objects under $IMAGE_TREE — the staged env image must carry at least the preload shim and R's modules"
note "in-image closure audited over $so_count shared object(s)"

# --- arm 7: lapack.so NEEDs libRblas directly ----------------------------
# The exec_closure walk materializes only the dlopen'd object's DIRECT
# dependencies, resolved through its own rpaths. libRlapack NEEDs
# libRblas, so unless lapack.so carries libRblas in its own dependency
# set the file is never materialized for ld.so's sake ("libRblas:
# cannot open shared object file"). On ELF the toolchain's spec-default
# --as-needed drops the reference-free -lRblas from the module link;
# substitution 5 wraps it --no-as-needed. On Mach-O ld64 records every
# linked dylib — the row is direct by construction.
lapack_so="$(find "$IMAGE_TREE" -type f -name 'lapack.so' -print -quit)"
if [ -z "$lapack_so" ]; then
  fail "no lapack.so under $IMAGE_TREE — R's internal LAPACK module must ship in the env image"
elif is_macho "$lapack_so"; then
  if [ -n "$(needed_rows "$lapack_so" | grep '^@rpath/libRblas\.dylib$' || true)" ]; then
    note "lapack.so loads @rpath/libRblas.dylib directly (the closure walk's materialization anchor; RBuild's install-name fixup)"
  else
    fail "lapack.so does not load @rpath/libRblas.dylib directly — the exec_closure walk cannot materialize it for libRlapack.dylib's sake (the darwin install-name fixup rewrites R's bare names; a drifted link lost the row)"
  fi
elif [ -n "$(needed_rows "$lapack_so" | grep '^libRblas\.so$' || true)" ]; then
  note "lapack.so NEEDs libRblas.so directly (the closure walk's materialization anchor)"
else
  fail "lapack.so does not NEED libRblas.so directly — the exec_closure walk cannot materialize it for libRlapack.so's sake (substitution 5's --no-as-needed pin)"
fi

if [ "$failures" -gt 0 ]; then
  echo "::error::provenance: $failures check(s) failed"
  exit 1
fi
note "the driver stack is linked, the fs TU is the entry point, and the closure is system-only — provenance OK ($EXE)"
