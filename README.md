# tebako-runtime-r

The R runtime factory for the tebako ecosystem (v2): builds tebako **R
runtimes** — the spec-17 driver linked into the R interpreter — from
pristine CRAN release tarballs, in the pinned tpkg-builder containers,
for every platform the matrix declares.

**Status: pre-release, full POSIX census.** Five legs (linux-gnu
x86_64, linux-musl x86_64/aarch64, macOS x86_64/arm64), one R line
(4.6.x, catalog `4.6.2`), the publish/sign/registry pipeline wired
(publish.yml + the tebako-release machinery). No release has been cut —
the first release is the owner's explicit act, and everything lands
through draft PRs (the ecosystem's hard rule: nothing touches `main`,
tags, or releases without the owner's explicit go-ahead). The
follow-ups section names the next increments.

## The wedge: CI / headless Rscript

The runtime's entry surface is **Rscript semantics only**: the exe is a
script/expression runner (`-e expr`, `--file=`, trailing args via
`commandArgs(TRUE)`), aimed at CI jobs and headless data/validation
pipelines. There is no interactive/IDE surface in scope (no RStudio
integration, no readline line editing), and **no CRAN marketplace
inside the image**: like the pydata lane, payloads stage their package
closure at press time — the runtime ships R's base packages, and a
payload that needs more carries its library tree in its own image.

## Source build, not prebuilt — the decision and the evidence

This factory **builds R from source** (CRAN's release tarballs,
sha256-pinned in `versions.yml`). The prebuilt alternatives all fail
the ecosystem's audience rule (a user RUNNING tebako packages needs no
compilation machinery and no libraries beyond the platform's own):

- **CRAN ships Windows and macOS binaries only.** Linux has no CRAN
  binary at all — linux R is distro-package territory (apt/dnf) or
  third-party builds. There is nothing to repack for the leg this
  skeleton ships.
- **Distro and third-party linux builds NEED distro libraries.** The
  Posit/rig prebuilt linux builds dynamically link libicu, libcurl,
  and friends — every one a library a bare target system does not
  carry. Repacking them would ship exactly the runtime dependency the
  audience rule forbids.
- **A source build in the tpkg-builder container proved tractable.** R
  is autotools (`configure && make && make install`), the container
  already carries gcc/make, and the only additions R 4.6 needs are
  gfortran (the internal LAPACK is Fortran), liblzma-dev, and
  libpcre2-dev (R 4.6 dropped its bundled xz/pcre2) — provisioned
  in-leg today,
  with baking them into tebako-ci-containers the named follow-up. A
  source build is also the only path that controls the link closure
  deterministically (the static-archive pins in
  `docs/build-chain.md`).

## The exe is R.bin with the Rscript front-end compiled in — not a wrapper

Upstream's `Rscript` (src/unix/Rscript.c) is not the interpreter: it is
a tiny launcher that execv()s `<R_HOME>/bin/R`, a **shell script**, which
execs `R_HOME/bin/exec/R` in turn. A shell script inside the VFS cannot
be exec'd — the kernel's `#!` read never reaches the preload shim — so
the launcher shape cannot survive the mount, and no wrapper can fix that
from outside.

The tebako runtime exe is therefore the interpreter binary itself
(`src/main/R.bin`), with two build-time changes (substitutions on the
**generated** `src/main/Makefile` — never a source patch; the CRAN
tarball ships pristine):

1. `Rmain.c`'s `main` is renamed `r_main` at compile time
   (`-Dmain=r_main`).
2. The factory's fs TU (`build/resources/tebako_r_main.c`) joins the
   link: it provides the real `main`, boots the spec-17 driver,
   emulates the Rscript front-end in C (ported from Rscript.c:
   `--no-echo --no-restore` prepended; `-e` pairs through;
   `--default-packages=` / `R_SCRIPT_DEFAULT_PACKAGES` /
   `R_SCRIPT_LEGACY` semantics; the first bare argument becomes
   `--file=`, the rest follow `--args`; lone `--help`/`--version`
   print and exit **without touching R**), and re-execs itself under
   the driver-armed preload shim when the boot mounted anything.

The exe merges upstream's TWO entry binaries, so the front-end
discriminates first: an interpreter-shaped argv (dashed options only,
no bare file token, no Rscript-only flag) passes through to `r_main`
untouched — upstream `exec/R` reads stdin when no `--file` names a
script, and R's own build leans on exactly that (basepkg.mk pipes
generated code into `bin/R --vanilla --no-echo` = this binary for every
lazy-load DB). The driver's handoff always arrives Rscript-shaped
(spec 17 rewrites argv to the interpreter convention: the resolved
entry as the script arg, then the user's args verbatim), so a bare-led
argv translates. `-e` pairs work on both arms.

The version banner reads the build's own generated `<Rversion.h>` — the
same header upstream Rscript.c prints from — so the exe's `--version`
can never drift from the interpreter it carries.

## The unpatched interpreter: preload shim + re-exec + R_HOME

There is no tamatebako source factory for R (yet): the interpreter is
**unpatched**, so its libc file IO cannot see the driver's mounts. The
visibility story is spec 22's tier-1 preload interposition, in two
process incarnations (the php/python factories' model):

1. the first incarnation boots the driver in-process
   (`tebako_driver_boot` — mounts the env image from
   `TEBAKO_RUNTIME_IMAGE` and every `--tebako-image` payload triple,
   verifies the layout card, applies the jail, rewrites argv to the
   resolved entry);
2. when the boot mounted anything, the fs TU re-execs itself with the
   Rscript-translated argv and the driver-armed env (`LD_PRELOAD` +
   `TEBAKO_PRELOAD_SHIM` + `TEBAKO_TFS_MOUNTS`); the shim's constructor
   re-mounts the serialized mount table in the child, and the child's
   `r_main` runs with its libc IO served from the VFS.

`exec/R` locates its home from the `R_HOME` environment variable
(src/main/sysutils.c `R_HomeDir`). With the env image mounted, the fs
TU exports `R_HOME=<effective root>/lib/R`, where the effective root is
the driver's validated `TEBAKO_MOUNT_ROOT` override when given, else
the baked mount root (`/__tfs__`). Bare boots leave `R_HOME` alone: the
interpreter's own `Fatal error: R home directory is not defined` (exit
2) names that honestly, while the lone `--help`/`--version` fast paths
still answer (upstream Rscript semantics — they never touch R). The
boot smoke pins all three behaviors.

## The feature set (the honest headless minimum)

`RBuild::CONFIGURE_ARGS` is the policy; every disable is a deliberate
closure decision (a library a bare system does not carry) or a wedge
decision (an interactive surface), and the build-chain doc maps each
one:

| Knob | Value | Why |
|---|---|---|
| X11 / cairo / png / jpeg / tiff / tcltk | off | The graphics surfaces beyond `pdf()`/`postscript()` are the named graphics increment; each drags a host library stack a bare system lacks |
| readline | off | Interactive/IDE surface; would drag libtinfo into the closure |
| ICU | off | Collation falls back to R's own; libicu is not on a bare system |
| OpenMP | off | libgomp is not on a bare system; the parallel increment revisits with a static libgomp |
| NLS | off | The translation catalogs are the interactive surface; and on musl the NLS probe links gettext's libintl into the exe (glibc folds gettext into libc, so gnu never leaks it) — off uniformly, one feature set on every leg |
| libR as a shared lib | off | `R.bin` links libR **statically** — the exe must start standalone to boot the driver |
| BLAS | static objects (R's own) | R.bin's appl objects call BLAS directly, and upstream builds its *included* BLAS only as the shared `libRblas.so` — an exe that NEEDs it cannot boot the driver (ld.so resolves NEEDED before `main()`, before any mount). The Makefile substitution links the included BLAS's *objects* into R.bin instead (the same objects libRblas.so carries); `libRblas.so`/`libRblas.dylib` still ships in `lib/R/lib` for libRlapack, resolved through the dylib `$ORIGIN`/`@loader_path` rpath |
| LAPACK | in-image shared | R's included LAPACK builds as `lib/R/lib/libRlapack.{so,dylib}`, reached only through the dlopen'd lapack module (never at exec) and resolved through the `$ORIGIN`/`@loader_path` rpath (two entries cover both shlib depths — `lib/R/modules` and `lib/R/library/<pkg>/libs`); the lapack module loads libRblas **directly** (linux: substitution 5's `--no-as-needed` pin — the toolchain's spec default would drop the reference-free library; darwin: ld64 records every linked dylib, and the install-name fixup respells the rows `@rpath/` — dyld consults LC_RPATH only for @rpath names — and the exec_closure walk materializes only direct dependencies); a system/vendor LAPACK opt-in is follow-up |
| libcurl | static (factory-built) | R 4.6 requires libcurl with https — no `--without-libcurl` exists upstream. The factory builds a minimal static libcurl itself (http/https/ftp only, TLS via the factory-built static OpenSSL 3 LTS — Apache-2.0, providers built in; the container's OpenSSL 1.1.1 is EOL), nothing else — the distro libcurl's encumbered closure never enters. https works from inside the runtime and the closure stays static |
| libzstd / libdeflate | pinned off | Same deterministic-closure rule (both join the link whenever a build host happens to have them); lazy-load databases stay gzip/xz/bzip2 |
| zlib | static (factory-built) | R links `-lz` into internet.so, a shared object, and the toolchain's `libz.a` carries no PIC (ld rejects it in a shared link) — the factory builds its own -fPIC static zlib and the `-L` pin fronts it for every `-lz` |
| bzip2 / xz / pcre2 | static | R 4.6 requires them and links them dynamically by default; the factory fronts the link with a `-L` dir of the static archives so the exe NEEDs none of them (the provenance gate proves it) |
| gfortran runtime | static (exe-side) | The internal LAPACK is Fortran and libgfortran is not on a bare system. R's LAPACK references exactly one gfortran symbol (`_gfortran_concat_string`): the exe carries the chain statically (the `FLIBS` pin resolves `-lgfortran -lquadmath` against the `-L` dir's archives) and exports the symbol via `--export-dynamic`; `libRlapack.so` records no gfortran NEEDED and binds the symbol from the exe at dlopen (`FLIBS_IN_SO` drops `-lgfortran` — focal's `libgfortran.a` is non-PIC and can never enter a shared object) |
| recommended packages (MASS class) | off | Payload-closure territory — staged at press time, never baked into the runtime image |

What **is** in the image: the full base-package set (base, methods,
datasets, utils, grDevices, graphics, stats — plus compiler, tools,
parallel, splines, stats4, tcltk-free grid/lattice), the `pdf()` /
`postscript()` devices, the `internet` module (http/https/ftp via the
factory-built static libcurl — CA discovery follows the OpenSSL
defaults, `SSL_CERT_FILE`/`SSL_CERT_DIR` override), R's own BLAS (its
objects statically linked into the exe; `libRblas.so` beside it in
`lib/R/lib` for `libRlapack.so`), and R's included
LAPACK (`libRlapack.so` in `lib/R/lib`).

## The artifacts (per version × triplet)

One build emits the image-era pair plus sidecars, under
`runtime-packages/`:

- `tebako-runtime-<tebako>-r-<r>-<host_id>` — the interpreter exe with
  the driver linked in (tebako#716's language segment from this
  factory's first line — R has no pre-#716 lines, so no era gate);
- `…​.tfs` — the env image (the pruned install tree: `lib/R` without
  `bin/`, `include/`, `doc/`; the prefix-level `bin/`/`share/` dropped)
  plus `lib/tebako/layout.yaml` (the era-2 layout card, with the
  `mount_root_override` grant), the preload shim, and the L1 payload
  manifest (`__tpkg__/manifest.yaml`) — packed by `tfs mkimage` in the
  default limnifs format;
- `…​.tfs.sha256` — the store-shape trust sidecar (never uploaded);
- `…​.abi` — the abi facet (`4.6` — R's C ABI is source-level and CRAN
  binary repositories build per minor line, so the major.minor line is
  the honest granularity);
- `…​.contract.yaml` — the era-2 provenance card (mount root, consumed
  tarball + sha256, the compile flags read back from the generated
  Makeconf, the link unit consumed).

The skeleton declares **no** `provides.entrypoints` (no spawn surface):
R ships no console-script ecosystem of its own in this configuration —
that arrives with the payload/CRAN-closure increment.

## The flow

```
tools/build_runtime --r 4.6.2
  1. fetch + verify    the CRAN tarball (versions.yml's sha256 pins)
  2. link unit + tfs   download + verify the pinned tamatebako/tebako
                       release's link unit (the driver + scoped tfs +
                       native closure) and tfs CLI
  3. configure + make  R (autotools; the generated-Makefile substitution
                       lands the fs TU + the -Dmain=r_main rename)
  4. env image         prune the staged install, deploy layout card +
                       preload shim + L1 manifest, tfs mkimage
  5. package + sidecars (above)
ci/check_symbol_provenance.sh   the linked-driver + closure gates
tools/boot_smoke                bare/boot/payload/compute-floor/
                                bad-mount/mount-root scenarios
```

## Matrix grammar

`.github/matrix.json` carries the env vocabulary (five rows:
`ubuntu-22.04` × `tpkg-builder-x86_64-linux-gnu` × `linux-gnu` ×
`x86_64`; `ubuntu-22.04` × `tpkg-builder-x86_64-linux-musl` ×
`linux-musl` × `x86_64`; `ubuntu-22.04-arm` ×
`tpkg-builder-aarch64-linux-musl` × `linux-musl` × `arm64`;
`macos-15-intel` × `macos` × `x86_64`; `macos-15` × `macos` × `arm64` —
the linux legs docker-run the pinned tpkg-builder image, the macOS legs
are runner-native on the runner's CLT + Homebrew gfortran);
`scripts/compute_matrix.rb` crosses it with the contract's version sets
under the dispatch filters (`R_FILTER`, `PLATFORM_FILTER`,
`ARCH_FILTER`) and emits the legs. `build-linux-gnu.yml`,
`build-linux-musl.yml`, and `build-macos.yml` are the thin triggers;
`_build-platform.yml` runs parity → compute → preflight → build →
publish → verify. `publish.yml` is the release coordinator (per-leg
publish + sign from `_build-platform.yml`, then the one release job:
the whole-matrix audit, the registry render, the bot PR, the aggregate
nudge).

## The publish pipeline

The tebako-release machinery pin rides `contract.yml`'s
`release_tooling` (the Gemfile reads it — the SSOT), adapted by
`scripts/release_adapter.rb` (the R grammar: version lines, the
`r` language segment, this repo's coordinates). Each leg's publish job
uploads its write-once names (payload + `.sha256` sidecars +
`.manifest.json` shard) and signs every served name (gated on
`TEBAKO_RELEASE_SIGNING_ENABLED` / `…_KEYID` /
`TEBAKO_RELEASE_SIGNING_KEY`); the macOS legs sign + notarize the exe
in-leg first (spec 31, `ci/macos-sign-notarize-runtime.sh`, gated on
`APPLE_SIGNING_ENABLED` — sign-then-hash: every downstream gate and the
`.sha256` anchor the exact signed bytes). `tools/registry_update.rb`
renders the registry mirror from the release's shards (spec 04 §2) and
the coordinator lands it on main by bot PR + auto-merge.

## contract.yml — the pins

- `contract_version: 2` — R runtimes are image-era from the first
  build; the driver-source parity arm locks it to the consumed link
  unit's compiled-in `TEBAKO_CONTRACT_VERSION`.
- `container_version` + `container_digests` — the tpkg-builder line,
  tag and immutable ghcr digests; preflight proves recorded == live
  before any leg spends compute.
- `link_unit_release` — the tamatebako/tebako release whose link unit
  and tfs CLI the legs consume (no source build of the driver stack,
  ever).
- `r.catalog/full/tidy` — the R versions this factory builds;
  `versions.yml` pins each one's source url + sha256 + line, and the
  contract gate cross-locks the two files both directions.

## Layout

```
build/lib/tebako_r_builder/   the build model (one class per concern)
build/resources/tebako_r_main.c   the fs TU template
ci/check_symbol_provenance.sh     the symbol + closure gates
docs/build-chain.md               architecture and invariants
schema/contract.schema.yml        the contract grammar
scripts/versions                  the catalog/pin reader
scripts/compute_matrix.rb         the leg planner
scripts/check_contract.rb         the contract gate
tools/build_runtime               the build entry
tools/boot_smoke                  the acceptance smoke
contract.yml / versions.yml       the pins (SSOT)
```

## Follow-ups (the named next increments)

- **Windows** (ucrt x64 — evaluated, deferred as a materially different
  fight): R on windows does NOT build through autotools — it builds
  through `src/gnuwin32`'s hand-maintained Makefiles with an
  `MkRules.local` feature sheet, so this factory's
  configure/substitution layer grows a whole second build driver, not a
  flag. The toolchain is Rtools/MSYS2 ucrt plus the prebuilt extsoft
  bundle (a different provisioning story than the POSIX deps stage),
  the gfortran/BLAS closure needs its own static proof under mingw
  (libgfortran/libquadmath exist as static archives in Rtools, but the
  PE loader has no rpath — the spec 22 PE walk + the spec 17 §7
  materialize tier serve the deps from the extracted tree), and the exe
  surface differs (Rterm.exe/Rscript.exe are both native — no
  shell-script wedge on windows, but the fs TU grows its windows
  branch then). The python/ruby factories prove the tier; the R
  gnuwin32 driver is the named blocker.
- **Toolchain baking**: gfortran + liblzma-dev + libpcre2-dev (gnu),
  gfortran + the -static splits + tzdata (musl) into the tpkg-builder
  images (tebako-ci-containers), retiring the in-leg provisioning.
- **The recommended-packages decision**: ship the MASS-class set as a
  first-class payload slice (press-time composition) rather than in the
  runtime image.
- **The CRAN-closure / census lane**: payload-side library trees staged
  at press time (the pydata analog) and the spawn surface
  (`provides.entrypoints`) for R scripts.
- **Graphics/parallel increments**: cairo devices, OpenMP with a static
  libgomp, system/vendor BLAS as an opt-in build variant — each
  closure-audited the same way.
- **The boot-contract parity spec/** (rspec), and a hello-runtimes arm
  once payloads exist.
- **The first release**: an operator act — bump `VERSION`, dispatch
  `publish.yml` (r_filter=full, platform=all, publish=true), and the
  pipeline builds, signs, audits, and renders the registry.
