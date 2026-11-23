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
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
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
#   5. the exe's NEEDED set is system-only (the audience rule — no
#      libz/libbz2/liblzma/libpcre2/libgfortran/libgomp/libzstd/libcurl
#      may appear: configure links them dynamically when given the
#      chance, and RBuild's -L static-archive pin + cache pins + the
#      deps stage's static libcurl exist to stop it; a leak here means
#      a build-host dependency escaped) — and the exe EXPORTS
#      _gfortran_concat_string: libRlapack.so carries that one gfortran
#      reference undefined and binds it from the exe at dlopen (RBuild's
#      FLIBS pin carries the chain statically; --export-dynamic
#      publishes it).
#   6. --image-tree: every shared object INSIDE the staged env image
#      (the modules: lapack.so, internet.so, ...; lib/R/lib/libRlapack.so;
#      the preload shim) passes the same system-only NEEDED gate, with
#      ONE image-internal exception: a NEEDED row whose basename exists
#      elsewhere in the tree (libRlapack.so for lapack.so) is allowed
#      only when the importer's RUNPATH names $ORIGIN — the dlmap2file
#      closure walk resolves bare NEEDED names through the importing
#      object's own rpaths, root-agnostically.
#   7. --image-tree: lapack.so NEEDs libRblas.so DIRECTLY — the closure
#      walk materializes only the dlopen'd object's direct dependencies,
#      so the BLAS libRlapack.so needs must ride lapack.so's own NEEDED
#      set. The toolchain's spec-default --as-needed would drop the
#      reference-free -lRblas; substitution 5 wraps it --no-as-needed.
#
# The skeleton gates the linux-gnu (ELF) leg only; a Mach-O input is a
# named failure, never a silently skipped arm.
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

# The system allowlist (the audience rule): glibc's own family plus the
# musl forms for the leg that arrives later. Anything else an object
# NEEDs — libz, libbz2, liblzma, libpcre2-8, libgfortran, libgomp,
# libzstd, libcurl, libssl, libcrypto, libintl, ... — is a runtime
# dependency a bare system cannot satisfy
# (tebako-runtime-python#76's class).
needed_allowed() {
  case "$1" in
    libc.musl-*.so.1 | ld-musl-*.so.1 | \
    libc.so.6 | libm.so.6 | libdl.so.2 | librt.so.2 | libpthread.so.0 | \
    libutil.so.1 | ld-linux-*.so.2 | ld-linux-*.so.1 | libgcc_s.so.1) return 0 ;;
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

# Echo the object's NEEDED rows (one per line); empty when unauditable.
needed_rows() {
  readelf_d "$1" | awk '/NEEDED/ { gsub(/[][]/, ""); print $NF }'
}

# Echo the object's RUNPATH (or RPATH) value, if any.
runpath_of() {
  readelf_d "$1" | awk -F'[][]' '/RUNPATH|RPATH/ { print $2; exit }'
}

# audit_needed <object> <tree-or-empty>: the system-only NEEDED gate,
# with the image-internal exception when a tree is given (arm 6).
audit_needed() {
  obj="$1"; tree="${2:-}"
  rows="$(needed_rows "$obj")"
  [ -n "$rows" ] || { fail "the dynamic section of $obj yielded no NEEDED rows (a static object? the probe cannot run)"; return; }
  obj_failures_before=$failures
  while IFS= read -r lib; do
    [ -z "$lib" ] && continue
    if needed_allowed "$lib"; then
      continue
    fi
    if [ -n "$tree" ] && [ -n "$(find "$tree" -name "$lib" -print -quit 2>/dev/null)" ]; then
      rp="$(runpath_of "$obj")"
      case "$rp" in
        *'$ORIGIN'*) : ;; # root-agnostic — the closure walk resolves it
        *) fail "$obj NEEDs the in-image $lib but its RUNPATH (${rp:-none}) does not name \$ORIGIN — the dlmap2file closure walk cannot resolve it root-agnostically (RBuild's SHLIB_LDFLAGS pin)" ;;
      esac
    else
      fail "$obj NEEDs $lib — a runtime .so dependency a bare system cannot satisfy (the audience rule; tebako-runtime-python#76)"
    fi
  done <<< "$rows"
  [ "$failures" -eq "$obj_failures_before" ] && note "$obj: NEEDED set is closed ($(printf '%s\n' "$rows" | tr '\n' ' '))"
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
if [ -z "$dis" ]; then
  fail "no objdump could disassemble main in $EXE — the forwarding check cannot run"
elif [ -n "$(printf '%s\n' "$dis" | grep tebako_driver_boot || true)" ]; then
  note "main forwards to tebako_driver_boot (the fs TU is the entry point)"
else
  fail "main in $EXE does not reference tebako_driver_boot — Rmain.c's own main, not the fs TU (the Makefile substitution never landed)"
  echo "disassembly evidence:"; printf '%s\n' "$dis"
fi

# --- arm 5: the exe's runtime library closure is system-only -------------
# The audience rule in executable form (the header). The skeleton ships
# the ELF leg only; anything else is named, never skipped.
if file_out="$(file "$EXE" 2>/dev/null)" && printf '%s' "$file_out" | grep -q ELF; then
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
elif printf '%s' "$file_out" | grep -q 'Mach-O'; then
  fail "$EXE is Mach-O — the skeleton gates the linux-gnu (ELF) leg only; the macos arm arrives with its leg"
else
  fail "file(1) recognizes neither ELF nor Mach-O in $EXE (${file_out:-no output}) — the closure gate cannot run"
fi

# --- arm 6: the in-image shared-object closure ---------------------------
# Every *.so the env image carries (the modules, lib/R/lib, the preload
# shim): the same audience-rule gate, plus the image-internal exception
# (the header). The boot smoke alone would miss this — the CI container
# is NOT bare, so a leaked dependency boots green here and dies on the
# target system.
so_count=0
while IFS= read -r so; do
  so_count=$((so_count + 1))
  audit_needed "$so" "$IMAGE_TREE"
done < <(find "$IMAGE_TREE" -type f -name '*.so*' | sort)
[ "$so_count" -gt 0 ] || fail "no shared objects under $IMAGE_TREE — the staged env image must carry at least the preload shim and R's modules"
note "in-image closure audited over $so_count shared object(s)"

# --- arm 7: lapack.so NEEDs libRblas.so directly --------------------------
# The exec_closure walk materializes only the dlopen'd object's DIRECT
# dependencies, resolved through its own rpaths. libRlapack.so NEEDs
# libRblas.so, so unless lapack.so carries libRblas in its own NEEDED set
# the file is never materialized for ld.so ("libRblas.so: cannot open
# shared object file"). The toolchain's spec-default --as-needed drops
# the reference-free -lRblas from the module link; substitution 5 wraps
# it --no-as-needed.
lapack_so="$(find "$IMAGE_TREE" -type f -name 'lapack.so' -print -quit)"
if [ -z "$lapack_so" ]; then
  fail "no lapack.so under $IMAGE_TREE — R's internal LAPACK module must ship in the env image"
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
