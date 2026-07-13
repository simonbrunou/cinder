defmodule Cinder.Acquisition.AnimePreferencesTest do
  use Cinder.DataCase, async: true

  alias Cinder.Acquisition.{AnimePreferences, Language, Release}
  alias Cinder.Catalog.Series
  alias Cinder.Download.Intent

  @defaults %{
    audio_mode: :original,
    subtitle_languages: ["fr", "en"],
    embedded_subtitle_mode: :prefer,
    preferred_groups: ["SubsPlease"],
    blocked_groups: ["BadGroup"],
    group_fallback_delay: 86_400
  }

  test "nil inherits and explicit empty lists disable inherited lists" do
    title = %Series{original_language: "ja", preferred_language: "fr"}

    assert {:ok, inherited} = AnimePreferences.resolve(title, @defaults)
    assert inherited.required_audio_languages == ["ja"]
    assert inherited.subtitle_languages == ["fr", "en"]
    assert inherited.preferred_groups == ["subsplease"]
    assert inherited.provenance.preferred_groups == :inherited

    title = %{title | subtitle_languages: [], preferred_release_groups: []}
    assert {:ok, explicit} = AnimePreferences.resolve(title, @defaults)
    assert explicit.subtitle_languages == []
    assert explicit.preferred_groups == []
    assert explicit.provenance.subtitle_languages == :overridden
  end

  test "audio modes produce ordered hard requirements" do
    base = %Series{original_language: "jpn", preferred_language: "fra"}

    assert {:ok, %{required_audio_languages: ["ja"]}} =
             AnimePreferences.resolve(%{base | audio_mode: :original}, @defaults)

    assert {:ok, %{required_audio_languages: ["fr"]}} =
             AnimePreferences.resolve(%{base | audio_mode: :dub}, @defaults)

    assert {:ok, %{required_audio_languages: ["ja", "fr"]}} =
             AnimePreferences.resolve(%{base | audio_mode: :dual}, @defaults)

    assert {:ok, %{required_audio_languages: []}} =
             AnimePreferences.resolve(%{base | audio_mode: :any}, @defaults)
  end

  test "original mode has no hard requirement when the source language is missing" do
    assert {:ok, %{required_audio_languages: []}} =
             AnimePreferences.resolve(%Series{original_language: nil}, @defaults)
  end

  test "dub and dual require an explicit dub target" do
    for mode <- [:dub, :dual], preferred <- ["original", "any"] do
      assert {:error, :dub_language_required} =
               AnimePreferences.resolve(
                 %Series{audio_mode: mode, preferred_language: preferred},
                 @defaults
               )
    end
  end

  test "required embedded subtitles need a normalized language" do
    assert {:error, :subtitle_language_required} =
             AnimePreferences.resolve(
               %Series{embedded_subtitle_mode: :require, subtitle_languages: [" "]},
               @defaults
             )
  end

  test "languages and groups normalize once in first-seen order" do
    assert AnimePreferences.normalize_languages([
             " JPN ",
             "ja",
             "FRA",
             "fre",
             " EN ",
             "eng",
             ""
           ]) == ["ja", "fr", "en"]

    assert Language.normalize("jpn") == "ja"
    assert Language.normalize("fre") == "fr"

    assert AnimePreferences.normalize_groups([
             " SubsPlease ",
             "subsplease",
             "EMBER",
             " ember ",
             ""
           ]) == ["subsplease", "ember"]
  end

  test "snapshot freezes normalized hard requirements and release evidence" do
    policy = %{
      required_audio_languages: ["ja", "fr"],
      subtitle_languages: ["fr", "en"],
      embedded_subtitle_mode: :require
    }

    release = %Release{title: "Show.S01.DUAL.1080p-GROUP", group: " GROUP "}

    assert AnimePreferences.snapshot(policy, release) == %{
             "version" => 1,
             "required_audio_languages" => ["ja", "fr"],
             "required_embedded_subtitle_languages" => ["fr", "en"],
             "release_group" => "group",
             "release_title" => "Show.S01.DUAL.1080p-GROUP"
           }

    assert AnimePreferences.snapshot(%{policy | embedded_subtitle_mode: :prefer}, release)[
             "required_embedded_subtitle_languages"
           ] == []
  end

  test "a standard intent exposes no release policy snapshot by default" do
    intent =
      %Intent{}
      |> Intent.changeset(%{
        operation_key: "standard:#{System.unique_integer([:positive])}",
        kind: :movie,
        target_id: System.unique_integer([:positive]),
        protocol: :torrent,
        release: %{"title" => "Movie.1080p-GROUP"}
      })
      |> Repo.insert!()

    assert %Intent{release_policy_snapshot: nil} = intent
  end
end
