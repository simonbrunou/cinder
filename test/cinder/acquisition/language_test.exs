defmodule Cinder.Acquisition.LanguageTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.{Language, Release}

  defp rel(language), do: struct(%Release{title: "fixture"}, language: language)

  describe "satisfies?/2" do
    test "MULTI satisfies any target" do
      assert Language.satisfies?(rel("MULTI"), "fr")
      assert Language.satisfies?(rel("MULTI"), "en")
    end

    test "an exact tag match satisfies; another language's tag does not" do
      assert Language.satisfies?(rel("FRENCH"), "fr")
      refute Language.satisfies?(rel("GERMAN"), "fr")
    end

    test "untagged means English audio — satisfies an English target only (the Hungarian-bug fix)" do
      # An untagged release is English by scene convention, so a French 'original' pick
      # (target "fr") drops it rather than treating it as the French original.
      assert Language.satisfies?(rel(nil), "en")
      refute Language.satisfies?(rel(nil), "fr")
      refute Language.satisfies?(rel(nil), "hu")
    end

    test "a recognised foreign tag satisfies only its own target" do
      # Hungarian dub of a French film (target "fr") or an English film (target "en"): dropped.
      refute Language.satisfies?(rel("HUNGARIAN"), "fr")
      refute Language.satisfies?(rel("HUNGARIAN"), "en")
      # A Hungarian-original film (target "hu") keeps its HUNGARIAN release — proves the parser
      # registry and this code↔tag table stay in sync (hu ⇒ HUNGARIAN).
      assert Language.satisfies?(rel("HUNGARIAN"), "hu")
    end
  end

  describe "satisfies_lang?/2" do
    test "satisfies_lang?/2 truth table" do
      assert Language.satisfies_lang?("MULTI", "fr")
      assert Language.satisfies_lang?(nil, "en")
      assert Language.satisfies_lang?("", "en")
      refute Language.satisfies_lang?(nil, "fr")
      assert Language.satisfies_lang?("FRENCH", "fr")
      refute Language.satisfies_lang?("HUNGARIAN", "fr")
      assert Language.satisfies_lang?("HUNGARIAN", nil) == true
    end
  end

  describe "target/2" do
    test "any disables the filter" do
      assert Language.target("any", "en") == nil
    end

    test "original resolves to the title's original language, off when unknown" do
      assert Language.target("original", "fr") == "fr"
      assert Language.target("original", nil) == nil
      assert Language.target("original", "") == nil
    end

    test "french always resolves to fr" do
      assert Language.target("french", "en") == "fr"
    end

    test "dual resolves to fr, same as french (the standard path)" do
      assert Language.target("dual", "en") == "fr"
    end
  end

  describe "preferences/0 and strict?/1" do
    test "dual is a valid pick and a strict (parking) preference" do
      assert "dual" in Language.preferences()
      assert Language.strict?("dual")
    end
  end

  describe "filter/3" do
    test "inactive filter returns releases unchanged" do
      releases = [rel("FRENCH"), rel(nil), rel("GERMAN")]
      assert Language.filter(releases, "any", "en") == releases
      assert Language.filter(releases, "original", nil) == releases
    end

    test "french filter keeps FRENCH + MULTI, drops the rest" do
      keep_fr = rel("FRENCH")
      keep_multi = rel("MULTI")
      releases = [keep_fr, rel(nil), rel("GERMAN"), keep_multi]
      assert Language.filter(releases, "french", "en") == [keep_fr, keep_multi]
    end

    test "original pick on a non-English film keeps untagged only under keep_untagged" do
      keep_fr = rel("FRENCH")
      keep_multi = rel("MULTI")
      untagged = rel(nil)
      releases = [keep_fr, rel("HUNGARIAN"), untagged, keep_multi]

      # A Hungarian dub is a confirmed mismatch and always dropped. An untagged release is kept
      # only for a caller that ranks its survivors (issue #191): French scene groups routinely
      # publish original-audio releases with a bare name.
      assert Language.filter(releases, "original", "fr", keep_untagged: true) ==
               [keep_fr, untagged, keep_multi]

      # Default (the set-cover callers, where coverage outranks language): still strict.
      assert Language.filter(releases, "original", "fr") == [keep_fr, keep_multi]
    end

    test "an explicit french pick stays strict about untagged releases even under keep_untagged" do
      keep_fr = rel("FRENCH")

      assert Language.filter([keep_fr, rel(nil)], "french", "fr", keep_untagged: true) == [
               keep_fr
             ]
    end

    test "dual filter behaves exactly like french: keeps FRENCH + MULTI, drops the rest" do
      keep_fr = rel("FRENCH")
      keep_multi = rel("MULTI")
      releases = [keep_fr, rel(nil), rel("GERMAN"), keep_multi]
      assert Language.filter(releases, "dual", "en") == [keep_fr, keep_multi]
    end
  end

  describe "leading_audio_mismatch?/2" do
    test "flags a file whose target track is present but not the leading one (issue #197)" do
      assert Language.leading_audio_mismatch?("en", ["tur", "eng"])
      assert Language.leading_audio_mismatch?("en", ["fre", "eng"])
      assert Language.leading_audio_mismatch?("ja", ["eng", "jpn"])
    end

    test "stays quiet when the leading track already is the target" do
      refute Language.leading_audio_mismatch?("en", ["eng", "fre"])
      refute Language.leading_audio_mismatch?("en", ["eng"])
    end

    test "stays quiet without a target, without evidence, or on an unrecognised head code" do
      refute Language.leading_audio_mismatch?(nil, ["fre", "eng"])
      refute Language.leading_audio_mismatch?("en", [])
      refute Language.leading_audio_mismatch?("en", nil)
      refute Language.leading_audio_mismatch?("en", ["zzz", "eng"])
    end

    test "a file missing the target entirely is audio_satisfies?/2's park, not this hint" do
      refute Language.leading_audio_mismatch?("en", ["tur", "fre"])
      refute Language.audio_satisfies?("en", ["tur", "fre"])
    end
  end

  describe "stream_status/3" do
    test "an exact normalized code satisfies even when it has no registered aliases" do
      assert Language.stream_status("is", ["is"], false) == :satisfied
      assert Language.stream_status("IS", ["iS"], false) == :satisfied
    end

    test "registered aliases and conservative unknown evidence retain their status" do
      assert Language.stream_status("fr", ["FRA"], false) == :satisfied
      assert Language.stream_status("is", ["zzz"], false) == :unknown
    end
  end
end
