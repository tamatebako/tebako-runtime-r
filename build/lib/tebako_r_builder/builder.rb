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
  # End-to-end runtime package build (tools/build_runtime): fetch + verify
  # the pristine CRAN source (sha256 against versions.yml's pins), stage
  # the pin-verified link unit and tfs CLI (the tamatebako/tebako
  # release), build the interpreter with the spec-17 driver linked in
  # (RBuild), assemble + pack the env image (ImageBuilder/ImagePackager),
  # and emit the package sidecars (the image's store-shape .sha256, the
  # exe's .abi facet, the era-2 .contract.yaml provenance card the release
  # pipeline will fold into the manifest entry when publish lands).
  class Builder
    # The era-2 contract card constants (spec 18 C2): what this factory
    # builds. Written into every package's .contract.yaml sidecar.
    CONTRACT_CARD = { "contract_era" => 2, "image_layout" => 1 }.freeze

    # The package name carries tebako#716's language segment from this
    # factory's FIRST line — tebako-runtime-<tebako>-r-<r>-<triplet> —
    # with no era gate: a factory born after the flip composes the
    # segment always (tebako-runtime-php's rationale; the era gate exists
    # only for factories with immutable pre-#716 lines — ruby's
    # <= 0.16.32, python's <= 0.2.x — and R has none).
    LANG_SEGMENT = "r"

    def initialize(repo_root:, r_version:, tebako_version:, prefix:, output:, # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength
                   jobs: nil, src_mirror: nil, link_unit_release: nil, link_unit_pid: nil, arch: nil)
      @repo_root = repo_root
      @r_version = r_version
      @r = TebakoRBuilder::RVersion.new(r_version)
      @tebako_version = tebako_version
      @prefix = File.expand_path(prefix)
      @output = output
      @jobs = jobs
      @contract = TebakoRBuilder::Contract.new
      @src_mirror = src_mirror
      @link_unit_release = link_unit_release || @contract.link_unit_release
      @link_unit_pid = link_unit_pid
      # The leg's DECLARED arch beats the tooling process's self-report:
      # under emulation host_cpu can lie, and every arch-keyed decision
      # (the link-unit pid, the package name) follows the lie.
      @platform = arch ? TebakoRBuilder::Platform.new(RUBY_PLATFORM, arch) : TebakoRBuilder::Platform.new
    end

    def run
      (tarball, sha256) = fetcher.fetch(@r.base_version)
      puts "-- Building tebako runtime for R #{@r_version} " \
           "(tebako #{@tebako_version}, #{@platform.host_id}, #{File.basename(tarball)})"
      link_unit_dir = link_unit.stage(File.join(@prefix, "link-unit"))
      tfs = tfs_tool.fetch
      build = TebakoRBuilder::RBuild.new(platform: @platform, r_version: @r_version,
                                         prefix: @prefix, tarball: tarball, src_sha256: sha256,
                                         link_unit: link_unit, link_unit_dir: link_unit_dir,
                                         repo_root: @repo_root, jobs: @jobs)
                                    .run
      finalize(build.exe_path)
      assemble_and_pack_image(build, sha256, link_unit, link_unit_dir, tfs)
      write_image_sidecar
      write_abi_sidecar(build)
      write_contract_sidecar(tarball, sha256, link_unit, build)
      @output = output
      puts "-- Runtime package: #{output}"
      puts "-- Runtime env image: #{image_output}"
      output
    end

    def default_output
      File.join(Dir.pwd, "runtime-packages",
                "tebako-runtime-#{@tebako_version}-#{LANG_SEGMENT}-#{@r_version}-#{@platform.host_id}#{@platform.exe_suffix}")
    end

    # The standalone runtime filesystem image published next to the
    # runtime executable (the image era's only filesystem image).
    def image_output
      "#{output.sub(/\.exe\z/, "")}.tfs"
    end

    private

    def output
      @output ||= default_output
    end

    def fetcher
      @fetcher ||= TebakoRBuilder::SourceFetcher.new(cache_dir: File.join(@prefix, "downloads"),
                                                     contract: @contract, mirror: @src_mirror)
    end

    def link_unit
      @link_unit ||= TebakoRBuilder::LinkUnit.new(release: @link_unit_release, platform: @platform,
                                                  pid: @link_unit_pid,
                                                  cache_dir: File.join(@prefix, "downloads"))
    end

    def tfs_tool
      @tfs_tool ||= TebakoRBuilder::TfsTool.new(release: @link_unit_release, platform: @platform,
                                                cache_dir: File.join(@prefix, "downloads"))
    end

    # The shipped exe is the build tree's driver-linked interpreter,
    # copied (never stripped — the symbol table is the symbol-provenance
    # assert's evidence on EVERY platform, ci/check_symbol_provenance.sh;
    # runtime size is not the gated artifact, the bootstrap is).
    def finalize(built_exe)
      FileUtils.mkdir_p(File.dirname(output))
      FileUtils.cp(built_exe, output)
      FileUtils.chmod(0o755, output)
    end

    def assemble_and_pack_image(build, sha256, link_unit, link_unit_dir, tfs)
      tree = TebakoRBuilder::ImageBuilder.new(platform: @platform, r_version: @r_version,
                                              tebako_version: @tebako_version, src_sha256: sha256,
                                              patch_set: "none (pristine CRAN tarball, versions.yml pin)",
                                              link_unit: link_unit, link_unit_dir: link_unit_dir,
                                              repo_root: @repo_root)
                                         .assemble(build.staged_prefix_tree, File.join(@prefix, "image-tree"))
      TebakoRBuilder::ImagePackager.new(@platform, tfs: tfs).package(tree, image_output)
    end

    # The store-layout trust marker next to the image (the store: every
    # cached runtime image carries its <image>.sha256): the leading token
    # is the content key the driver's exec-cache segregation (spec 22 §6)
    # reads. Written at build so a factory tree boots store-faithfully
    # (the boot smoke's TEBAKO_RUNTIME_IMAGE then resolves the same image
    # key the store would give it); never uploaded.
    def write_image_sidecar
      hex = TebakoRBuilder::BuildHelpers.sha256_file(image_output)
      File.write("#{image_output}.sha256", "#{hex}  #{File.basename(image_output)}\n")
    end

    # The runtime's abi facet (spec 05 §5's abi line) as `<output>.abi`.
    # The release flow folds it into the manifest entry's additive `abi`
    # key when publish lands.
    def write_abi_sidecar(build)
      File.write("#{output.sub(/\.exe\z/, "")}.abi", "#{build.abi}\n")
    end

    # The era-2 contract provenance (spec 18 C2) as
    # `<output>.contract.yaml`. built_from names the consumed tarballs
    # (the R source plus the deps stage's factory-built libraries) with
    # their verified sha256 and the pin file that anchored them, and records
    # the compile flags the build ACTUALLY ran with (RBuild's Makeconf
    # read-back — the boot smoke's compute-floor flags arm reads them from
    # this card, the only surface R has for them: the interpreter records
    # no CFLAGS at runtime, unlike CPython's sysconfig); the additive
    # link_unit block names the consumed product release's unit and its
    # API-declared digest (open parse — consumers that predate the key
    # ignore it).
    def write_contract_sidecar(tarball, sha256, link_unit, build)
      card = CONTRACT_CARD.merge(
        "mount_root" => @platform.mount_root,
        "built_from" => {
          "pin" => "versions.yml",
          "sources" => [{ "name" => File.basename(tarball), "sha256" => sha256 }] + build.dep_sources,
          "cflags" => build.recorded_cflags
        },
        "link_unit" => {
          "release" => @link_unit_release,
          "asset" => link_unit.asset_name
        }
      )
      File.write("#{output.sub(/\.exe\z/, "")}.contract.yaml", YAML.dump(card))
    end
  end
end
