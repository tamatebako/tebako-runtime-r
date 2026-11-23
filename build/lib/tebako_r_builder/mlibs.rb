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

module TebakoRBuilder
  # The tebako link line for the R.bin exe link (the substituted
  # $(R_binary) recipe's appended $(TEBAKO_LIBS)): the scoped Rust
  # staticlibs + the native closure, ELF legs wrapped in
  # -Wl,--start-group/--end-group (the dwarfs/codec archives have
  # circular member-level references).
  #
  # tebako-runtime-php's Mlibs port, one interpreter over: R links no
  # second openssl/zlib of its own against the closure (R's
  # zlib/bzip2/xz/pcre2 ride the exe STATICALLY — RBuild's -L
  # static-archive pin on linux, the deps stage on musl/darwin — so the
  # closure rides complete, the php no-second-consumer rule). ELF legs
  # wrap the tebako set in -Wl,--start-group/--end-group; the static
  # C++/gcc runtime tail and the libc-family statics (rt/util, proven
  # safe by the ruby factory) follow the group; the rest of libc stays
  # dynamic (always present on a glibc/musl host). The gfortran runtime
  # is static too (RBuild's FLIBS pin). darwin links the full set by
  # full path under ld_classic (below). msys arrives with the windows
  # leg — a platform with no link shape here is a named error, never a
  # wrong link line.
  class Mlibs
    def initialize(platform:, link_unit:, link_unit_dir:)
      @platform = platform
      @link_unit = link_unit
      @link_unit_dir = link_unit_dir
    end

    # The $(TEBAKO_LIBS) value substituted into the generated Makefile.
    def tebako_libs
      if @platform.macos?
        darwin_libs
      elsif @platform.linux?
        elf_libs
      else
        raise TebakoRBuilder::Error.new(
          "no tebako link line for #{@platform.ostype} yet — msys arrives with the windows leg", 112
        )
      end
    end

    private

    # ELF legs: the group around the tebako set (complete closure — the
    # class comment's no-second-consumer rule), then the static C++
    # runtime, then the libc-family tail statically where ruby proved it
    # safe (rt/util, glibc only — musl folds both into libc, so the musl
    # tail names only dl/pthread), the rest dynamically (always present
    # on a glibc/musl host).
    def elf_libs
      tail = %w[-static-libgcc -l:libstdc++.a -lgcc_eh]
      tail += @platform.musl? ? %w[-ldl -lpthread] : %w[-l:librt.a -l:libutil.a -ldl -lpthread]
      (["-Wl,--start-group"] + @link_unit.libraries(@link_unit_dir) + ["-Wl,--end-group"] + tail).join(" ")
    end

    # darwin: the full set by full path under ld_classic — Apple ld
    # implements neither -l:<file> nor --start-group, and ld_classic
    # resolves the cargo-bundled vague-linkage duplicates by the ODR rule
    # (tebako-runtime-ruby's Xcode 15 lesson; tebako-runtime-php's
    # darwin_libs is the proven shape). The closure rides COMPLETE (R's
    # interpreter binds no platform openssl/zlib of its own against it —
    # the class comment's no-second-consumer rule).
    # Security.framework + CoreFoundation.framework: the v2.8.4+ unit's
    # driver embeds the trust bridge's OS-store enumeration
    # (rustls-native-certs → security-framework objects; the same
    # driver's core_foundation / rustls_platform_verifier objects
    # reference _CFURL*/_CFUUID*/_kCF* symbols) — R's own configure line
    # pulls neither on darwin (the --without-x/--without-cairo/ICU=no
    # policy), so this factory's line must name both.
    def darwin_libs
      (["-Wl,-ld_classic"] + @link_unit.libraries(@link_unit_dir) +
       %w[-framework CoreFoundation -framework Security -lc++ -lc++abi]).join(" ")
    end
  end
end
