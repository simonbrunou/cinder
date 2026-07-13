defmodule Cinder.Acquisition.AnimePreferencesTest do
  use Cinder.DataCase, async: true

  alias Cinder.Acquisition.{AnimePreferences, Language, Release}
  alias Cinder.Catalog
  alias Cinder.Catalog.Series
  alias Cinder.Download.Intent

  import Cinder.CatalogFixtures

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

  test "override attrs distinguish inherit from an explicit blank list" do
    assert {:ok, %{subtitle_languages: nil}} =
             AnimePreferences.override_attrs(%{
               "subtitle_languages_mode" => "inherit",
               "subtitle_languages" => "fr,en"
             })

    assert {:ok, %{subtitle_languages: []}} =
             AnimePreferences.override_attrs(%{
               "subtitle_languages_mode" => "override",
               "subtitle_languages" => ""
             })
  end

  test "override attrs normalize fixed enums, lists, and whole-hour delays" do
    assert {:ok,
            %{
              audio_mode: :dual,
              embedded_subtitle_mode: :require,
              subtitle_languages: ["fr", "en"],
              preferred_release_groups: ["subsplease"],
              blocked_release_groups: [],
              group_fallback_delay: 21_600
            }} =
             AnimePreferences.override_attrs(%{
               "audio_mode" => "dual",
               "embedded_subtitle_mode" => "require",
               "subtitle_languages_mode" => "override",
               "subtitle_languages" => "FRA, en",
               "preferred_release_groups_mode" => "override",
               "preferred_release_groups" => "SubsPlease, subsplease",
               "blocked_release_groups_mode" => "override",
               "blocked_release_groups" => "",
               "group_fallback_delay_mode" => "override",
               "group_fallback_delay_hours" => "6"
             })

    assert {:error, :invalid_audio_mode} =
             AnimePreferences.override_attrs(%{"audio_mode" => "forged"})

    assert {:error, :invalid_subtitle_languages_mode} =
             AnimePreferences.override_attrs(%{
               "subtitle_languages_mode" => "override",
               "subtitle_languages" => %{}
             })

    for hours <- ["", "-1", "1.5"] do
      assert {:error, :invalid_group_fallback_delay} =
               AnimePreferences.override_attrs(%{
                 "group_fallback_delay_mode" => "override",
                 "group_fallback_delay_hours" => hours
               })
    end
  end

  test "form state exposes stored modes and retains submitted values" do
    title = %Series{
      audio_mode: :dual,
      subtitle_languages: [],
      embedded_subtitle_mode: nil,
      preferred_release_groups: ["subsplease"],
      blocked_release_groups: nil,
      group_fallback_delay: 21_600
    }

    assert %{
             "audio_mode" => "dual",
             "subtitle_languages_mode" => "override",
             "subtitle_languages" => "",
             "embedded_subtitle_mode" => "inherit",
             "preferred_release_groups_mode" => "override",
             "preferred_release_groups" => "subsplease",
             "blocked_release_groups_mode" => "inherit",
             "group_fallback_delay_mode" => "override",
             "group_fallback_delay_hours" => "6"
           } = AnimePreferences.form_state(title, %{})

    assert %{
             "audio_mode" => "dub",
             "group_fallback_delay_mode" => "override",
             "group_fallback_delay_hours" => "-1"
           } =
             AnimePreferences.form_state(title, %{
               "audio_mode" => "dub",
               "group_fallback_delay_mode" => "override",
               "group_fallback_delay_hours" => "-1"
             })
  end

  test "Catalog writers persist normalized overrides and broadcast exactly once" do
    movie =
      movie_fixture(%{
        media_profile: :anime,
        original_language: "ja",
        preferred_language: "french"
      })

    series =
      series_fixture(%{
        media_profile: :anime,
        original_language: "ja",
        preferred_language: "french"
      })

    Catalog.subscribe()
    Catalog.subscribe_series()
    params = valid_override_params()

    assert {:ok, updated_movie} = Catalog.set_anime_preferences(movie, params)
    assert updated_movie.audio_mode == :dual
    assert updated_movie.subtitle_languages == ["fr"]
    assert updated_movie.preferred_release_groups == ["subsplease"]
    assert updated_movie.group_fallback_delay == 21_600
    assert_receive {:movie_updated, ^updated_movie}
    refute_received {:movie_updated, _}

    assert {:ok, updated_series} = Catalog.set_anime_preferences(series, params)
    assert updated_series.audio_mode == :dual
    assert updated_series.subtitle_languages == ["fr"]
    assert updated_series.preferred_release_groups == ["subsplease"]
    assert updated_series.group_fallback_delay == 21_600
    series_id = series.id
    assert_receive {:series_updated, ^series_id}
    refute_received {:series_updated, ^series_id}
  end

  test "Catalog writer returns field errors and persists nothing invalid" do
    movie =
      movie_fixture(%{
        media_profile: :anime,
        original_language: "ja",
        preferred_language: "original"
      })

    Catalog.subscribe()

    assert {:error, changeset} =
             Catalog.set_anime_preferences(movie, %{"audio_mode" => "dub"})

    assert errors_on(changeset).audio_mode != []

    assert {:error, changeset} =
             Catalog.set_anime_preferences(movie, %{
               "group_fallback_delay_mode" => "override",
               "group_fallback_delay_hours" => "-1"
             })

    assert errors_on(changeset).group_fallback_delay != []

    assert {:error, changeset} =
             Catalog.set_anime_preferences(movie, %{
               "embedded_subtitle_mode" => "require",
               "subtitle_languages_mode" => "override",
               "subtitle_languages" => ""
             })

    assert errors_on(changeset).subtitle_languages != []

    fresh = Repo.reload!(movie)
    assert fresh.audio_mode == nil
    assert fresh.embedded_subtitle_mode == nil
    assert fresh.subtitle_languages == nil
    assert fresh.group_fallback_delay == nil
    refute_received {:movie_updated, _}
  end

  test "Catalog writer validates the current title at the write boundary" do
    stale =
      movie_fixture(%{
        media_profile: :anime,
        original_language: "ja",
        preferred_language: "french"
      })

    assert {:ok, current} = Catalog.set_movie_language(stale, "original")
    assert current.preferred_language == "original"
    Catalog.subscribe()

    assert {:error, changeset} =
             Catalog.set_anime_preferences(stale, valid_override_params())

    assert errors_on(changeset).audio_mode != []

    fresh = Repo.reload!(stale)
    assert fresh.preferred_language == "original"
    assert fresh.audio_mode == nil
    assert fresh.embedded_subtitle_mode == nil
    assert fresh.subtitle_languages == nil
    assert fresh.preferred_release_groups == nil
    assert fresh.blocked_release_groups == nil
    assert fresh.group_fallback_delay == nil
    refute_received {:movie_updated, _}
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

    assert {:ok, %{required_audio_languages: ["fr"]}} =
             AnimePreferences.resolve(
               %{base | audio_mode: :dub, preferred_language: "french"},
               @defaults
             )
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

  defp valid_override_params do
    %{
      "audio_mode" => "dual",
      "embedded_subtitle_mode" => "require",
      "subtitle_languages_mode" => "override",
      "subtitle_languages" => "fr",
      "preferred_release_groups_mode" => "override",
      "preferred_release_groups" => "SubsPlease, subsplease",
      "blocked_release_groups_mode" => "override",
      "blocked_release_groups" => "BadGroup",
      "group_fallback_delay_mode" => "override",
      "group_fallback_delay_hours" => "6"
    }
  end
end
