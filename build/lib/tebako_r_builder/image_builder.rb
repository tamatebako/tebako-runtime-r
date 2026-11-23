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
require "yaml"

module TebakoRBuilder
  # Assembles the env image's layout tree from the staged install
  # (RBuild#staged_prefix_tree): the R install tree with the build-time
  # surface pruned, plus the tebako contract card (lib/tebako/layout.yaml),
  # the preload shim (POSIX — REQUIRED: the unpatched interpreter cannot
  # read its own mounted image without it, so a missing shim is a hard
  # error here, never the ruby factory's degrade), and the L1 payload
  # manifest (__tpkg__/manifest.yaml).
  #
  # The interpreter binary itself is NOT in the image — the exe ships
  # beside it (the image-era runtime's two-artifact shape). The staged
  # prefix's bin/ is pruned wholesale: it carries the build-tree Rscript
  # launcher and the R/Rcmd front-end SHELL scripts (dead weight here —
  # the fs TU carries the Rscript front-end in C, and a shell script
  # inside the VFS cannot be exec'd: the kernel's #! read never reaches
  # the preload shim). R_HOME/bin/ goes the same way (bin/exec/R — the
  # stock interpreter copy the exe replaces — plus Rscript and the R CMD
  # toolchain scripts, press-time surface a read-only runtime image
  # never needs). include/ and doc/ are press-time/interactive surface
  # (headers; the html manuals — per-package help lives in library/ and
  # stays). The skeleton declares NO spawn surface
  # (provides.entrypoints): R ships no console-script ecosystem of its
  # own in this configuration — the census's CRAN-closure lane lands with
  # the payload increment.
  class ImageBuilder
    # The env image's own contract declaration (spec 18 C3), read by the
    # driver post-mount, before the interpreter starts: a missing layout
    # is an era-1 refusal; a mount_root != the exe's compiled-in root is
    # exit 78. Field set per docs/spec/schemas/layout.yaml (snake_case):
    # schema/version, era, image_layout, mount_root,
    # interpreter_api_version; the additive mount_root_override grant
    # (schema_minor 1) is emitted ALWAYS (the mounts move, never R's
    # configuration — the fs TU's R_HOME follows the effective root); the
    # additive preload_shim grant (schema_minor 2) names exactly the
    # staged shim's in-image path.
    LAYOUT_DECLARATION = {
      "schema" => "layout",
      "schema_version" => 1,
      "era" => 2,
      "image_layout" => 1
    }.freeze
    LAYOUT_PATH = File.join("lib", "tebako", "layout.yaml").freeze

    # Pruned under the staged prefix tree (relative spellings): the
    # class comment's build-time surface. bin/ and share/ are the PREFIX
    # level (the man pages live in share/man); the rest is R_HOME's.
    PRUNE_TOP = %w[bin share].freeze
    PRUNE_FILES = [
      File.join("lib", "R", "bin"),
      File.join("lib", "R", "include"),
      File.join("lib", "R", "doc")
    ].freeze

    def initialize(platform:, r_version:, tebako_version:, src_sha256:, patch_set:, # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength
                   link_unit:, link_unit_dir:, repo_root:)
      @platform = platform
      @r = TebakoRBuilder::RVersion.new(r_version)
      @tebako_version = tebako_version
      @src_sha256 = src_sha256
      @patch_set = patch_set
      @link_unit = link_unit
      @link_unit_dir = link_unit_dir
      @repo_root = repo_root
    end

    # Copy the staged prefix tree into a fresh tree at dest and deploy the
    # tebako surface; returns dest (the image root — its CONTENTS map onto
    # the mount root).
    def assemble(staged_tree, dest)
      FileUtils.rm_rf(dest, secure: true)
      FileUtils.mkdir_p(dest)
      FileUtils.cp_r("#{staged_tree}/.", dest)
      prune(dest)
      deploy_preload(dest)
      deploy_layout(dest)
      deploy_manifest(dest)
      dest
    end

    private

    def prune(tree)
      PRUNE_TOP.each { |d| FileUtils.rm_rf(File.join(tree, d), secure: true) }
      PRUNE_FILES.each { |f| FileUtils.rm_rf(File.join(tree, f), secure: true) }
    end

    # The preload shim rides the env image at lib/tebako/ and is declared
    # via the layout's preload_shim grant, which the driver flows to the
    # injection env (LD_PRELOAD) and TEBAKO_PRELOAD_SHIM. The unpatched R
    # CANNOT read its own mounted image without the shim — its absence
    # from the link unit is a hard error (LinkUnit already fails the same
    # way; this is the staging side of the declaration's truthfulness).
    def deploy_preload(tree)
      src = @link_unit.preload_shim_path(@link_unit_dir)
      unless src && File.file?(src)
        raise TebakoRBuilder::Error.new(
          "no preload shim in the link unit at #{@link_unit_dir} — the image cannot declare " \
          "what it does not hold (the fs TU refuses such a boot with exit 78)", 131
        )
      end

      dest = File.join(tree, "lib", "tebako")
      FileUtils.mkdir_p(dest)
      FileUtils.cp(src, File.join(dest, File.basename(src)))
      puts "   ... preload shim: #{File.join(dest, File.basename(src))}"
    end

    def deploy_layout(tree)
      path = File.join(tree, LAYOUT_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      declaration = LAYOUT_DECLARATION.merge(
        "mount_root" => @platform.mount_root,
        "interpreter_api_version" => @r.api_version,
        "mount_root_override" => true,
        "preload_shim" => File.join("lib", "tebako", @link_unit.preload_shim_name)
      )
      File.write(path, YAML.dump(declaration))
      puts "   ... env image layout declaration: #{path}"
    end

    def deploy_manifest(tree)
      path = TebakoRBuilder::ImageManifest.new(platform: @platform,
                                               r_version: @r.r_version,
                                               tebako_version: @tebako_version,
                                               patch_set: @patch_set,
                                               src_sha256: @src_sha256).deploy(tree)
      puts "   ... env image payload manifest: #{path}"
    end
  end
end
