# The build chain — architecture and invariants

This document is the normative description of how this repository's CI
turns a pristine CRAN source tarball into a verified runtime pair, and
of the pin contracts that keep the factory honest. **If you change any
workflow, the build tooling, the matrix computation, or a cache key,
update this file in the same PR.** A future agent that skips this file
and "just fixes" a red run is the classic failure mode — read it first.
(tebako-runtime-php's docs/build-chain.md is the family reference; this
file carries the R factory's edition, minus the windows legs.)

## The staged hierarchy

One reusable workflow, `_build-platform.yml` (the php factory's port),
called by the three thin triggers (`build-linux-gnu.yml`,
`build-linux-musl.yml`, `build-macos.yml`) and by the `publish.yml`
coordinator — never dispatched directly:

1. **parity** — the contract gate's driver-source parity arm needs the
   pinned link-unit release's `lib.rs` off raw.githubusercontent.com, a
   fetch that flakes under near-simultaneous per-platform reads
   (tamatebako/tebako-runtime-python#4). ONE job fetches it (bounded
   retry) and hands it to compute as an artifact.
2. **compute** — the contract gate (`scripts/check_contract.rb`:
   contract.yml against `schema/contract.schema.yml`, the
   catalog ↔ versions.yml cross-lock, and the parity arm reading the
   stage-1 artifact via `TEBAKO_DRIVER_SRC`) runs first; then
   `scripts/compute_matrix.rb` expands this platform's legs from
   `contract.yml`'s catalog × `.github/matrix.json`'s env vocabulary
   under the dispatch filters (`R_FILTER`, `PLATFORM_FILTER`,
   `ARCH_FILTER`). Every downstream value flows from these outputs —
   workflow YAML never hardcodes a version, a tag, or a SHA. The run's
   `SOURCE_DATE_EPOCH` (the HEAD commit's epoch, the ruby#381 idiom) is
   computed here and exported to every leg.
3. **preflight** — the container digest pin (the ruby#381 idiom, born
   pinned here): `contract.yml container_digests` must equal the ghcr
   registry's CURRENT digest for the tag — per (container × leg arch) —
   before any leg spends compute; the build leg then pulls
   `name:tag@digest`. A retagged toolchain container fails the preflight
   by name instead of moving the compiler under the matrix, and a failed
   preflight skips the build legs outright. (The macOS legs are
   runner-native — no container, nothing to preflight.)
4. **build** — one leg per (R × arch): `tools/build_runtime` → (macOS:
   the sign+notarize arm, spec 31, gated on `APPLE_SIGNING_ENABLED`) →
   `ci/check_symbol_provenance.sh` → `tools/boot_smoke` → the
   `runtime-packages-<os>-<arch>-<r>` artifact. The linux legs
   docker-run the digest-pinned `tpkg-builder` image per step (the
   container grammar: the job-level `container:` form is out — the
   alpine-based musl image cannot host node actions, and uniformity
   beats a per-image branch). The macOS legs run runner-native: the
   toolchain is the runner image's CLT plus its Homebrew gfortran
   (the macOS provisioning note below), and the provenance gate's
   Mach-O arm proves the closure stays system-only.
5. **publish** — one leg per (R × arch), re-running THIS leg's artifact
   handoff (tebako-runtime-ruby#190's split): the leg that built a
   package publishes it (the tebako-release gem's uploader — payload +
   .sha256 sidecars + the .manifest.json shard, write-once per-leg
   names) and signs its served names (the gem's signer, spec 09 §5),
   then attests SLSA L3 provenance over the exact shipped bytes. N legs
   publish concurrently with zero rendezvous (spec 13 §2a's
   de-rendezvous); a publish-layer failure re-runs as a minutes-long
   download + upload, never a rebuild. Runs only when the caller asked
   for `publish`.
6. **verify** — the terminal aggregate and the branch-protection gate.
   The build legs are a dynamic matrix whose check names shift with the
   catalog, so protection pins this job's stable check name; on publish
   runs it gates on the publish legs too.

`publish.yml` is the operator-facing coordinator (the php factory's
port): the optional `prepare-release` job (a force_rebuild republication
recreates the release OBJECT under the kept tag —
tebako-runtime-ruby#189), one `_build-platform.yml` call per selected
platform, then ONE release job that audits the whole matrix against the
release (read-only — the legs' publish jobs already landed their
packages), renders the registry from the release's shards
(`tools/registry_update.rb`), and lands it on main by bot PR +
auto-merge (main is protected), then nudges the official aggregate and
pings the versions catalog.

`lint.yml` is the static gate (no builds): the same contract check, the
catalog/matrix resolution, a `ruby -c` sweep over every authored ruby
file, and a parse pass over every authored YAML/JSON.

## The inputs (both pinned, both verified)

- **R source** — `cran.r-project.org/src/base/R-4/R-<v>.tar.gz`,
  sha256-pinned per version in `versions.yml`. There is NO tamatebako
  R source factory; the tarball is upstream's pristine release.
  `SourceFetcher` downloads and verifies; a checksum mismatch is a
  named error, never a re-fetch. (Source-vs-prebuilt: the README's
  decision section — CRAN ships no linux binary, and distro/Posit
  linux builds NEED distro libraries the audience rule forbids.)
- **the link unit** — `link-unit-<ver>-<pid>.tar.gz` from the pinned
  tamatebako/tebako release (`contract.yml link_unit_release`): the
  spec-17 driver + scoped tfs + the native closure, fetched through the
  release API's digest anchor (the release's own SHA256SUMS does not
  cover the link-unit assets), and the tfs CLI from the same pinned
  release. An empty pin, a missing asset, or a checksum mismatch are
  hard named errors — this factory has no source-build path for the
  driver stack.

Both download under `.build/downloads/` and are re-verified against the
pins on every use, so a poisoned or stale cache entry cannot survive a
pin bump.

## The toolchain containers and the in-leg provisioning

The linux legs run inside the digest-pinned `tpkg-builder` images; the
macOS legs are runner-native. Each leg's provisioning:

- **linux-gnu** (`tpkg-builder-x86_64-linux-gnu`, ubuntu 20.04,
  gcc-11). The v1 image lacks three packages R 4.6 needs:
  - **gfortran** — R's included LAPACK is Fortran; there is no C
    fallback. The leg installs `gfortran-11` and points
    `update-alternatives` at it (matching the image's gcc-11).
    gfortran-11 comes from the `ubuntu-toolchain-r/test` PPA, and
    `ppa.launchpad.net` intermittently 503s mid-fetch (index and pool
    alike) — the apt phase repoints the source at
    `ppa.launchpadcontent.net` (same content, steady) and retries the
    update/install a handful of times before failing named.
  - **liblzma-dev** and **libpcre2-dev** — R 4.6 dropped its bundled xz
    and pcre2; configure requires the system libraries (statically
    linked via the `-L` pin below).
- **linux-musl** (`tpkg-builder-x86_64-linux-musl` /
  `tpkg-builder-aarch64-linux-musl`, alpine): `apk add gfortran
  bzip2-dev bzip2-static xz-dev xz-static pcre2-dev tzdata` (bounded
  retry on a mirror hiccup). tzdata is for R's configure, which runs a
  date-time conversion probe needing the zone database. Alpine splits
  the static archives out of the -dev
  packages: `bzip2-static`/`xz-static` carry libbz2.a/liblzma.a (the
  -dev packages carry the headers and the shared objects only), while
  pcre2-dev ships libpcre2-8.a directly. The gfortran/quadmath story
  forks per arch: aarch64 alpine builds gfortran WITHOUT libquadmath
  (container-proven: `gfortran -print-file-name=libquadmath.a` finds
  nothing), so its libgfortran.a folds the quadmath entry points
  internally and the musl-arm64 `FLIBS` pin drops `-lquadmath`;
  x86_64 alpine SHIPS libquadmath.a and its libgfortran.a references
  `quadmath_snprintf` exactly like gnu's, so the musl-x86_64 pin keeps
  `-lquadmath` (RBuild's `quadmath_static?`).
- **macos** (`macos-15-intel`, `macos-15`): runner-native, no
  container. The toolchain is the runner image's Command Line Tools
  (Apple clang) plus the image's Homebrew **gcc** formula — gfortran
  and its static archives (`libgfortran.a`, `libquadmath.a`,
  `libgcc.a`) come from there, located through `gfortran
  -print-file-name`, never a hardcoded Cellar path. The
  `MACOSX_DEPLOYMENT_TARGET` floor is contract.yml's
  `macos_deployment_target` pin, exported over the WHOLE build
  (configure probes, the deps stage, the final link) — unpinned, the
  exe's LC_BUILD_VERSION minos floats with the build host's OS
  (tebako-runtime-python#81), and the provenance gate's Mach-O arm
  asserts recorded == pin. The sign+notarize arm
  (`ci/macos-sign-notarize-runtime.sh`, spec 31: Developer ID
  Application + hardened runtime + notary ticket, entitlements
  disable-library-validation + allow-jit) runs in-leg after the build,
  gated on `APPLE_SIGNING_ENABLED` — every downstream gate and the
  publish stage's .sha256 anchor the exact SIGNED bytes.

No **libssl-dev** and no **zlib1g-dev** reliance on the linux legs,
deliberately: the deps stage builds its own static OpenSSL 3 (the
`CURL_CONFIG` pin below) — the focal image's 1.1.1 is EOL and curl
8.23 rejects it outright (configure requires >= 3.0.0), and a bare
musl target has no libssl at all — and its own -fPIC static zlib (the
`build_zlib` stage): the gnu image's `libz.a` is compiled without PIC,
and R links `-lz` into internet.so, a shared object, where ld rejects
non-PIC relocations outright. The macOS legs build NO curl/openssl/
zlib at all: macOS's own dylibs carry them (the system curl-config
answers `--built-shared yes`; the closure stays system-only by policy
— the Mach-O provenance arm proves it), and the deps stage there
builds only pcre2 and xz (static, -fPIC) because the SDK ships their
stubs without the headers.

The named follow-up is baking the linux packages into
tebako-ci-containers and dropping the in-leg `apt-get`/`apk` — the
container pin's immutable digest means the provisioning is itself
deterministic (the same base image every time), but an image that
carries its own toolchain is the honest end state.

## The Makefile-substitution law (the factory never edits R source)

This repo is a **pure builder** of pristine upstream source. The driver
link is composed by build-time substitutions on R's GENERATED
`src/main/Makefile` (`RBuild#substitute_makefile`), never by a source
patch:

- an explicit `Rmain.o` rule compiles `$(srcdir)/Rmain.c` with
  `-Dmain=r_main` (the interpreter's entry point renamed at compile
  time — an explicit target rule wins over the generic `.c.o` suffix
  rule, which the substitution leaves untouched);
- the `$(R_binary)` link recipe gains `tebako_r_main.o` between
  `$(R_bin_OBJECTS)` and `$(R_bin_LDADD)`, and `$(TEBAKO_LIBS)` last
  (the fs TU + the scoped driver closure);
- the `$(R_binary)` rule gains the fs TU object and the BLAS objects as
  prerequisites, and the fs TU compile rule (dependent on the
  build-generated `../include/Rversion.h` — the fs TU's version banner
  reads the same header upstream Rscript.c prints from) + the
  `TEBAKO_LIBS` and `BLAS_STATIC_OBJS` variables land under a marker
  comment;
- the `EXTRA_LIBS` line's `$(BLAS_LIBS)` becomes
  `$(BLAS_STATIC_OBJS)` — R.bin links R's own included BLAS as OBJECTS.
  `CONFIGURE_ARGS` carries `--without-blas` for this: the included BLAS
  is the uniform answer on every leg (darwin's configure default would
  otherwise find the system Accelerate framework and the closure would
  fork per leg — the same determinism rule as the zlib/OpenSSL deps).
  Upstream builds that BLAS ONLY as the shared `libRblas.so`
  (src/extra/blas/Makefile.in builds nothing when BLAS_SHLIB is false),
  and an exe that NEEDs it could never boot the driver: ld.so resolves
  NEEDED before `main()`, before any mount exists. The object list is
  parsed from the generated `src/extra/blas/Makefile`'s `blas_OBJS`
  assignment (a drift is a named error) — the same objects libRblas.so
  carries, built before src/main in R's own SUBDIRS order. libRblas.so
  still builds and ships in lib/R/lib for libRlapack.so, resolved
  post-mount through the dylib rpath (the `SHLIB_LDFLAGS` pin below —
  an unset `DYLIB_LDFLAGS` inherits the preset, so the lib/*.so dylibs
  carry it too);
- and on the GENERATED `src/modules/lapack/Makefile` (substitution 5):
  the module link's `-lRblas` (EXTRA_LIBS) is wrapped in
  `-Wl,--no-as-needed … -Wl,--as-needed`. The tpkg-builder toolchain's
  link spec enables `--as-needed` by default
  (`%{!fsanitize=*:--as-needed}`), and lapack.so's own objects reference
  no BLAS symbol, so the reference-free `-lRblas` is dropped and libRblas
  arrives only transitively through libRlapack.so. But the exec_closure
  walk (crates/tfs) materializes only the dlopen'd object's DIRECT
  dependencies, resolved through its own rpaths — a transitive libRblas
  is never materialized and ld.so fails libRlapack.so's load
  ("libRblas.so: cannot open shared object file"). The wrap restores
  upstream's intended semantics (the Makefile's own comment: "Include
  BLAS here, as with (static) ATLAS that pulls all the BLAS routines
  into one place"). The module Makefile's self-regeneration rule names
  only the stable prerequisites, so no collapse is needed there; the
  marker re-application guard works the same way.

Every anchor must match exactly once; an R whose generated-Makefile
grammar drifted is a named build error (exit 103), never a half-applied
edit. `config.status` regenerates the Makefile WITHOUT the marker, so a
re-configure cleanly re-applies the pass. The substitution also removes
the stale `Rmain` objects it invalidates (make does not track recipe
changes).

If a genuine R source need ever appears (a patch the runtime cannot
live without), the answer is a tamatebako **source factory** for R —
the tamatebako/ruby and tamatebako/python pattern — never a factory-
side hot-patch of R source.

## The configure pins (the static closure, deterministically)

`RBuild::CONFIGURE_ARGS` is the feature policy (the README's table);
`RBuild#configure_env` carries the closure pins, each answering a
specific "the build host decided the artifact" failure class:

- **`LIBnn=lib`** — rhome is `<prefix>/lib/R` on every leg (never
  lib64: ubuntu has no `/usr/lib64`, and R's configure would otherwise
  pick lib64 on x86_64).
- **`CFLAGS=-O2`** — the tpkg-builder gnu image exports
  `CFLAGS=-pthread`, and under autoconf an env-set CFLAGS REPLACES
  configure's `-g -O2` default outright (the
  tebako-runtime-python#79 slow-build class; php's pin is the same fix,
  one interpreter over). Deliberately NO `-pthread`, although the
  container's value carries it: `R_PTHREAD` (m4/R.m4) searches for the
  link option that finds `pthread_kill` and adds it to
  `MAIN/DYLIB_LDFLAGS` — with `-pthread` already in CFLAGS the empty
  option wins, the flag never reaches R.bin's link (`MAIN_LINK`
  carries no CFLAGS), and eval.c's `pthread_create` is undefined at
  link time. Letting configure find it keeps the flag on upstream's
  own channel (the stock-R shape). `RBuild#recorded_cflags` reads the
  ACTUAL flags back from the generated Makeconf and fails the build
  (exit 103) unless an `-O2`/`-O3` is present and no `-O0/-O1/-Og/-Od`
  is, and the boot smoke's compute-floor re-asserts the pair at run
  time (the `.contract.yaml` card's `built_from.cflags` — the one
  surface that records the flags, since R records no CFLAGS at
  runtime — plus a timing tripwire).
- **`-L<.build/static-libs>`** — R 4.6 links zlib/bzip2/xz/pcre2
  DYNAMICALLY into libR by default (the bundled copies are gone), and
  each configure probe PREPENDS its `-lz`/`-lbz2`/`-llzma`/`-lpcre2-8`
  to `LIBS` — a static-spec `-l:libz.a` in our own `LIBS` would lose
  the order. So `prepare_static_libs_dir` fronts a `-L` dir with
  symlinks to the STATIC archives and nothing else: libz.a is the
  deps stage's own -fPIC build (`build_zlib` — the toolchain's archive
  carries no PIC and internet.so links `-lz` into a shared object, where
  ld rejects non-PIC relocations); libbz2/liblzma/libpcre2-8 are resolved
  through the compiler's own search path (`gcc -print-file-name=<archive>`
  — a missing one is a named error with its provisioning hint) and only
  ever reach R.bin's link, so PIC-in-archive is never exercised there;
  libgfortran.a/libquadmath.a come from the compiler's own directory for
  the exe's FLIBS pin (the next bullet — no shlib link ever names them).
  libbz2/liblzma/libpcre2-8 are NOT on a bare system (the audience rule,
  tebako-runtime-python#76's class). internet.so's curl closure resolves
  its `-lz` against the deps prefix too (its `-lssl`/`-lcrypto` come
  from the deps prefix's own static OpenSSL). The provenance gate proves
  no DT_NEEDED escaped.
- **`-static-libgfortran -static-libgcc`** on `LDFLAGS` — the declared
  intent (gfortran's runtime is NOT on a bare system), but on this
  toolchain the flags do NOT rewrite a literal `-lgfortran`, and focal's
  `libgfortran.a` is non-PIC (ld refuses it in any shared object), so
  the actual closure is split by the `FLIBS`/`FLIBS_IN_SO` pins. R's
  LAPACK references exactly one gfortran symbol,
  `_gfortran_concat_string`: the EXE's `FLIBS` carries the chain
  statically (`-Wl,--undefined=_gfortran_concat_string -lgfortran
  -lquadmath -lm`, resolved against the `-L` pin's archives — the
  concat chain pulls `write.o`, which needs `quadmath_snprintf`), and
  `--export-dynamic` (already in `MAIN_LDFLAGS`) exports the symbol;
  `FLIBS_IN_SO` drops `-lgfortran` entirely, so libRlapack.so records
  no gfortran NEEDED and its undefined reference binds from the exe at
  dlopen — the same mechanism the modules use for R's own symbols under
  `--disable-R-shlib`. The provenance gate asserts both halves (the
  exe's export, libRlapack.so's closed NEEDED), and the boot smoke's
  LAPACK probe (`solve()`) proves the chain end to end.
- **`SHLIB_LDFLAGS='-Wl,-rpath,'"'"'$$ORIGIN/../lib:$$ORIGIN/../../../lib'"'"'`**
  — R's included LAPACK builds as `R_HOME/lib/libRlapack.so`, and
  configure's internal-LAPACK `LAPACK_LIBS` names `-lRlapack` on the
  shlib links, while the shlib `BLAS_LIBS` names `-lRblas`: the modules
  and the library package .so's NEED those bare sonames. The
  `dlmap2file` closure walk (crates/tfs exec_closure) resolves a bare
  NEEDED only through the importing image's OWN rpaths, so the rpath
  names `lib/R/lib` root-agnostically from BOTH shlib depths:
  `lib/R/modules/` (`$ORIGIN/../lib`) and `lib/R/library/<pkg>/libs/`
  (`$ORIGIN/../../../lib`); each depth's other entry is a dead path
  ld.so skips. The same preset seeds `DYLIB_LDFLAGS` (configure.ac: an
  unset `DYLIB_LD`/`DYLIB_LDFLAGS` inherits the SHLIB pair), so
  libRlapack.so and libRblas.so carry the rpath as well — from
  `lib/R/lib/`, the first entry normalizes to `lib/R/lib`, and
  libRlapack.so's own NEEDED libRblas.so resolves the same way. The
  `$$` survives make's expansion into the recipe; the quotes protect
  `$ORIGIN` from the shell.
- **`CURL_CONFIG=<.build/deps>/bin/curl-config`** — R has NO
  `--without-libcurl` switch: `R_LIBCURL` HARD-FAILS the configure
  without libcurl + https support (m4/R.m4), so the python#80
  host-leak class cannot be pinned off by hiding the header — the
  closure must be PROVIDED honestly. The deps stage
  (`RBuild#build_deps`, running before configure) builds all three
  itself from versions.yml's `deps:` pins:
  - **zlib 1.4, static -fPIC** — R links `-lz` into internet.so, a
    shared object, and the focal toolchain's `libz.a` is compiled
    without PIC (ld rejects its relocations in a shared link), so the
    distro has nothing honest to offer. `--static`, `-O3 -fPIC`;
    `prepare_static_libs_dir` fronts the installed `libz.a` for every
    `-lz` (libR's own LIBS included).
  - **OpenSSL 3.5 (LTS, Apache-2.0)** — license-clean for static
    linking (the LGPL TLS stacks are not), and the only honest source:
    curl 8.23 requires OpenSSL >= 3.0.0 while the focal toolchain
    carries the EOL 1.1.1. Built `no-shared no-module no-dso
    no-tests -fPIC`: static archives with the providers built INTO
    libcrypto (a module build would dlopen them at runtime from the
    build machine's `<prefix>/lib/ossl-modules` — a path that exists
    nowhere on the user's system or inside the VFS), PIC because
    internet.so is a shared object. `--openssldir=/usr/lib/ssl` bakes
    the debian CA layout (`/etc/ssl/certs`) as the runtime default;
    `SSL_CERT_FILE`/`SSL_CERT_DIR` override at run time.
  - **libcurl 8.23, minimal static** — http/https/ftp/file only,
    `--with-openssl=<deps prefix>`, and no idn2/rtmp/ssh/psl/ldap/
    gssapi/brotli/zstd/http2+3 (the distro libcurl's
    LGPL/GPL-encumbered closure is exactly what must not ship).
  `AC_PATH_PROG` honors the preset `CURL_CONFIG`; the static-only
  build's curl-config answers `--built-shared` "no", so R consumes
  `--static-libs` (`-L<deps>/lib -lcurl -lssl -lcrypto -lz`), every
  archive resolving statically against the deps prefix. libR itself
  never links curl — `src/main/internet.c` lazy-loads the internet module, and only
  internet.so carries `$(CURL_LIBS)`
  (`src/modules/internet/Makefile.in`). The boot smoke asserts
  `capabilities("libcurl")` only — end-to-end https from inside the
  runtime is the named MANUAL verification, so CI-network flakiness
  never enters the gate.
- **`ac_cv_lib_zstd_ZSTD_versionNumber=no`** and
  **`--without-libdeflate-compression`** — both libraries join the link
  whenever a build host happens to have them (zstd has no opt-out at
  all). Pinned off for the same deterministic-closure rule; lazy-load
  databases stay gzip/xz/bzip2.

The **darwin legs** carry the same law in ld64 grammar
(`darwin_configure_env`):

- **deps tier** — only pcre2 and xz are factory-built (static, -fPIC):
  the SDK ships their stubs without the headers, so the deps stage
  provides both honestly. libz/libbz2/libcurl link DYNAMICALLY against
  macOS's own dylibs by policy (a bare macOS always carries them; the
  Mach-O provenance arm proves the closure stays system-only).
- **`CPPFLAGS=-I<deps>/include`** and
  **`PKG_CONFIG_PATH=<deps>/lib/pkgconfig`** — pcre2.h/lzma.h live
  nowhere else, and R's pkg-config probes must find the deps stage's
  `.pc` files and nothing else (a runner's Homebrew pcre2 would
  otherwise leak into the closure — the tebako-runtime-python#80
  class).
- **`CURL_CONFIG=/usr/bin/curl-config`** — macOS's own libcurl: the
  system curl-config answers `--built-shared yes`, so R consumes
  `--libs` (-lcurl, dynamic) and the deps stage builds no
  curl/openssl/zlib on this leg at all.
- **`FLIBS`** — clang's spelling of the exe-side static gfortran chain:
  `-Wl,-u,__gfortran_concat_string -lgfortran -lquadmath -lgcc -lm`,
  resolved against the `-L<static-libs>` pin (the compiler's archives,
  symlinked there). `-lgcc` closes it: libgfortran's quadmath IO
  references GCC's 128-bit soft-float routines (__divtf3/__multf3/
  __eqtf2…), which Apple's compiler-rt omits on arm64 (darwin long
  double is 64-bit) — without libgcc.a the mixed C/Fortran configure
  probe dies. `FLIBS_IN_SO=-lm` drops the chain: darwin's shlib AND
  dylib links both carry `-undefined dynamic_lookup`, so every shared
  object's gfortran references defer to load time and bind from the
  exe (ld64 needs no --export-dynamic — an exe's globals are visible to
  dlopen'd bundles by default; the provenance gate asserts
  `_gfortran_concat_string` is defined).
- **`SHLIB_LDFLAGS`/`DYLIB_LDFLAGS`** — the $ORIGIN pin's darwin
  spellings (`@loader_path/../lib` + `@loader_path/../../../lib` for
  the modules and package .so's; `@loader_path/.` for lib/R/lib's own
  dylibs), covering both shlib depths exactly as on linux.
- **the @rpath install-name fixup** (`fixup_darwin_install_names`,
  after `make install`): dyld consults LC_RPATH ONLY for dependent
  names spelled `@rpath/<name>` — R hardcodes BARE `-install_name
  libRlapack.dylib`/`libRblas.dylib` grammar, which dyld resolves
  against the cwd and its fallback dirs, never the rpath pins. The
  fixup rewrites the two dylibs' LC_ID_DYLIB to `@rpath/<name>` and
  every referencing object (libRlapack → libRblas; lapack.so, the
  library package .so's → both) with install_name_tool — the idiom
  upstream's own packaging uses (R links every target with
  `-headerpad_max_install_names` for exactly this), and the rewrite the
  exec_closure walk's @rpath arm materializes. The provenance gate's
  arm 7 re-proves lapack.so's direct `@rpath/libRblas.dylib` row; the
  boot smoke proves the dlopen end to end.

## The env image (what ships, what is pruned)

`make install DESTDIR=<stage>` is fully supported upstream (every
install line spells `$(DESTDIR)$(dir)`); with `--prefix=/__tfs__
LIBnn=lib` the tree lands at `<stage>/__tfs__`, and `R_HOME` is
`<prefix>/lib/R`. `ImageBuilder` then prunes the build-time surface:

- the prefix-level `bin/` (the build-tree Rscript launcher and the R
  front-end SHELL scripts — dead weight: a script inside the VFS cannot
  be exec'd, and the fs TU carries the front-end in C) and
  `share/` (the man pages);
- `lib/R/bin/` (`bin/exec/R` — the stock interpreter copy the shipped
  exe replaces — plus Rscript and the R CMD toolchain scripts,
  press-time surface a read-only runtime image never needs);
- `lib/R/include/` and `lib/R/doc/` (headers; the html manuals —
  per-package help lives in `library/` and stays).

The tebako surface then deploys: `lib/tebako/layout.yaml` (the era-2
layout card: mount root, `interpreter_api_version: "4.6"`, the
`mount_root_override` grant emitted ALWAYS, the `preload_shim` grant
naming the staged shim), the preload shim itself (REQUIRED — the
unpatched interpreter cannot read its own mounted image without it; a
missing shim is a hard error, never a degrade), and the L1 payload
manifest (`__tpkg__/manifest.yaml` — kind `runtime`, engine/implementation
`r`, `abi_line` the major.minor line, NO `provides.entrypoints` in the
skeleton). `tfs mkimage` packs the tree in the default limnifs format —
never a `--format` pin (that would drift from the product's default).

## The cache architecture

One cache, keyed on what it contains:

| Cache | Key | Contents |
|-------|-----|----------|
| downloads + staged link unit | `tebako-r-dl-<os>-<arch>-<hash(contract.yml, versions.yml)>-v<CACHE_VER>` | `.build/downloads` (the sha256-verified tarballs + tfs CLI) and `.build/link-unit` (the staged unit) |

`save-always: true` — a red boot smoke must never tax the next leg a
cold re-download. The key carries the pins' hashes, so a pin bump mints
a fresh entry and the stale one ages out. `CACHE_VER` stays the manual
escape hatch — bump ONLY for a build-recipe shape change under
UNCHANGED pins, and say why in the workflow comment.

## The determinism notes

Born pinned: the toolchain container digests (recorded == live proven
in preflight) and both input pins above. `SOURCE_DATE_EPOCH` follows
the ruby#381 idiom: the compute job derives ONE epoch from the HEAD
commit (`git log -1 --format=%ct` under a full-history checkout) and
every leg stamps it into the image manifest's `identity.created`
(`ImageManifest` honors it; unset falls to epoch 0), so a same-commit
re-run stamps identically. The packed image's own metadata is
deterministic the same way (tfs-cli's mkimage honors the variable).

The configure-pins section above is the second half of the story: every
"if available" probe upstream offers is either pinned off (zstd,
libdeflate), provided deterministically (zlib + OpenSSL + curl — the
deps stage's minimal static builds, themselves sha256-pinned), pinned
static (bzip2/xz/pcre2/gfortran-runtime), or compiled from R's own
pristine sources (the included BLAS/LAPACK), so two build hosts
with different incidental libraries produce the SAME artifact.

## Where each value lives (SSOT)

- Version catalog + pins (including `container_digests`):
  `contract.yml` (+ `schema/contract.schema.yml`).
- Source url/sha256 pins: `versions.yml` (cross-locked to the catalog
  by `scripts/check_contract.rb`).
- Env vocabulary (os/arch/host/container): `.github/matrix.json`.
- The feature policy (`CONFIGURE_ARGS`), the closure pins
  (`configure_env`, `prepare_static_libs_dir`), the Makefile
  substitution anchors, the mount root: `build/lib/tebako_r_builder/
  r_build.rb` and `platform.rb`.
- The front-end (the Rscript translation + the interpreter-shaped
  passthrough), the R_HOME story, the re-exec:
  `build/resources/tebako_r_main.c` (its header comment is normative).
- The boot-contract scenarios: `tools/boot_smoke`.
- This architecture: `docs/build-chain.md`.
