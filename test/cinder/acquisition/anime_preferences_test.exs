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

  test "a required chi subtitle setting accepts a release whose subtitles parse as zh (#519)" do
    policy = %{
      required_audio_languages: [],
      subtitle_languages: AnimePreferences.normalize_languages(["chi"]),
      embedded_subtitle_mode: :require,
      preferred_groups: [],
      blocked_groups: [],
      group_fallback_delay: 86_400
    }

    assert policy.subtitle_languages == ["zh"]

    release = %Release{
      title: "[Group] Show - 01 [1080p] [Chinese Subs]",
      group: "Group",
      embedded_subtitle_claim: :present,
      embedded_subtitle_languages: ["zh"]
    }

    assert AnimePreferences.verdict(release, policy) == :ok
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

  describe "group_wait/3" do
    @now ~U[2026-07-13 12:00:00Z]

    defp waiting_policy(groups), do: %{preferred_groups: groups, group_fallback_delay: 3_600}

    test "no preferred groups means nothing waits, dated or not" do
      assert AnimePreferences.group_wait(%Release{group: "Other"}, waiting_policy([]), @now) ==
               :eligible
    end

    test "a preferred group's release is eligible at once, whatever its case or spacing" do
      release = %Release{group: " SubsPlease ", published_at: @now}

      assert AnimePreferences.group_wait(release, waiting_policy(["subsplease"]), @now) ==
               :eligible
    end

    test "another group's release waits out the fallback delay from its publication" do
      release = %Release{group: "Other", published_at: @now}
      policy = waiting_policy(["subsplease"])

      assert AnimePreferences.group_wait(release, policy, ~U[2026-07-13 12:59:59Z]) ==
               {:delayed, ~U[2026-07-13 13:00:00Z]}

      assert AnimePreferences.group_wait(release, policy, ~U[2026-07-13 13:00:00Z]) == :eligible
    end

    test "another group's release with no publication time cannot start the wait" do
      policy = waiting_policy(["subsplease"])

      assert AnimePreferences.group_wait(%Release{group: "Other"}, policy, @now) == :undated

      assert AnimePreferences.group_wait(%Release{group: nil, published_at: "bad"}, policy, @now) ==
               :undated
    end
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
