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

    test "original pick on a non-English film keeps only its original-language tag + MULTI" do
      keep_fr = rel("FRENCH")
      keep_multi = rel("MULTI")
      # A Hungarian dub and an untagged (English) release are both dropped for a French original.
      releases = [keep_fr, rel("HUNGARIAN"), rel(nil), keep_multi]
      assert Language.filter(releases, "original", "fr") == [keep_fr, keep_multi]
    end
  end
end
