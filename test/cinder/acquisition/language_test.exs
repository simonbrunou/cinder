defmodule Cinder.Acquisition.LanguageTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.{Language, Release}

  defp rel(language), do: struct(%Release{title: "fixture"}, language: language)

  describe "satisfies?/3" do
    test "MULTI satisfies any target" do
      assert Language.satisfies?(rel("MULTI"), "fr", "en")
      assert Language.satisfies?(rel("MULTI"), "en", "fr")
    end

    test "french target: exact tag and MULTI satisfy; other tags do not" do
      assert Language.satisfies?(rel("FRENCH"), "fr", "en")
      refute Language.satisfies?(rel("GERMAN"), "fr", "en")
    end

    test "french target on an English-original title: untagged is rejected" do
      refute Language.satisfies?(rel(nil), "fr", "en")
    end

    test "french target on a French-original title: untagged is accepted (untagged = original audio)" do
      assert Language.satisfies?(rel(nil), "fr", "fr")
    end

    test "english/original target: untagged accepted, a foreign tag rejected" do
      assert Language.satisfies?(rel(nil), "en", "en")
      refute Language.satisfies?(rel("FRENCH"), "en", "en")
    end
  end

  describe "target/2 and active?/2" do
    test "any disables the filter" do
      assert Language.target("any", "en") == nil
      refute Language.active?("any", "en")
    end

    test "original resolves to the title's original language, off when unknown" do
      assert Language.target("original", "fr") == "fr"
      assert Language.target("original", nil) == nil
      assert Language.target("original", "") == nil
    end

    test "french always resolves to fr" do
      assert Language.target("french", "en") == "fr"
      assert Language.active?("french", nil)
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
  end
end
