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
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# This factory's tebako-release declaration (ecosystem invariant 10: the
# release machinery's single owner is tamatebako/tebako-release-tooling —
# the gem the Gemfile pins at contract.yml's release_tooling). This file
# declares THIS factory's identity + policy through the gem's adapter
# seam; the machinery itself is never copied here. The tebako-release exe
# loads this file before dispatching (upload|sign).

$LOAD_PATH.unshift(File.expand_path("../build/lib", __dir__))
require "tebako_r_builder"

# The factory's release policy, delegated to the version model that owns
# each grammar (TebakoRBuilder::RVersion — spec 00 §10's single-owner
# rule; nothing here re-derives a name or a grammar). R ships no flavor
# lines and no DLL facet, so the defaults carry those axes.
class RReleaseAdapter < TebakoRelease::Adapter
  # The package-name grammar's version capture (x.y.z — plain; flavor
  # lines, when a census demands one, ride RVersion's grammar).
  # LINE_GRAMMAR_SOURCE, never LINE_PATTERN.source: the gem's parse
  # wraps the source in its own \A…\z and numbers the captures, so an
  # anchored/named-group source would never match.
  def version_grammar_source
    TebakoRBuilder::RVersion::LINE_GRAMMAR_SOURCE
  end

  # tebako#716's language segment of the package-name grammar
  # (`tebako-runtime-<ver>-r-<lv>-<triplet>`): ALWAYS "r" — this
  # factory was born after the flip, so it has no immutable pre-#716
  # line to keep composing (Builder::LANG_SEGMENT is the same fact's
  # build-side owner; tebako-runtime-php's adapter rationale).
  def lang_name
    TebakoRBuilder::Builder::LANG_SEGMENT
  end
end

TebakoRelease.configure(
  repo: "tamatebako/tebako-runtime-r",
  language: "r",
  title_prefix: "Tebako R runtime packages",
  contract_yml: File.expand_path("../contract.yml", __dir__),
  adapter: RReleaseAdapter.new
)
