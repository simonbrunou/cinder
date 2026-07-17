defmodule Cinder.Acquisition.AnimePreferencesTest do
  use Cinder.DataCase, async: true

  alias Cinder.Acquisition.{AnimePreferences, Language, Release}
  alias Cinder.Catalog.Series
  alias Cinder.Download.Intent

  @defaults %{
    subtitle_languages: ["fr", "en"],
    embedded_subtitle_mode: :prefer,
    preferred_groups: ["subsplease"],
    blocked_groups: ["badgroup"],
    group_fallback_delay: 86_400
  }

  test "resolve/2 returns the global defaults verbatim alongside the derived hard audio requirement" do
    title = %Series{original_language: "ja", preferred_language: "original"}

    assert {:ok, policy} = AnimePreferences.resolve(title, @defaults)
    assert policy.required_audio_languages == ["ja"]
    assert policy.subtitle_languages == ["fr", "en"]
    assert policy.preferred_groups == ["subsplease"]
    assert policy.blocked_groups == ["badgroup"]
    assert policy.embedded_subtitle_mode == :prefer
    assert policy.group_fallback_delay == 86_400
  end

  test "the Audio pick derives the hard audio requirement" do
    base = %Series{original_language: "jpn"}

    assert {:ok, %{required_audio_languages: ["ja"]}} =
             AnimePreferences.resolve(%{base | preferred_language: "original"}, @defaults)

    assert {:ok, %{required_audio_languages: ["fr"]}} =
             AnimePreferences.resolve(%{base | preferred_language: "french"}, @defaults)

    assert {:ok, %{required_audio_languages: ["ja", "fr"]}} =
             AnimePreferences.resolve(%{base | preferred_language: "dual"}, @defaults)

    assert {:ok, %{required_audio_languages: []}} =
             AnimePreferences.resolve(%{base | preferred_language: "any"}, @defaults)
  end

  test "the french pick needs no original-language metadata — the dub target is fixed at fr" do
    assert {:ok, %{required_audio_languages: ["fr"]}} =
             AnimePreferences.resolve(
               %Series{original_language: nil, preferred_language: "french"},
               @defaults
             )
  end

  test "original mode has no hard requirement when the source language is missing" do
    assert {:ok, %{required_audio_languages: []}} =
             AnimePreferences.resolve(%Series{original_language: nil}, @defaults)
  end

  test "dual rejects missing original metadata instead of degrading to dub-only" do
    title = %Series{original_language: nil, preferred_language: "dual"}

    assert {:error, :original_language_required} = AnimePreferences.resolve(title, @defaults)

    assert {:ok, %{required_audio_languages: ["fr"]}} =
             AnimePreferences.resolve(%{title | preferred_language: "french"}, @defaults)
  end

  test "unusable original metadata is not treated as a hard audio language" do
    title = %Series{original_language: "und", preferred_language: "dual"}

    assert {:error, :original_language_required} = AnimePreferences.resolve(title, @defaults)

    assert {:ok, %{required_audio_languages: []}} =
             AnimePreferences.resolve(%{title | preferred_language: "original"}, @defaults)
  end

  test "required embedded subtitles need at least one configured language" do
    assert {:error, :subtitle_language_required} =
             AnimePreferences.resolve(%Series{}, %{
               @defaults
               | embedded_subtitle_mode: :require,
                 subtitle_languages: []
             })
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
