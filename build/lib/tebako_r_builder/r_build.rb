# frozen_string_literal: true

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

require "fileutils"

module TebakoRBuilder
  # The relocatable R build (tools/build_runtime phases 3-4): the pristine
  # CRAN tarball is extracted, configured, and built IN TREE (the extracted
  # copy is this factory's scratch — never a published input), and the
  # spec-17 driver is linked into the R interpreter exe (src/main/R.bin)
  # by build-time substitutions on the GENERATED src/main/Makefile (the
  # php factory's generated-Makefile analog — a build-file edit, never a
  # source patch; the CRAN tarball ships pristine):
  #
  #   * an explicit Rmain.o rule is added compiling $(srcdir)/Rmain.c with
  #     -Dmain=r_main, renaming the interpreter's entry point at compile
  #     time (Rmain.o otherwise rides the generic .c.o suffix rule, which
  #     the substitution leaves untouched — an explicit target rule wins
  #     over the suffix rule);
  #   * the $(R_binary) link recipe gains tebako_r_main.o between
  #     $(R_bin_OBJECTS) and $(R_bin_LDADD) and $(TEBAKO_LIBS) last (the
  #     fs TU — build/resources/tebako_r_main.c — providing the real main,
  #     which boots the driver, applies the front-end (Rscript-shaped
  #     argv translates; interpreter-shaped passes through — R's own
  #     build invokes the exe the interpreter way), and re-execs; TEBAKO_LIBS is the scoped driver + tfs + closure,
  #     Mlibs);
  #   * the $(R_binary) rule gains the fs TU object and the BLAS objects
  #     as prerequisites, and the factory appends the fs TU's compile
  #     rule + the TEBAKO_LIBS and BLAS_STATIC_OBJS variables under a
  #     marker comment;
  #   * the EXTRA_LIBS line's $(BLAS_LIBS) becomes $(BLAS_STATIC_OBJS) —
  #     R.bin links R's own included BLAS as objects (substitute_makefile's
  #     comment — upstream builds that BLAS ONLY as the shared
  #     libRblas.so, and an R.bin that NEEDs it could never boot the
  #     driver, because ld.so resolves NEEDED before main(), before any
  #     mount exists);
  #   * and on the GENERATED src/modules/lapack/Makefile (substitution
  #     5): the module link's -lRblas is wrapped in --no-as-needed so
  #     lapack.so records libRblas.so as a DIRECT NEEDED — the
  #     toolchain's spec-default --as-needed would drop the
  #     reference-free library, and the exec_closure walk (crates/tfs)
  #     materializes only the dlopen'd object's DIRECT dependencies,
  #     resolved through its own rpaths.
  #
  # R's generated src/main/Makefile is the durable substitution target
  # ONLY after one countermeasure: upstream's Makefile self-regeneration
  # rule names ../include/Rversion.h and ../include/config.h as
  # prerequisites, and R's build re-stamps Rversion.h during make — so
  # make re-runs config.status mid-build and REGENERATES the Makefile,
  # silently wiping the driver link (the plain-interpreter shadow, the
  # ci gate's named class). Substitution 3 below collapses that rule to
  # the two stable prerequisites: the anchors then match exactly once
  # and stay matched, a deliberate re-configure still regenerates
  # (config.status newer) and this pass re-applies (the marker check),
  # and an R whose build grammar drifted is a named error, never a
  # half-applied edit.
  #
  # Before configure, the deps stage builds the libraries the shipped
  # closure needs but no honest artifact can take from the toolchain or
  # OS (build_deps): on the linux legs, the -fPIC static zlib (R links
  # -lz into internet.so, a shared object, and the focal toolchain's
  # libz.a carries no PIC — build_zlib's comment); the static OpenSSL 3
  # (LTS, Apache-2.0) that curl 8.23 requires (the focal toolchain
  # carries only the EOL 1.1.1, and a bare musl target carries no
  # libssl at all); and the minimal static libcurl that R 4.6
  # hard-requires — R_LIBCURL has no opt-out, and the distro libcurl's
  # LGPL/GPL-encumbered closure is exactly what must not ship. On the
  # macOS legs the tier is pcre2 + xz instead: R 4.6 dropped its bundled
  # copies, and the macOS SDK ships the .tbd stubs WITHOUT the
  # pcre2.h/lzma.h headers, so the system dylibs are unprobe-able and a
  # Homebrew find is tebako-runtime-python#80's leak class — while
  # libz/libbz2/libcurl are macOS's own (SDK stub + header + the dyld
  # cache on every bare macOS) and link dynamically by design. See the
  # build_* comments.
  #
  # The shipped exe is the build tree's src/main/R.bin — NOT Rscript:
  # upstream's Rscript is a launcher that execv()s R_HOME/bin/R, a SHELL
  # script (which execs R_HOME/bin/exec/R in turn), and a script inside
  # the VFS cannot be exec'd (the kernel's #! read never reaches the
  # preload shim). The fs TU therefore carries the front-end (Rscript
  # translation for Rscript-shaped argv; passthrough for the
  # interpreter-shaped, which is how R's own build invokes the exe) and
  # the exe IS the R binary — README's exe section.
  class RBuild
    MARKER = "# --- tebako: the fs TU + driver link (factory substitution) ---"

    # The lapack module Makefile's marker (substitute_lapack_makefile —
    # substitution 5: --no-as-needed around the module link's -lRblas so
    # lapack.so records libRblas.so as a DIRECT NEEDED despite the
    # toolchain's spec-default --as-needed; the exec_closure walk
    # materializes only direct dependencies).
    LAPACK_MARKER = "# --- tebako: record libRblas on lapack.so (factory substitution) ---"

    # The configure line — README's feature policy: the honest minimal set
    # for headless CI use. --without-x (no X11 module; the graphics
    # surfaces beyond pdf()/postscript() — cairo png()/jpeg()/tiff(),
    # tcltk — are the named graphics increment), --with-readline=no (line
    # editing is the interactive/IDE surface, outside the wedge; readline
    # would also drag libtinfo into the closure), --with-ICU=no
    # (collation falls back to R's own; ICU would drag libicu into the
    # closure), --disable-openmp (libgomp is not on a bare system — the
    # audience rule; the parallel increment revisits with a static
    # libgomp), --disable-R-shlib (R.bin links libR STATICALLY — the exe
    # must start standalone to boot the driver, before any shim exists
    # to serve libR.so), --without-blas (R's own included BLAS — the
    # linux defaults already deliver it since no system BLAS exists in
    # the containers, but on darwin the external-BLAS search would find
    # Apple's Accelerate and fork the BLAS story per platform; the pin
    # keeps ONE story everywhere: upstream builds the included BLAS ONLY
    # as the shared libRblas (.so/.dylib), so R.bin cannot
    # consume it through BLAS_LIBS — an exe that NEEDs libRblas could
    # never boot the driver, because the loader resolves NEEDED before
    # main(), before any mount exists. Substitution 4 instead links the
    # BLAS objects themselves into R.bin — the same objects libRblas
    # carries, built before src/main in R's own SUBDIRS order — and
    # libRblas still builds and ships in lib/R/lib for libRlapack,
    # resolved post-mount through the dylib rpath), --without-lapack
    # (R's included LAPACK, built as libRlapack and resolved
    # post-mount through the dylib rpath — LAPACK is only ever reached
    # through the dlopen'd lapack module, never at R.bin's exec),
    # --without-libdeflate-compression (deterministic:
    # otherwise a build host with libdeflate-dev produces a different
    # artifact than one without — the python#80 shape; zlib serves
    # lazy-load compression), --disable-nls (the translation catalogs
    # are the interactive surface, outside the wedge; and on musl the
    # NLS probe links gettext's libintl.so.8 INTO R.bin — glibc folds
    # gettext into libc so the gnu leg never leaks it, but a bare musl
    # target cannot satisfy libintl (the audience rule), so NLS is off
    # uniformly, one feature set on every leg),
    # --with-recommended-packages=no (the
    # MASS-class set is payload-closure territory, staged at press time
    # like pydata — README's limits section).
    CONFIGURE_ARGS = %w[
      --without-x
      --with-readline=no
      --with-ICU=no
      --without-cairo
      --with-tcltk=no
      --with-libpng=no
      --with-jpeglib=no
      --with-libtiff=no
      --disable-openmp
      --disable-R-shlib
      --disable-nls
      --without-blas
      --without-lapack
      --without-libdeflate-compression
      --with-recommended-packages=no
    ].freeze

    def initialize(platform:, r_version:, prefix:, tarball:, src_sha256:, # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength
                   link_unit:, link_unit_dir:, repo_root:, jobs: nil, macos_deployment_target: nil)
      @platform = platform
      @r_version = r_version
      @r = TebakoRBuilder::RVersion.new(r_version)
      @prefix = prefix
      @tarball = tarball
      @src_sha256 = src_sha256
      @link_unit = link_unit
      @link_unit_dir = link_unit_dir
      @repo_root = repo_root
      @jobs = jobs
      @macos_deployment_target = macos_deployment_target
      @dep_sources = []
    end

    attr_reader :src_dir, :stage_dir

    def run
      TebakoRBuilder::BuildHelpers.with_env(floor_env) do
        extract
        build_deps
        configure
        substitute_makefile
        write_fs_tu
        make
        install
        fixup_darwin_install_names
      end
      self
    end

    # The built interpreter exe in the build tree (the driver-linked one):
    # src/main/R.bin (installed as R_HOME/bin/exec/R by the stock install;
    # the image prunes that copy — the exe ships BESIDE the image).
    def exe_path
      File.join(src_dir, "src", "main", "R.bin")
    end

    # The runtime's abi facet (the release shard's additive `abi` key):
    # the R major.minor line (RVersion#abi_line's comment: R's C ABI is
    # source-level, CRAN binary repos build per minor line).
    def abi
      @r.abi_line
    end

    # The factory-built dependency sources the shipped closure contains
    # (the deps stage) — [{name, sha256}] entries the Builder folds into
    # the contract card's built_from.sources, same grammar as the R
    # tarball's own entry.
    attr_reader :dep_sources

    # The compile flags the build ACTUALLY runs with, read back from the
    # generated Makeconf's CFLAGS (the recipe's own record — the contract
    # card's built_from.cflags; available post-configure). The read-back
    # doubles as the build-side gate against the env-clobber class
    # (configure_env's comment): a Makeconf whose compile flags carry no
    # -O option fails the build here, never at the boot smoke. Public:
    # Builder folds it into the package's .contract.yaml card.
    def recorded_cflags
      line = File.read(File.join(src_dir, "Makeconf"))[/^CFLAGS = (.*)$/, 1]
      unless line
        raise TebakoRBuilder::Error.new(
          "no CFLAGS line in the generated Makeconf — this R's build grammar drifted", 103
        )
      end
      if (line.split & %w[-O0 -O1 -Og -Od]).any? || line.split.grep(/\A-O[23]\z/).empty?
        raise TebakoRBuilder::Error.new(
          "the generated Makeconf compiles R with no -O2/-O3 (CFLAGS=#{line.inspect}) — " \
          "a slow build ships green under a boot-only gate (the env-clobber class, " \
          "tebako-runtime-python#79); configure_env pins the flags", 103
        )
      end
      line
    end

    private

    def mlibs
      @mlibs ||= TebakoRBuilder::Mlibs.new(platform: @platform, link_unit: @link_unit,
                                           link_unit_dir: @link_unit_dir)
    end

    def ncores
      @jobs || @platform.ncores
    end

    def src_parent
      File.join(@prefix, "src")
    end

    def tree_name
      "R-#{@r.base_version}-src"
    end

    def extract
      @src_dir = File.join(src_parent, tree_name)
      marker = File.join(src_parent, ".#{tree_name}.src-sha256")
      if File.directory?(@src_dir) && File.file?(marker) && File.read(marker).strip == @src_sha256
        puts "-- R source #{@r_version} already extracted (sha256 #{@src_sha256})"
        return
      end

      FileUtils.rm_rf(@src_dir, secure: true)
      FileUtils.mkdir_p(src_parent)
      # A crashed extract's staging leftover is reclaimed FIRST — tar
      # onto a non-empty dir would keep files the tarball no longer
      # carries (debris, not a pristine tree).
      FileUtils.rm_rf(staging_parent, secure: true)
      TebakoRBuilder::BuildHelpers.run_with_capture(
        ["tar", "-xzf", @tarball, "-C", staging_parent]
      )
      staged = File.join(staging_parent, "R-#{@r.base_version}")
      unless File.directory?(staged)
        raise TebakoRBuilder::Error.new(
          "#{@tarball} did not extract to R-#{@r.base_version} under #{staging_parent}", 103
        )
      end
      FileUtils.mv(staged, @src_dir)
      FileUtils.rm_rf(staging_parent, secure: true)
      File.write(marker, "#{@src_sha256}\n")
    end

    # The extraction staging dir (sibling of the build trees; extract
    # reclaims it before every unpack and removes it after the rename).
    def staging_parent
      dir = File.join(src_parent, ".extract-staging")
      FileUtils.mkdir_p(dir)
      dir
    end

    # The deps stage (the class comment): the factory-built libraries
    # the shipped closure needs but no honest artifact can consume from
    # the toolchain or OS. The linux legs build zlib first (curl's own
    # --static-libs names -lz), then OpenSSL (curl links against it),
    # then libcurl (their comments carry the why); pcre2/xz ride the
    # toolchain's -dev packages there (apt on gnu, apk on musl — the
    # in-leg provisioning). The macOS legs build pcre2 + xz instead (the
    # SDK ships the stubs without the headers — build_pcre2's comment)
    # and link libz/libbz2/libcurl against macOS's own dylibs (the
    # audience rule allows the platform's own libraries; the provenance
    # gate's Mach-O arm proves the closure stays system-only). Runs
    # before configure so configure_env's pins name real files; the
    # unsupported-leg gate lives in configure.
    def build_deps
      if @platform.linux?
        build_zlib
        build_openssl
        build_curl
      elsif @platform.macos?
        build_pcre2
        build_xz
      end
    end

    def deps_prefix
      File.join(@prefix, "deps")
    end

    def deps_src_dir
      File.join(deps_prefix, "src")
    end

    def curl_config
      File.join(deps_prefix, "bin", "curl-config")
    end

    def deps_libz
      File.join(deps_prefix, "lib", "libz.a")
    end

    # The -fPIC static zlib (versions.yml's deps: pin). R links -lz into
    # internet.so, a SHARED object, and the focal toolchain's static
    # libz.a is compiled without -fPIC — ld rejects its relocations in a
    # shared link, so the distro has nothing honest to offer (the same
    # class as OpenSSL below). The deps stage builds zlib itself:
    # --static (archives only), -fPIC throughout. prepare_static_libs_dir
    # fronts this libz.a for every -lz — libR's LIBS and internet.so's
    # CURL_LIBS alike resolve here, never against the toolchain's.
    def build_zlib
      fetcher = TebakoRBuilder::SourceFetcher.new(cache_dir: File.join(@prefix, "downloads"))
      (tarball, sha256) = fetcher.fetch_dep("zlib")
      tree = File.basename(tarball).sub(/\.tar\.gz\z/, "")
      @dep_sources << { "name" => File.basename(tarball), "sha256" => sha256 }
      marker = File.join(deps_prefix, ".#{tree}.built-sha256")
      if File.file?(deps_libz) && File.file?(marker) && File.read(marker).strip == sha256
        puts "-- #{tree} already built (sha256 #{sha256})"
        return
      end

      puts "-- Building #{tree} (static, -fPIC, sha256 #{sha256})"
      zlib_src = File.join(deps_src_dir, tree)
      FileUtils.rm_rf(zlib_src, secure: true)
      FileUtils.mkdir_p(deps_src_dir)
      TebakoRBuilder::BuildHelpers.run_with_capture(["tar", "-xzf", tarball, "-C", deps_src_dir])
      unless File.directory?(zlib_src)
        raise TebakoRBuilder::Error.new("#{tarball} did not extract to #{tree} under #{deps_src_dir}", 103)
      end

      begin
        TebakoRBuilder::BuildHelpers.run_with_capture(
          ["./configure", "--static", "--prefix=#{deps_prefix}"],
          env: { "CFLAGS" => "-O3 -fPIC" }, chdir: zlib_src
        )
      rescue TebakoRBuilder::Error => e
        raise TebakoRBuilder::Error.new("'build_runtime' deps stage (zlib configure) failed: #{e.message}", 103)
      end
      begin
        TebakoRBuilder::BuildHelpers.run_with_capture(["make", "-j", ncores.to_s], chdir: zlib_src)
        TebakoRBuilder::BuildHelpers.run_with_capture(["make", "install"], chdir: zlib_src)
      rescue TebakoRBuilder::Error => e
        raise TebakoRBuilder::Error.new("'build_runtime' deps stage (zlib build) failed: #{e.message}", 104)
      end

      File.write(marker, "#{sha256}\n")
      puts "   ... #{deps_libz} installed"
    end

    # The static OpenSSL 3 (versions.yml's deps: pin — the LTS line,
    # Apache-2.0: license-clean for static linking, unlike the LGPL TLS
    # stacks). curl 8.23 requires OpenSSL >= 3.0 and the focal toolchain
    # image carries only the EOL 1.1.1, so the distro has nothing honest
    # to offer (the musl image is newer, but a bare musl target carries
    # no libssl at all — the audience rule answers both legs the same
    # way) — the factory builds its own. no-shared (static archives
    # only), no-module + no-dso (the providers are built INTO libcrypto
    # — a module build would dlopen them at runtime from the BUILD
    # machine's <prefix>/lib/ossl-modules, a path that exists nowhere
    # on the user's system or inside the VFS), no-tests (build time).
    # -fPIC: libssl.a/libcrypto.a link into internet.so, a shared
    # object. --openssldir names the layout baked at runtime
    # (X509 default cert file/dir resolve there; SSL_CERT_FILE/
    # SSL_CERT_DIR override at run time) — the debian layout on the gnu
    # leg (/usr/lib/ssl → /etc/ssl/certs, exactly as the distro's own
    # OpenSSL behaves), the alpine layout on the musl leg (/etc/ssl).
    # install_sw touches only the container's own filesystem there,
    # never the bind mount.
    def build_openssl
      fetcher = TebakoRBuilder::SourceFetcher.new(cache_dir: File.join(@prefix, "downloads"))
      (tarball, sha256) = fetcher.fetch_dep("openssl")
      tree = File.basename(tarball).sub(/\.tar\.gz\z/, "")
      @dep_sources << { "name" => File.basename(tarball), "sha256" => sha256 }
      marker = File.join(deps_prefix, ".#{tree}.built-sha256")
      if File.file?(File.join(deps_prefix, "lib", "libssl.a")) &&
         File.file?(marker) && File.read(marker).strip == sha256
        puts "-- #{tree} already built (sha256 #{sha256})"
        return
      end

      puts "-- Building #{tree} (static, providers built in, sha256 #{sha256})"
      openssl_src = File.join(deps_src_dir, tree)
      FileUtils.rm_rf(openssl_src, secure: true)
      FileUtils.mkdir_p(deps_src_dir)
      TebakoRBuilder::BuildHelpers.run_with_capture(["tar", "-xzf", tarball, "-C", deps_src_dir])
      unless File.directory?(openssl_src)
        raise TebakoRBuilder::Error.new("#{tarball} did not extract to #{tree} under #{deps_src_dir}", 103)
      end

      begin
        TebakoRBuilder::BuildHelpers.run_with_capture(
          ["perl", "Configure", openssl_configure_target,
           "--prefix=#{deps_prefix}", "--libdir=lib", "--openssldir=#{openssl_ca_dir}",
           "no-shared", "no-module", "no-dso", "no-tests", "-fPIC"],
          chdir: openssl_src
        )
      rescue TebakoRBuilder::Error => e
        raise TebakoRBuilder::Error.new("'build_runtime' deps stage (OpenSSL Configure) failed: #{e.message}", 103)
      end
      begin
        TebakoRBuilder::BuildHelpers.run_with_capture(["make", "-j", ncores.to_s], chdir: openssl_src)
        TebakoRBuilder::BuildHelpers.run_with_capture(["make", "install_sw"], chdir: openssl_src)
      rescue TebakoRBuilder::Error => e
        raise TebakoRBuilder::Error.new("'build_runtime' deps stage (OpenSSL build) failed: #{e.message}", 104)
      end

      File.write(marker, "#{sha256}\n")
      puts "   ... #{File.join(deps_prefix, "lib", "libssl.a")} installed"
    end

    # OpenSSL's Configure target for the leg's arch (the linux legs —
    # darwin builds no OpenSSL).
    def openssl_configure_target
      @platform.host_id.end_with?("arm64") ? "linux-aarch64" : "linux-x86_64"
    end

    # The CA layout baked into the static OpenSSL (build_openssl's
    # comment): debian's on the gnu leg, alpine's on the musl leg.
    def openssl_ca_dir
      @platform.musl? ? "/etc/ssl" : "/usr/lib/ssl"
    end

    # The minimal static libcurl's configure line (build_curl's
    # comment): http/https/ftp/file only, everything else off — no
    # idn2/rtmp/ssh/psl/ldap/gssapi/brotli/zstd/http2+3 (the distro
    # libcurl's encumbered closure is exactly what must not ship), no
    # extra protocols R never calls. The TLS backend is --with-openssl=
    # <deps prefix>, appended in build_curl (the deps stage's own
    # OpenSSL — build_openssl's comment).
    CURL_CONFIGURE_ARGS = %w[
      --disable-shared
      --enable-static
      --with-pic
      --with-ca-fallback
      --without-libpsl
      --without-brotli
      --without-zstd
      --without-nghttp2
      --without-nghttp3
      --without-ngtcp2
      --without-libidn2
      --without-libssh
      --without-libssh2
      --without-gssapi
      --disable-ldap
      --disable-ldaps
      --disable-rtsp
      --disable-dict
      --disable-telnet
      --disable-tftp
      --disable-pop3
      --disable-imap
      --disable-smtp
      --disable-gopher
      --disable-mqtt
      --disable-manual
      --disable-docs
    ].freeze

    # The minimal static libcurl (versions.yml's deps: pin). R 4.6
    # REQUIRES libcurl with https support (m4/R.m4's R_LIBCURL
    # hard-fails the configure without it — there is no
    # --without-libcurl), and the distro libcurl drags an
    # LGPL/GPL-encumbered dynamic closure (libidn2/librtmp/libssh/...)
    # a bare system neither carries nor may ship statically. So the
    # factory builds curl itself per CURL_CONFIGURE_ARGS against the
    # deps stage's own static OpenSSL (--with-openssl=<deps prefix> —
    # never the focal toolchain's EOL 1.1.1, which curl 8.23 rejects),
    # every other library and protocol off. The build is static-only,
    # so the installed curl-config answers --built-shared "no" and R's
    # R_LIBCURL consumes --static-libs — -L<deps>/lib -lcurl -lssl
    # -lcrypto -lz, each archive static and all four from the deps
    # prefix (build_zlib's libz.a — the toolchain's carries no PIC).
    # PIC throughout
    # (-O2 -fPIC): libcurl.a links into internet.so, a shared object —
    # libR itself never touches curl (src/main/internet.c lazy-loads
    # the internet module, and only internet.so carries $(CURL_LIBS),
    # src/modules/internet/Makefile.in). CA discovery follows the
    # OpenSSL defaults (--with-ca-fallback keeps the build host's
    # bundle out of the trust decision, and the deps OpenSSL's
    # --openssldir bakes the debian layout);
    # SSL_CERT_FILE/SSL_CERT_DIR override at run time.
    def build_curl
      fetcher = TebakoRBuilder::SourceFetcher.new(cache_dir: File.join(@prefix, "downloads"))
      (tarball, sha256) = fetcher.fetch_dep("curl")
      tree = File.basename(tarball).sub(/\.tar\.gz\z/, "")
      @dep_sources << { "name" => File.basename(tarball), "sha256" => sha256 }
      marker = File.join(deps_prefix, ".#{tree}.built-sha256")
      if File.executable?(curl_config) && File.file?(marker) && File.read(marker).strip == sha256
        puts "-- #{tree} already built (sha256 #{sha256})"
        return
      end

      puts "-- Building #{tree} (minimal static, sha256 #{sha256})"
      curl_src = File.join(deps_src_dir, tree)
      FileUtils.rm_rf(curl_src, secure: true)
      FileUtils.mkdir_p(deps_src_dir)
      TebakoRBuilder::BuildHelpers.run_with_capture(["tar", "-xzf", tarball, "-C", deps_src_dir])
      unless File.directory?(curl_src)
        raise TebakoRBuilder::Error.new("#{tarball} did not extract to #{tree} under #{deps_src_dir}", 103)
      end

      begin
        TebakoRBuilder::BuildHelpers.run_with_capture(
          ["./configure", "--prefix=#{deps_prefix}", "--with-openssl=#{deps_prefix}"] + CURL_CONFIGURE_ARGS,
          env: { "CFLAGS" => "-O2 -fPIC" }, chdir: curl_src
        )
      rescue TebakoRBuilder::Error => e
        raise TebakoRBuilder::Error.new("'build_runtime' deps stage (libcurl configure) failed: #{e.message}", 103)
      end
      begin
        TebakoRBuilder::BuildHelpers.run_with_capture(["make", "-j", ncores.to_s], chdir: curl_src)
        TebakoRBuilder::BuildHelpers.run_with_capture(["make", "install"], chdir: curl_src)
      rescue TebakoRBuilder::Error => e
        raise TebakoRBuilder::Error.new("'build_runtime' deps stage (libcurl build) failed: #{e.message}", 104)
      end

      File.write(marker, "#{sha256}\n")
      puts "   ... #{curl_config} --static-libs: #{`#{curl_config} --static-libs`.strip}"
    end

    # The static PCRE2 (versions.yml's deps: pin; the macOS legs only —
    # build_deps' comment). R 4.6 dropped its bundled pcre2 and
    # hard-requires an external one, and the macOS SDK ships libpcre2-8's
    # .tbd stub WITHOUT pcre2.h, so the system dylib is unprobe-able and
    # a Homebrew find is tebako-runtime-python#80's leak class — the
    # factory builds its own. --disable-shared: archives only, -fPIC
    # throughout (pcre2 only ever reaches libR — the exe link — but PIC
    # keeps a later shared-object consumer honest). The install's
    # lib/pkgconfig/libpcre2-8.pc is what configure's R_PCRE2 finds
    # through configure_env's PKG_CONFIG_PATH pin — never the runner's
    # Homebrew pkg-config.
    def build_pcre2
      fetcher = TebakoRBuilder::SourceFetcher.new(cache_dir: File.join(@prefix, "downloads"))
      (tarball, sha256) = fetcher.fetch_dep("pcre2")
      tree = File.basename(tarball).sub(/\.tar\.gz\z/, "")
      @dep_sources << { "name" => File.basename(tarball), "sha256" => sha256 }
      marker = File.join(deps_prefix, ".#{tree}.built-sha256")
      if File.file?(File.join(deps_prefix, "lib", "libpcre2-8.a")) &&
         File.file?(marker) && File.read(marker).strip == sha256
        puts "-- #{tree} already built (sha256 #{sha256})"
        return
      end

      puts "-- Building #{tree} (static, -fPIC, sha256 #{sha256})"
      pcre2_src = File.join(deps_src_dir, tree)
      FileUtils.rm_rf(pcre2_src, secure: true)
      FileUtils.mkdir_p(deps_src_dir)
      TebakoRBuilder::BuildHelpers.run_with_capture(["tar", "-xzf", tarball, "-C", deps_src_dir])
      unless File.directory?(pcre2_src)
        raise TebakoRBuilder::Error.new("#{tarball} did not extract to #{tree} under #{deps_src_dir}", 103)
      end

      begin
        TebakoRBuilder::BuildHelpers.run_with_capture(
          ["./configure", "--prefix=#{deps_prefix}",
           "--disable-shared", "--enable-static",
           # R consumes the 8-bit library only (PCRE2_CODE_UNIT_WIDTH=8,
           # m4/R.m4's R_PCRE2).
           "--disable-pcre2-16", "--disable-pcre2-32"],
          env: { "CFLAGS" => "-O2 -fPIC" }, chdir: pcre2_src
        )
      rescue TebakoRBuilder::Error => e
        raise TebakoRBuilder::Error.new("'build_runtime' deps stage (pcre2 configure) failed: #{e.message}", 103)
      end
      begin
        TebakoRBuilder::BuildHelpers.run_with_capture(["make", "-j", ncores.to_s], chdir: pcre2_src)
        TebakoRBuilder::BuildHelpers.run_with_capture(["make", "install"], chdir: pcre2_src)
      rescue TebakoRBuilder::Error => e
        raise TebakoRBuilder::Error.new("'build_runtime' deps stage (pcre2 build) failed: #{e.message}", 104)
      end

      File.write(marker, "#{sha256}\n")
      puts "   ... #{File.join(deps_prefix, "lib", "libpcre2-8.a")} installed"
    end

    # The static liblzma (versions.yml's deps: pin; the macOS legs only —
    # build_deps' comment): R 4.6 dropped its bundled xz and the macOS
    # SDK ships liblzma's .tbd without lzma.h (build_pcre2's comment).
    # Only liblzma is needed — the xz tools and scripts stay off.
    def build_xz
      fetcher = TebakoRBuilder::SourceFetcher.new(cache_dir: File.join(@prefix, "downloads"))
      (tarball, sha256) = fetcher.fetch_dep("xz")
      tree = File.basename(tarball).sub(/\.tar\.gz\z/, "")
      @dep_sources << { "name" => File.basename(tarball), "sha256" => sha256 }
      marker = File.join(deps_prefix, ".#{tree}.built-sha256")
      if File.file?(File.join(deps_prefix, "lib", "liblzma.a")) &&
         File.file?(marker) && File.read(marker).strip == sha256
        puts "-- #{tree} already built (sha256 #{sha256})"
        return
      end

      puts "-- Building #{tree} (static liblzma only, -fPIC, sha256 #{sha256})"
      xz_src = File.join(deps_src_dir, tree)
      FileUtils.rm_rf(xz_src, secure: true)
      FileUtils.mkdir_p(deps_src_dir)
      TebakoRBuilder::BuildHelpers.run_with_capture(["tar", "-xzf", tarball, "-C", deps_src_dir])
      unless File.directory?(xz_src)
        raise TebakoRBuilder::Error.new("#{tarball} did not extract to #{tree} under #{deps_src_dir}", 103)
      end

      begin
        TebakoRBuilder::BuildHelpers.run_with_capture(
          ["./configure", "--prefix=#{deps_prefix}",
           "--disable-shared", "--enable-static",
           "--disable-xz", "--disable-xzdec", "--disable-lzmadec", "--disable-scripts"],
          env: { "CFLAGS" => "-O2 -fPIC" }, chdir: xz_src
        )
      rescue TebakoRBuilder::Error => e
        raise TebakoRBuilder::Error.new("'build_runtime' deps stage (xz configure) failed: #{e.message}", 103)
      end
      begin
        TebakoRBuilder::BuildHelpers.run_with_capture(["make", "-j", ncores.to_s], chdir: xz_src)
        TebakoRBuilder::BuildHelpers.run_with_capture(["make", "install"], chdir: xz_src)
      rescue TebakoRBuilder::Error => e
        raise TebakoRBuilder::Error.new("'build_runtime' deps stage (xz build) failed: #{e.message}", 104)
      end

      File.write(marker, "#{sha256}\n")
      puts "   ... #{File.join(deps_prefix, "lib", "liblzma.a")} installed"
    end

    # The relocatable configure: the compiled-in prefix IS the mount root
    # (rhome = <prefix>/<LIBnn>/R = <mount root>/lib/R — the path Rscript's
    # launcher and our fs TU's R_HOME both spell). The feature policy is
    # CONFIGURE_ARGS (the class comment).
    def configure
      if @platform.msys?
        raise TebakoRBuilder::Error.new(
          "the windows legs arrive with their own increment — " \
          "this factory builds POSIX legs only today (the fs TU is POSIX-only)", 103
        )
      end

      prepare_static_libs_dir
      args = ["./configure", "--prefix=#{@platform.mount_root}"] + CONFIGURE_ARGS
      puts "-- Configuring R #{@r_version} (#{@platform.host_id})"
      TebakoRBuilder::BuildHelpers.run_with_capture(args, env: configure_env, chdir: src_dir)
      puts "   ... compile flags (Makeconf CFLAGS): #{recorded_cflags}"
    rescue TebakoRBuilder::Error => e
      raise e if e.error_code == 103 &&
                 (e.message.include?("POSIX legs") || e.message.include?("Makeconf") || e.message.include?("static"))

      raise TebakoRBuilder::Error.new("'build_runtime' configure step failed: #{e.message}", 103)
    end

    # The configure env, per leg family: the ELF legs share one shape
    # (elf_configure_env — the gnu/musl differences are the quadmath
    # absence on musl and the apk-vs-apt provisioning, both noted
    # there); darwin is its own (darwin_configure_env — clang/ld64
    # grammar, the system-library closure, and the deps-stage pcre2/xz).
    def configure_env
      if @platform.macos?
        darwin_configure_env
      else
        elf_configure_env
      end
    end

    # linux-gnu/linux-musl, the container/env honesty pins:
    #
    #   LIBnn=lib — rhome is <prefix>/lib/R (never lib64: ubuntu has no
    #   /usr/lib64, and R's configure would otherwise pick lib64 on
    #   x86_64; one spelling, declared everywhere).
    #
    #   CFLAGS=-O2 — the tpkg-builder gnu image EXPORTS CFLAGS=-pthread,
    #   and under autoconf an env-set CFLAGS REPLACES configure's -g -O2
    #   default outright (the tebako-runtime-python#79 slow-build class;
    #   php's configure_env is the same fix, one interpreter over).
    #   Deliberately NO -pthread, although the container's value carries
    #   it: R_PTHREAD (m4/R.m4) searches for the link option that finds
    #   pthread_kill and adds it to MAIN/DYLIB_LDFLAGS — with -pthread
    #   already in CFLAGS the empty option wins the search, the flag
    #   never reaches R.bin's link (MAIN_LINK carries no CFLAGS), and
    #   eval.c's pthread_create is undefined at link time. Letting
    #   configure find it keeps the flag on upstream's own channel (and
    #   the stock-R shape: -pthread in MAIN/DYLIB_LDFLAGS, not CFLAGS).
    #   recorded_cflags gates the outcome at configure time, the boot
    #   smoke's compute-floor at run time.
    #
    #   LDFLAGS=-L<static-libs> -static-libgfortran -static-libgcc — two
    #   pins ride it (MAIN_LINK and SHLIB_LINK both carry LDFLAGS):
    #
    #   * -L<static-libs> — R 4.6 links zlib/bzip2/xz/pcre2 DYNAMICALLY
    #     into libR by default (the bundled copies are gone; there is no
    #     --with-system-zlib=no left, and each R_<LIB> probe PREPENDS its
    #     -lz/-lbz2/-llzma/-lpcre2-8 to LIBS, so a static-spec -l:libz.a
    #     in our LIBS would lose the order). libbz2/liblzma/libpcre2-8
    #     are NOT on a bare system (the audience rule;
    #     tebako-runtime-python#76's class), so the -L dir fronts the
    #     search path with symlinks to the STATIC archives and
    #     nothing else — every -lz/-lbz2/-llzma/-lpcre2-8, configure
    #     test and final link alike, resolves statically and adds no
    #     DT_NEEDED. libz.a is the deps stage's own (build_zlib):
    #     internet.so links -lz into a shared object and the focal
    #     toolchain's libz.a carries no PIC. The other three only ever
    #     reach R.bin's link (no module links them, so PIC-in-archive is
    #     never exercised there). The dir also fronts libgfortran.a and
    #     libquadmath.a from the compiler's own directory — the exe's
    #     FLIBS pin (below) resolves its gfortran closure against them,
    #     and no shlib link ever names them. The provenance gate proves
    #     the outcome.
    #
    #   * -static-libgfortran -static-libgcc — R needs a Fortran compiler
    #     (the internal LAPACK is Fortran), and gfortran's runtime is NOT
    #     on a bare system (the audience rule). The flags ride every link
    #     as the declared intent, but on this toolchain they do NOT
    #     rewrite a literal -lgfortran — the actual closure is the
    #     FLIBS/FLIBS_IN_SO pin below (their comment carries the proven
    #     split).
    #
    #   FLIBS/FLIBS_IN_SO — configure's detected Fortran library list,
    #   overridden because the gfortran closure has to be split between
    #   the exe and the shared objects:
    #
    #   * -static-libgfortran does NOT rewrite a literal -lgfortran on
    #     this toolchain — a shared object linked with both still NEEDs
    #     libgfortran.so.5 (container-proven), and R's detected FLIBS
    #     carries the literal flag.
    #   * focal's libgfortran.a is non-PIC (async.o's thread_unit,
    #     unix.o's stdin) — ld refuses it in any shared object, so the
    #     archive can never enter libRlapack.so.
    #   * R's LAPACK references exactly ONE gfortran symbol:
    #     _gfortran_concat_string (nm over src/modules/lapack/*.o; the
    #     BLAS objects reference none).
    #
    #   So the exe carries the chain statically — FLIBS resolves
    #   -lgfortran/-lquadmath against the -L pin's archives, and
    #   --undefined=_gfortran_concat_string forces the member in (the
    #   exe's own objects reference no gfortran symbol; the concat chain
    #   pulls write.o, which needs quadmath_snprintf, hence -lquadmath).
    #   MAIN_LINK already carries --export-dynamic, so the exe exports
    #   the symbol and libRlapack.so's undefined reference binds from
    #   the exe at dlopen — the same mechanism the modules use for R's
    #   own symbols under --disable-R-shlib. FLIBS_IN_SO (R's own
    #   override-able name for the shlib link lines, configure.ac) drops
    #   -lgfortran entirely, so no shared object records a gfortran
    #   NEEDED. The provenance gate asserts both halves (the exe's
    #   export, libRlapack.so's closed NEEDED).
    #
    #   SHLIB_LDFLAGS — adds -Wl,-rpath,'$$ORIGIN/../lib:$$ORIGIN/../../../lib'
    #   to every module .so link: lapack.so NEEDs libRlapack.so and (via
    #   substitution 5's --no-as-needed pin) libRblas.so, the library
    #   package .so's (stats.so) NEED libRlapack.so/libRblas.so directly
    #   (R's included LAPACK/BLAS are built as R_HOME/lib/*.so, and
    #   configure's internal-LAPACK LAPACK_LIBS and shlib BLAS_LIBS name
    #   them on the shlib links), and the dlmap2file closure walk
    #   (crates/tfs exec_closure) resolves a bare NEEDED only through the
    #   importing image's OWN rpaths — root-agnostic $ORIGIN entries name
    #   the in-image lib/R/lib from BOTH shlib depths: lib/R/modules
    #   (../lib) and lib/R/library/<pkg>/libs (../../../lib); each depth's
    #   other entry is a dead path ld.so skips. The walk materializes only
    #   the dlopen'd object's DIRECT dependencies, so every in-image
    #   dependency must be direct (substitution 5 exists because the
    #   toolchain's spec-default --as-needed drops the reference-free
    #   -lRblas from lapack.so's link). The preset also seeds
    #   DYLIB_LDFLAGS (configure.ac: an unset DYLIB_LD inherits
    #   SHLIB_LD/SHLIB_LDFLAGS), so libRlapack.so and libRblas.so
    #   themselves carry the rpath — from lib/R/lib, the first entry
    #   normalizes to lib/R/lib, and libRlapack.so's own NEEDED
    #   libRblas.so resolves the same way. The $$ survives make's
    #   expansion into the recipe; the quotes protect $ORIGIN from the
    #   shell.
    #
    #   CURL_CONFIG=<deps>/bin/curl-config — R has NO --without-libcurl
    #   switch: R_LIBCURL hard-fails the configure without libcurl +
    #   https (m4/R.m4), so the python#80 host-leak class can't be
    #   pinned off by hiding the header — the closure must be PROVIDED
    #   honestly instead. build_deps' minimal static libcurl
    #   (versions.yml's deps: pin — http/https/ftp/file, TLS via the
    #   deps stage's own static OpenSSL 3, none of the distro closure's
    #   libidn2/librtmp/libssh/...) is the answer: AC_PATH_PROG honors
    #   the preset CURL_CONFIG, the static-only build's curl-config
    #   answers --built-shared "no", and R consumes --static-libs
    #   (-L<deps>/lib -lcurl -lssl -lcrypto -lz), every archive
    #   resolving statically against the deps prefix. libR itself never
    #   links curl — src/main/internet.c lazy-loads the internet
    #   module, and only internet.so carries $(CURL_LIBS)
    #   (src/modules/internet/Makefile.in). The provenance gate proves
    #   the outcome.
    #
    #   ac_cv_lib_zstd_ZSTD_versionNumber=no — R_ZSTD has no opt-out
    #   either: a found libzstd joins LIBS unconditionally. Same pin,
    #   same reason. Lazy-load databases stay gzip/xz/bzip2 (R's own
    #   install default is gzip; zstd-compressed third-party .rdb files
    #   are out of the payload-closure contract).
    #
    # The musl legs differ in exactly one pin: alpine's aarch64 gfortran
    # is built WITHOUT libquadmath (`gfortran
    # -print-file-name=libquadmath.a` finds nothing there —
    # container-proven), so its libgfortran.a resolves the quad I/O
    # chain internally and its FLIBS pin drops -lquadmath. x86_64 alpine
    # ships libquadmath.a and its libgfortran.a references
    # quadmath_snprintf exactly like gnu's, so the pin keeps -lquadmath
    # there (quadmath_static?).
    def elf_configure_env
      static_fortran = "-static-libgfortran -static-libgcc"
      quadmath = quadmath_static? ? " -lquadmath" : ""
      {
        "LIBnn" => "lib",
        "CFLAGS" => "-O2",
        "LDFLAGS" => "-L#{static_libs_dir} #{static_fortran}",
        "FLIBS" => "#{static_fortran} -Wl,--undefined=_gfortran_concat_string -lgfortran#{quadmath} -lm",
        "FLIBS_IN_SO" => "#{static_fortran} -lm",
        "SHLIB_LDFLAGS" => "#{static_fortran} -Wl,-rpath,'$$ORIGIN/../lib:$$ORIGIN/../../../lib'",
        "CURL_CONFIG" => curl_config,
        "ac_cv_lib_zstd_ZSTD_versionNumber" => "no"
      }
    end

    # darwin, the runner/SDK honesty pins. The shape differs from the
    # ELF legs because the platform grammar differs:
    #
    #   The closure is macOS's own where macOS guarantees it: libz,
    #   libbz2, and libcurl ship in every macOS install (SDK stub +
    #   header + the dyld shared cache), so they link DYNAMICALLY — the
    #   provenance gate's Mach-O arm allows /usr/lib/* and
    #   /System/Library/* by design, and internet.so records
    #   /usr/lib/libcurl.4.dylib there exactly as the linux legs record
    #   nothing. pcre2 and xz are the exceptions (build_deps' comment:
    #   the SDK ships their .tbd stubs WITHOUT the headers) — they come
    #   from the deps stage statically, and the -L pin's dir fronts
    #   their archives so configure's probes resolve them.
    #
    #   LIBnn=lib / CFLAGS=-O2 / the zstd cache pin — the same honesty
    #   pins as the ELF legs (the runner exports no clobbering CFLAGS,
    #   but an explicit -O2 is deterministic and the recorded_cflags
    #   gate reads the same Makeconf).
    #
    #   CPPFLAGS=-I<deps>/include — pcre2.h and lzma.h live nowhere else
    #   (the SDK omits them; the deps stage installed them). R's header
    #   probes resolve here.
    #
    #   PKG_CONFIG_PATH=<deps>/lib/pkgconfig — R_PCRE2 (m4/R.m4) probes
    #   pkg-config FIRST, and a macOS runner's Homebrew pkg-config WOULD
    #   find Homebrew's libpcre2-8 and leak it into the closure (the
    #   tebako-runtime-python#80 class). The pin points the probe at the
    #   deps stage's own libpcre2-8.pc — and at nothing else, which is
    #   also the determinism pin for every other pkg-config probe R
    #   runs.
    #
    #   LDFLAGS=-L<static-libs> — fronts the static archives for
    #   -lpcre2-8/-llzma (the deps stage's) and -lgfortran/-lquadmath/
    #   -lgcc (the compiler's, symlinked) and nothing else: -lz/-lbz2/-lcurl
    #   fall through to the SDK stubs and link dynamically (the closure
    #   comment above). NO -static-libgfortran/-static-libgcc: those are
    #   gcc driver flags and darwin links with clang, which rejects
    #   them — the static gfortran closure is the -L pin's work alone.
    #
    #   FLIBS — clang's spelling of the exe-side gfortran chain (the
    #   ELF comment's split applies one-for-one, with ld64 grammar):
    #   -Wl,-u,__gfortran_concat_string forces the member in (darwin
    #   symbol names carry the leading underscore; the exe's own objects
    #   reference no gfortran symbol), -lgfortran/-lquadmath resolve
    #   statically against the -L pin, and -lgcc closes the chain:
    #   libgfortran.a's quadmath IO references GCC's 128-bit soft-float
    #   routines (__divtf3/__multf3/__eqtf2…, libgcc.a) which Apple's
    #   compiler-rt omits on arm64 (darwin long double is 64-bit), so
    #   the -lgfortran/-lquadmath pair alone leaves them undefined.
    #   ld64 needs no --export-dynamic:
    #   the exe's global symbols are visible to dlopen'd bundles by
    #   default, so libRlapack.dylib's undefined gfortran reference
    #   binds from the exe exactly as R's own symbols do under
    #   --disable-R-shlib. The provenance gate asserts the export.
    #
    #   FLIBS_IN_SO — drops the gfortran chain entirely (just -lm):
    #   darwin's shlib AND dylib links both carry -undefined
    #   dynamic_lookup (configure.ac's darwin branch), so every shared
    #   object's gfortran references defer to load time and bind from
    #   the exe — no shared object records a gfortran dylib, and no
    #   static archive needs PIC-in-dylib treatment (though darwin's are
    #   PIC anyway).
    #
    #   SHLIB_LDFLAGS — the $ORIGIN pin's darwin spelling,
    #   -Wl,-rpath,@loader_path/../lib plus @loader_path/../../../lib:
    #   lapack.so records libRlapack.dylib and libRblas.dylib (ld64
    #   records every linked dylib — there is no --as-needed default to
    #   defeat, which is why substitution 5 is verify-only on this
    #   leg), and the exec_closure walk resolves a bare install name
    #   only through the importing object's own LC_RPATH — the two
    #   depths cover lib/R/modules and lib/R/library/<pkg>/libs exactly
    #   as on linux.
    #
    #   DYLIB_LDFLAGS — libRlapack.dylib/libRblas.dylib's own rpath:
    #   from lib/R/lib, libRlapack.dylib's recorded libRblas.dylib
    #   resolves through @loader_path/. (configure.ac honors the preset
    #   and appends its -dynamiclib/-headerpad/dynamic_lookup triple;
    #   an unset DYLIB_LD inherits SHLIB_LD).
    #
    #   CURL_CONFIG=/usr/bin/curl-config — macOS's own libcurl (the
    #   closure comment): the system curl-config answers --built-shared
    #   "yes", so R consumes --libs (-lcurl, dynamic) — the deps stage
    #   builds no curl/openssl/zlib on this leg at all.
    #
    #   ac_cv_lib_zstd_ZSTD_versionNumber=no — the ELF pin, same reason.
    def darwin_configure_env
      {
        "LIBnn" => "lib",
        "CFLAGS" => "-O2",
        "CPPFLAGS" => "-I#{File.join(deps_prefix, "include")}",
        "PKG_CONFIG_PATH" => File.join(deps_prefix, "lib", "pkgconfig"),
        "LDFLAGS" => "-L#{static_libs_dir}",
        "FLIBS" => "-Wl,-u,__gfortran_concat_string -lgfortran -lquadmath -lgcc -lm",
        "FLIBS_IN_SO" => "-lm",
        "SHLIB_LDFLAGS" => "-Wl,-rpath,@loader_path/../lib -Wl,-rpath,@loader_path/../../../lib",
        "DYLIB_LDFLAGS" => "-Wl,-rpath,@loader_path/.",
        "CURL_CONFIG" => "/usr/bin/curl-config",
        "ac_cv_lib_zstd_ZSTD_versionNumber" => "no"
      }
    end

    # The macOS support floor rides the WHOLE build as
    # MACOSX_DEPLOYMENT_TARGET — configure's probes compile+link, the
    # deps stage builds under it, and the exe's final link (inside make)
    # is what clang stamps as LC_BUILD_VERSION minos. Unpinned, the
    # stamp floats with the build host's OS (tebako-runtime-python#81:
    # the Intel runtime refused to load on macOS 14). The pin is
    # contract.yml's macos_deployment_target, a product decision, and
    # the provenance gate asserts the recorded minos equals it.
    # Off-macOS the env is empty and merges as a no-op.
    def floor_env
      return {} unless @platform.macos?

      floor = @macos_deployment_target.to_s
      if floor.empty?
        raise TebakoRBuilder::Error.new(
          "no macos_deployment_target pin (contract.yml) — the macOS support floor is a product decision, " \
          "never the runner image's accident (tebako-runtime-python#81)", 64
        )
      end
      { "MACOSX_DEPLOYMENT_TARGET" => floor }
    end

    # The static archives the -L pin fronts (configure_env's comments),
    # per leg. libz.a is the deps stage's own -fPIC build on the linux
    # legs (build_zlib) — the toolchain's archive carries no PIC and
    # internet.so links -lz into a shared object; libbz2/liblzma/
    # libpcre2-8 come from the toolchain's -dev packages there and only
    # ever reach R.bin's link (on darwin the pcre2/xz pair is the deps
    # stage's own — the SDK ships no headers — and libz/libbz2 link
    # dynamically against macOS's own dylibs, so they are absent here).
    # The gfortran pair comes from the compiler's own directory: ONLY
    # the exe's FLIBS pulls them (FLIBS_IN_SO drops the chain entirely),
    # so their members never enter a shared object. darwin adds libgcc.a
    # (the FLIBS comment: libgfortran's quadmath IO needs GCC's 128-bit
    # soft-float routines, absent from Apple's compiler-rt). musl/arm64
    # is the one POSIX leg WITHOUT libquadmath: alpine builds no
    # quadmath support for aarch64 (`gfortran
    # -print-file-name=libquadmath.a` finds nothing — container-proven),
    # so its libgfortran.a resolves the quad I/O chain internally.
    # musl/x86_64 is the gnu shape instead: alpine ships libquadmath.a
    # and its libgfortran.a references quadmath_snprintf exactly like
    # gnu's (the same link failure the FLIBS pin answers).
    STATIC_ARCHIVES_LINUX_GNU = %w[libz.a libbz2.a liblzma.a libpcre2-8.a libgfortran.a libquadmath.a].freeze
    STATIC_ARCHIVES_LINUX_MUSL = %w[libz.a libbz2.a liblzma.a libpcre2-8.a libgfortran.a libquadmath.a].freeze
    STATIC_ARCHIVES_LINUX_MUSL_ARM64 = %w[libz.a libbz2.a liblzma.a libpcre2-8.a libgfortran.a].freeze
    STATIC_ARCHIVES_DARWIN = %w[libpcre2-8.a liblzma.a libgfortran.a libquadmath.a libgcc.a].freeze

    # musl/arm64 is the one leg whose gfortran is built WITHOUT
    # libquadmath (the constants comment); every other POSIX leg's
    # libgfortran.a needs the external archive.
    def quadmath_static?
      !(@platform.musl? && @platform.host_id.end_with?("arm64"))
    end

    def static_archives
      if @platform.macos?
        STATIC_ARCHIVES_DARWIN
      elsif @platform.musl?
        quadmath_static? ? STATIC_ARCHIVES_LINUX_MUSL : STATIC_ARCHIVES_LINUX_MUSL_ARM64
      else
        STATIC_ARCHIVES_LINUX_GNU
      end
    end

    def static_libs_dir
      File.join(@prefix, "static-libs")
    end

    # Populate the -L dir with symlinks to the STATIC archives (and only
    # those). The deps stage's own builds link directly; the toolchain's
    # archives are located through the compilers' own search paths
    # (`gcc -print-file-name`; the gfortran pair — and darwin's libgcc.a —
    # through `gfortran -print-file-name` — clang has no Fortran and no
    # GCC search path), never a hardcoded libdir. A missing archive is a
    # named error with its provisioning
    # hint (docs/build-chain.md's in-leg provisioning note).
    def prepare_static_libs_dir
      FileUtils.mkdir_p(static_libs_dir)
      static_archives.each do |archive|
        found = locate_static_archive(archive)
        unless found.start_with?("/") && File.file?(found)
          raise TebakoRBuilder::Error.new("no static #{archive} on the search path — #{static_archive_hint(archive)}", 103)
        end
        FileUtils.ln_sf(File.realpath(found), File.join(static_libs_dir, archive))
      end
      puts "   ... static closure dir: #{static_libs_dir} (#{static_archives.join(' ')})"
    end

    def locate_static_archive(archive)
      case archive
      when "libz.a"
        deps_libz
      when "libpcre2-8.a", "liblzma.a"
        @platform.macos? ? File.join(deps_prefix, "lib", archive) : `gcc -print-file-name=#{archive}`.strip
      when "libgfortran.a", "libquadmath.a", "libgcc.a"
        # The compiler's own archives (the gfortran pair on every POSIX
        # leg, libgcc.a on darwin): gfortran locates them — clang has no
        # Fortran and no GCC search path (darwin's gcc IS clang).
        `gfortran -print-file-name=#{archive}`.strip
      else
        `gcc -print-file-name=#{archive}`.strip
      end
    end

    # The provisioning hint for a missing static archive
    # (prepare_static_libs_dir), per leg: the deps stage builds libz.a on
    # linux and the pcre2/xz pair on darwin, the gfortran pair ships with
    # the Fortran compiler, and the rest ride the toolchain's -dev
    # packages on linux.
    def static_archive_hint(archive)
      case archive
      when "libz.a"
        "the deps stage builds it (build_zlib — run build_runtime from a clean deps prefix)"
      when "libpcre2-8.a", "liblzma.a"
        if @platform.macos?
          "the deps stage builds it (run build_runtime from a clean deps prefix)"
        else
          "install the -dev package (apt: liblzma-dev libpcre2-dev · apk: xz-dev xz-static pcre2-dev — " \
            "the in-leg provisioning note in docs/build-chain.md)"
        end
      when "libgfortran.a", "libquadmath.a", "libgcc.a"
        "install the Fortran compiler (apt/apk: gfortran · macOS: the runner image's Homebrew gcc — " \
          "the in-leg provisioning note in docs/build-chain.md)"
      else
        "install the -dev package (apt: libbz2-dev · apk: bzip2-dev bzip2-static — " \
          "the in-leg provisioning note in docs/build-chain.md)"
      end
    end

    # The build-time substitutions on the generated src/main/Makefile.
    # Every anchor must match exactly once — an R whose build grammar
    # drifted is a named error, never a half-applied edit.
    def substitute_makefile
      makefile = File.join(src_dir, "src", "main", "Makefile")
      content = File.read(makefile)
      if content.include?(MARKER)
        puts "   ... Makefile substitutions already applied"
        return
      end

      blas_objects = r_blas_objects.join(" ")
      substitutions = [
        # 1. The link recipe gains the fs TU object between
        #    $(R_bin_OBJECTS) and $(R_bin_LDADD), and the tebako link
        #    line last.
        [%r{^(\t\$\(MAIN_LINK\) -o \$@ \$\(R_bin_OBJECTS\))( \$\(R_bin_LDADD\).*)$},
         "\\1 tebako_r_main.o\\2 $(TEBAKO_LIBS)"],
        # 2. The fs TU object and the BLAS objects join the R.bin
        #    target's prerequisites.
        [%r{^(\$\(R_binary\): \$\(R_bin_OBJECTS\) \$\(R_bin_DEPENDENCIES\))(.*)$},
         "\\1 tebako_r_main.o $(BLAS_STATIC_OBJS)\\2"],
        # 3. The Makefile self-regeneration rule must not fire mid-build
        #    (the class comment): collapse the volatile prerequisites to
        #    the two stable ones. The recipe (config.status re-run)
        #    stays — a re-configure still regenerates and this pass
        #    re-applies.
        [%r{^Makefile: \$\(srcdir\)/Makefile\.in \\\n  \$\(top_builddir\)/config\.status \\\n  \.\./include/config\.h \\\n  \.\./include/Rversion\.h \\\n  \$\(SOURCES_C\) \$\(EXTRA_SOURCES_C\)$},
         "Makefile: $(srcdir)/Makefile.in $(top_builddir)/config.status"],
        # 4. R.bin links the included BLAS as OBJECTS, never -lRblas
        #    (the CONFIGURE_ARGS comment — a NEEDs-libRblas exe could
        #    never boot the driver). The shlib BLAS_LIBS spells
        #    -L"$(R_HOME)/lib$(R_ARCH)" -lRblas for the lib/*.so
        #    consumers; EXTRA_LIBS is R.bin's own line, so the objects
        #    take its place there. The objects are the same ones
        #    libRblas.so carries, built before src/main in R's own
        #    SUBDIRS order (src/Makefile: extra precedes main).
        [%r{^EXTRA_LIBS = \$\(BLAS_LIBS\)(.*)$},
         "EXTRA_LIBS = $(BLAS_STATIC_OBJS)\\1"]
      ]
      substitutions.each { |(pattern, replacement)| content = content.gsub(pattern, replacement) }
      content += "\n#{MARKER}\nBLAS_STATIC_OBJS = #{blas_objects}\nTEBAKO_LIBS = #{mlibs.tebako_libs}\n" \
                 "tebako_r_main.o: $(srcdir)/tebako_r_main.c ../include/Rversion.h\n" \
                 "\t$(CC) $(ALL_CPPFLAGS) $(ALL_CFLAGS) -c $(srcdir)/tebako_r_main.c -o $@\n" \
                 "\n" \
                 "# The interpreter's entry point, renamed at compile time (the class comment):\n" \
                 "Rmain.o: $(srcdir)/Rmain.c\n" \
                 "\t$(CC) $(ALL_CPPFLAGS) $(ALL_CFLAGS) -Dmain=r_main -c $(srcdir)/Rmain.c -o $@\n"
      File.write(makefile, content)

      verify_substitutions(content)

      # The substitution invalidates any already-built Rmain object (the
      # class comment): force its recompilation under the renamed main.
      # A fresh tree carries none of these.
      FileUtils.rm_f(Dir.glob(File.join(src_dir, "src", "main", "{Rmain.o,Rmain.d}")))
      puts "   ... Makefile substitutions applied"

      substitute_lapack_makefile
    end

    # Substitution 5, on the generated src/modules/lapack/Makefile: record
    # libRblas as a DIRECT dependency of lapack.so. The tpkg-builder
    # toolchain's link spec enables --as-needed by default
    # (%{!fsanitize=*:--as-needed}), and lapack.so's own objects reference
    # no BLAS symbol, so upstream's -lRblas on the module link (EXTRA_LIBS)
    # is dropped and libRblas arrives only transitively through
    # libRlapack.so. But the exec_closure walk (crates/tfs) materializes
    # only the dlopen'd object's DIRECT dependencies, resolved through its
    # OWN rpaths — a transitive libRblas is never materialized and ld.so
    # fails libRlapack.so's load ("libRblas.so: cannot open shared object
    # file"). Wrapping -lRblas in --no-as-needed restores upstream's
    # intended semantics (the Makefile's own comment: "Include BLAS here,
    # as with (static) ATLAS that pulls all the BLAS routines into one
    # place"). The module Makefile's self-regeneration rule names only the
    # stable prerequisites (Makefile.in + config.status + SOURCES), so no
    # collapse is needed here; the marker re-application guard works the
    # same way as the main Makefile's.
    #
    # darwin needs no edit: ld64 records every linked dylib by default
    # (there is no --as-needed to defeat, and clang rejects the flag), so
    # lapack.so's -lRblas is a direct LC_LOAD_DYLIB row by construction
    # — the anchor is verified (a grammar drift is the same named error
    # here) and nothing is written.
    def substitute_lapack_makefile
      makefile = File.join(src_dir, "src", "modules", "lapack", "Makefile")
      content = File.read(makefile)
      if content.include?(LAPACK_MARKER)
        puts "   ... lapack Makefile substitution already applied"
        return
      end

      anchor = %r{^(EXTRA_LIBS = -L"\$\(R_HOME\)/lib\$\(R_ARCH\)" -lRlapack )(-L"\$\(R_HOME\)/lib\$\(R_ARCH\)" -lRblas)( \$\(FLIBS_IN_SO\))$}
      if @platform.macos?
        unless content.match?(anchor)
          raise TebakoRBuilder::Error.new(
            "the lapack module Makefile's EXTRA_LIBS anchor did not match — this R's build grammar " \
            "drifted from the factory's anchors (substitution 5)", 103
          )
        end
        puts "   ... lapack Makefile: -lRblas is direct on darwin by construction (ld64 records every linked dylib)"
        return
      end

      substituted = content.gsub(anchor, '\1-Wl,--no-as-needed \2 -Wl,--as-needed\3')
      if substituted == content
        raise TebakoRBuilder::Error.new(
          "the lapack module Makefile's EXTRA_LIBS anchor did not match — this R's build grammar " \
          "drifted from the factory's anchors (substitution 5)", 103
        )
      end
      File.write(makefile, "#{substituted}\n#{LAPACK_MARKER}\n")
      puts "   ... lapack Makefile substitution applied (--no-as-needed libRblas pin)"
    end

    # The BLAS objects R.bin links statically (substitution 4's list),
    # parsed from the generated src/extra/blas/Makefile's blas_OBJS
    # assignment: with the included BLAS (CONFIGURE_ARGS' defaults) the
    # $(Rblas_la): $(blas_OBJS) rule is active and extra builds before
    # main (src/Makefile's SUBDIRS order), so the objects exist at R.bin's
    # link and are exactly the ones libRblas.so carries. A grammar drift
    # (no assignment, no objects) is a named error, never a silently
    # BLAS-less exe.
    def r_blas_objects
      blas_makefile = File.join(src_dir, "src", "extra", "blas", "Makefile")
      objects = File.readlines(blas_makefile).reject { |line| line.lstrip.start_with?("#") }
                  .select { |line| line.match?(/^\s*blas_OBJS\s*=/) }
                  .flat_map { |line| line.sub(/^[^=]*=/, "").split(/\s+/) }
                  .select { |word| word.end_with?(".o") }
                  .map { |object| "../extra/blas/#{object}" }
      return objects unless objects.empty?

      raise TebakoRBuilder::Error.new(
        "no blas_OBJS objects in the generated src/extra/blas/Makefile — this R's build grammar " \
        "drifted from the factory's anchors (substitution 4 would link R.bin without a BLAS)", 103
      )
    end

    def verify_substitutions(content)
      missing = []
      missing << "the Rmain.o rename rule (-Dmain=r_main)" unless content.include?("-Dmain=r_main -c ")
      missing << "the $(R_binary) link recipe" unless content.match?(%r{^\t\$\(MAIN_LINK\) -o \$@ \$\(R_bin_OBJECTS\) tebako_r_main\.o \$\(R_bin_LDADD\) \$\(TEBAKO_LIBS\)})
      missing << "the $(R_binary) prerequisites" unless content.match?(/^\$\(R_binary\): .*tebako_r_main\.o \$\(BLAS_STATIC_OBJS\)/)
      missing << "the fs TU compile rule" unless content.match?(%r{^tebako_r_main\.o: \$\(srcdir\)/tebako_r_main\.c})
      unless content.match?(%r{^Makefile: \$\(srcdir\)/Makefile\.in \$\(top_builddir\)/config\.status$})
        missing << "the collapsed Makefile self-regeneration rule"
      end
      if content.match?(%r{^Makefile:.*\.\./include/Rversion\.h})
        missing << "the volatile Rversion.h prerequisite (still present)"
      end
      missing << "the BLAS_STATIC_OBJS variable" unless content.match?(%r{^BLAS_STATIC_OBJS = \.\./extra/blas/\S})
      unless content.match?(%r{^EXTRA_LIBS = \$\(BLAS_STATIC_OBJS\) })
        missing << "the EXTRA_LIBS static-BLAS line"
      end
      if content.match?(%r{^EXTRA_LIBS = \$\(BLAS_LIBS\)})
        missing << "the EXTRA_LIBS -lRblas spelling (still present)"
      end
      return if missing.empty?

      raise TebakoRBuilder::Error.new(
        "Makefile substitution incomplete (#{missing.join(", ")}) — this R's generated-Makefile " \
        "grammar drifted from the factory's anchors", 103
      )
    end

    # The generated fs TU: the exe's real main() — boots the driver with
    # the baked mount root, exports the contract version, sets R_HOME off
    # the effective root, applies the front-end (Rscript-shaped argv
    # translates, interpreter-shaped passes through), and re-execs
    # under the preload-shim injection when the image is mounted
    # (README's LINKED-driver section).
    def write_fs_tu
      template = File.read(File.join(@repo_root, "build", "resources", "tebako_r_main.c"))
      rendered = template.gsub("@MOUNT_ROOT@", @platform.mount_root)
                           .gsub("@R_VERSION@", @r.base_version)
      File.write(File.join(src_dir, "src", "main", "tebako_r_main.c"), rendered)
      puts "   ... fs TU: src/main/tebako_r_main.c (mount root #{@platform.mount_root})"
    end

    def make
      TebakoRBuilder::BuildHelpers.run_with_capture(["make", "-j", ncores.to_s], chdir: src_dir)
    rescue TebakoRBuilder::Error => e
      raise TebakoRBuilder::Error.new("'build_runtime' build step failed: #{e.message}", 104)
    end

    # Staged install: `make install DESTDIR=<stage>` lands the prefix
    # tree at <stage>/<mount root spelling> (R's Makefiles spell every
    # destination $(DESTDIR)$(dir) with no separator, which composes
    # only because a POSIX prefix starts with a slash).
    def install
      @stage_dir = File.join(@prefix, "stage")
      FileUtils.rm_rf(@stage_dir, secure: true)
      FileUtils.mkdir_p(@stage_dir)
      TebakoRBuilder::BuildHelpers.run_with_capture(["make", "install", "DESTDIR=#{stage_dir}"], chdir: src_dir)
    rescue TebakoRBuilder::Error => e
      raise TebakoRBuilder::Error.new("'build_runtime' install step failed: #{e.message}", 105)
    end

    # darwin only: rewrite R's intra-image dylib names to @rpath
    # spellings. dyld consults LC_RPATH ONLY for runpath-dependent
    # libraries — dependent names spelled @rpath/<name>; a BARE name
    # (R's hardcoded `-install_name libRlapack.dylib` grammar) searches
    # only the cwd and the dyld fallback dirs, never the LC_RPATH
    # entries, so the SHLIB/DYLIB LDFLAGS rpath pins are dead letters
    # against upstream's bare names and every stats.so/lapack.so dlopen
    # dies on libRlapack.dylib (the boot smoke's darwin evidence).
    # Upstream links every one of these targets with
    # -headerpad_max_install_names precisely so its packaging can
    # rewrite install names (src/library/tools/R/install.R's
    # install_name_tool pass is the same idiom, to absolute framework
    # paths); this pass is the runtime-image edition, to @rpath paths
    # the rpath pins resolve root-agnostically (and the exec_closure
    # walk's @rpath arm materializes — spec 22). ld64 records a
    # dependency by the linked dylib's ID, so the rewrite touches three
    # row kinds: the two dylibs' LC_ID_DYLIB, libRlapack's reference to
    # libRblas, and every .so's references to either (lapack.so, the
    # library package .so's). Runs on the STAGED tree (a fresh copy per
    # install — idempotent); the provenance gate's arm 6/7 re-proves
    # the rewrite and the boot smoke proves the dlopen end to end.
    DARWIN_RPATH_DYLIBS = %w[libRblas.dylib libRlapack.dylib].freeze

    def fixup_darwin_install_names
      return unless @platform.macos?

      lib_r = File.join(staged_prefix_tree, "lib", "R")
      DARWIN_RPATH_DYLIBS.each do |lib|
        next if File.file?(File.join(lib_r, "lib", lib))

        raise TebakoRBuilder::Error.new(
          "no #{lib} under #{lib_r}/lib — this R's install grammar drifted (the @rpath fixup " \
          "expects the included BLAS/LAPACK dylibs at lib/R/lib)", 103
        )
      end

      rewritten = DARWIN_RPATH_DYLIBS.count do |lib|
        darwin_fixup_object(File.join(lib_r, "lib", lib), id: "@rpath/#{lib}")
      end
      rewritten += Dir.glob(File.join(lib_r, "**", "*.so")).sort.count do |so|
        darwin_fixup_object(so)
      end
      puts "   ... darwin install names: @rpath rewrite over #{rewritten} object(s) " \
           "(#{DARWIN_RPATH_DYLIBS.join(' + ')} — dyld consults LC_RPATH only for @rpath-spelled names)"
    end

    # One object's rows: -id when given (the dylib's own LC_ID_DYLIB),
    # plus -change for each DARWIN_RPATH_DYLIBS member the object
    # references by its bare name. Returns true when the object was
    # rewritten. install_name_tool re-signs ad-hoc on rewrite, so the
    # arm64 link signatures stay valid for dlopen.
    def darwin_fixup_object(path, id: nil)
      out = TebakoRBuilder::BuildHelpers.run_with_capture(["otool", "-L", path])
      rows = out.lines.drop(1).filter_map { |line| line.strip.split.first }
      args = []
      args += ["-id", id] if id
      DARWIN_RPATH_DYLIBS.each do |lib|
        next if id == "@rpath/#{lib}" # the -id rewrites the object's own row; -change is for dependents
        args += ["-change", lib, "@rpath/#{lib}"] if rows.include?(lib)
      end
      return false if args.empty?

      TebakoRBuilder::BuildHelpers.run_with_capture(["install_name_tool", *args, path])
      true
    rescue TebakoRBuilder::Error => e
      raise TebakoRBuilder::Error.new("'build_runtime' darwin install-name fixup failed for #{path}: #{e.message}", 103)
    end

    public

    # The staged prefix tree (the image root's content): stage/<root>
    # with the root spelling normalized ("/__tfs__" -> "__tfs__").
    def staged_prefix_tree
      spelling = @platform.mount_root.sub(%r{\A/+}, "")
      File.join(stage_dir, spelling).tap do |tree|
        next if File.directory?(tree)

        raise TebakoRBuilder::Error.new(
          "the staged install carries no #{spelling} tree under #{stage_dir} " \
          "(prefix #{@platform.mount_root} did not install as expected)", 105
        )
      end
    end
  end
end
