# AGENTS.md — tebako-runtime-r

The binding rules are the ecosystem's: **tamatebako/AGENTS.md** (the
workspace root) — read it first. The short version as applied here:

- **Draft PRs only.** No merges to `main`, no tags, no releases without
  the owner's explicit go-ahead.
- **Prebuilt artifacts flow downward.** This factory CONSUMES published
  artifacts — CRAN source tarballs (sha256-pinned in `versions.yml`)
  and the link unit + tfs CLI from the pinned tamatebako/tebako release
  (`contract.yml`). Never a source checkout of a sibling repo, in CI or
  locally; never a source build of the driver stack.
- **SSOT for versions and pins.** Versions, tags, SHAs live in
  `contract.yml` (catalog + pins), `versions.yml` (source url/sha256),
  and `.github/matrix.json` (env vocabulary) — never hardcoded in
  workflow YAML or scripts.
- **No R source patches.** The tarball ships pristine; the driver link
  and the `main`→`r_main` rename are build-time substitutions on the
  GENERATED `src/main/Makefile`
  (`build/lib/tebako_r_builder/r_build.rb`). A genuine R source need
  means a tamatebako source factory, not a factory-side hot-patch.
- **YAML** for all authored config/manifests; named errors and named
  exit codes, never silent fallbacks.

## Repo status: pre-release, full POSIX census

`tools/build_runtime` is implemented (the tebako-runtime-php
`build/lib` port, R edition): fetch/verify → configure/make → driver
link → (macOS: the @rpath install-name fixup) → env-image pack →
packaging → sidecars, gated by `ci/check_symbol_provenance.sh` and
`tools/boot_smoke`. CI carries three platform workflows
(`build-linux-gnu.yml`, `build-linux-musl.yml`, `build-macos.yml` —
thin triggers over `_build-platform.yml`: parity → compute → preflight
→ build → publish → verify) plus the static gate (`lint.yml`). The
publish pipeline (`publish.yml` + the tebako-release gem via
`scripts/release_adapter.rb` + `tools/registry_update.rb`) is present,
but **no release has been cut** — the first release is the owner's
explicit act (README's follow-ups section names the remaining
increments).

## Repo-local gotchas

- Tooling is **Ruby** (stdlib-first; gems only via `Gemfile`).
  Ecosystem §12 rules apply: autoload only, no `require_relative`, no
  `send`/`instance_variable_get`/`respond_to?` metaprogramming.
- `Gemfile.lock` is gitignored (factory convention — resolutions float).
- `contract.yml` is validated by `scripts/check_contract.rb` against
  `schema/contract.schema.yml` (`bundle exec`), including the
  driver-source parity arm (contract.yml ↔ the pinned link-unit
  release's compiled-in `TEBAKO_CONTRACT_VERSION`). A contract bump
  edits both in the same commit.
- CI containers are `ghcr.io/tamatebako/tpkg-builder-*`
  (tebako-ci-containers) only, pulled `name:tag@digest`; the archived
  v1 `tebako-<platform>` images are never referenced here. The v1 gnu
  image lacks gfortran/liblzma-dev/libpcre2-dev — the
  build leg apt-provisions them in-container (the named follow-up is
  baking them into tebako-ci-containers; `docs/build-chain.md` carries
  the detail).
- The container legs bind-mount the workspace and run as root —
  root-owned files land in `.build/` and `runtime-packages/`. The
  workflow hands them back to the runner user (`chown` at the end of
  the docker-run step); do the same locally before editing or
  `git clean`-ing.
- Local container builds need docker with the linux/amd64 platform
  (`docker run --platform linux/amd64` on arm64 hosts).
- The exe is `src/main/R.bin`, NOT Rscript — upstream's Rscript is a
  launcher that execv()s a shell script, which cannot work inside the
  VFS; the fs TU (`build/resources/tebako_r_main.c`) carries the
  front-end in C (the Rscript translation plus the interpreter-shaped
  passthrough). Read the README's exe section before touching
  the link.
- `gh pr create` bodies: always `--body-file` — inline `--body` with
  backticks executes them (ecosystem §13).
- Architecture/chain questions: `docs/build-chain.md` first, then
  README.md. If you change a workflow, the build tooling, the matrix,
  or a cache key, update `docs/build-chain.md` in the same PR.
