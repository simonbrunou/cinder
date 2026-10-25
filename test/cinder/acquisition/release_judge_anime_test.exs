defmodule Cinder.Acquisition.ReleaseJudgeAnimeTest do
  use ExUnit.Case, async: true

  import Cinder.AnimeFixtures, only: [neutral_anime_policy: 1]

  alias Cinder.Acquisition.{Anime, Release, ReleaseJudge}

  @gb 1_000_000_000
  @now ~U[2026-07-13 12:00:00Z]

  # `Catalog.movie_acquisition_context/1`'s shape.
  @movie %{kind: :movie, title: "Your Name", year: 2016, aliases: [], localized_titles: []}

  defp movie_release(title, attrs \\ []) do
    {origins, attrs} = Keyword.pop(attrs, :query_origins, [:id_scoped])

    %{title: title, size: 5 * @gb, download_url: title, published_at: @now}
    |> Map.merge(Map.new(attrs))
    |> Release.new()
    |> Map.put(:query_origins, origins)
  end

  defp policy(overrides \\ []), do: neutral_anime_policy(overrides)

  defp row(%ReleaseJudge{rows: rows}, title), do: Enum.find(rows, &(&1.release.title == title))

  # `Catalog.anime_series_acquisition_context/1`'s shape: two regular episodes and an OVA, each
  # with the stable-id mapping its release names resolve through.
  @series %{
    kind: :series,
    title: "Show",
    year: 2020,
    tvdb_id: 99,
    aliases: [],
    episodes: [
      %{id: 11, season_number: 1, episode_number: 1},
      %{id: 12, season_number: 1, episode_number: 2},
      %{id: 13, season_number: 0, episode_number: 1}
    ],
    mappings: [
      %{
        identity: %{
          source: "cinder",
          scheme: "standard",
          namespace: "canonical",
          canonical_value: "S01E01"
        },
        precedence: :manual,
        episode_ids: [11],
        evidence: %{"kind" => "fixture"}
      },
      %{
        identity: %{
          source: "cinder",
          scheme: "standard",
          namespace: "canonical",
          canonical_value: "S01E02"
        },
        precedence: :manual,
        episode_ids: [12],
        evidence: %{"kind" => "fixture"}
      },
      %{
        identity: %{
          source: "fixture",
          scheme: "typed_special",
          namespace: "main",
          canonical_value: "OVA:1"
        },
        precedence: :manual,
        episode_ids: [13],
        evidence: %{"kind" => "fixture"}
      }
    ]
  }

  @wanted [11, 12, 13]

  defp episode_release(title, attrs \\ []) do
    %{title: title, size: 2 * @gb, download_url: title, published_at: @now}
    |> Map.merge(Map.new(attrs))
    |> Release.new()
    |> Map.put(:query_origins, [:id_scoped])
  end

  defp judge_episodes(releases, opts),
    do: ReleaseJudge.judge(releases, {:anime_episodes, @series, @wanted}, opts)

  describe "anime movie stages" do
    test "each row names the first stage that drops it, and kept keeps indexer order" do
      releases = [
        movie_release("[Group] Your Name (2016) [1080p] usenet", protocol: :usenet),
        movie_release("[Group] Weathering With You (2019) [1080p]"),
        movie_release("[Group] Your Name (2016) [1080p] free", query_origins: [:free_text]),
        movie_release("Your.Name.2016.1080p.BluRay")
      ]

      judged =
        ReleaseJudge.judge(releases, {:anime_movie, @movie},
          protocols: [:torrent],
          anime_policy: policy(),
          now: @now
        )

      assert Enum.map(releases, &row(judged, &1.title).dropped_at) ==
               [:protocol, :title_guard, nil, nil]

      assert Enum.map(judged.kept, & &1.title) ==
               ["[Group] Your Name (2016) [1080p] free", "Your.Name.2016.1080p.BluRay"]

      assert row(judged, "[Group] Your Name (2016) [1080p] usenet").verdict ==
               {:rejected, :wrong_protocol}

      assert row(judged, "[Group] Weathering With You (2019) [1080p]").verdict ==
               {:rejected, :title_mismatch}
    end

    # The anime policy judges audio from release evidence, never the name's language tag.
    test "under an anime policy the language stage is off and no row carries a language fact" do
      judged =
        ReleaseJudge.judge(
          [movie_release("[Group] Your Name (2016) [1080p] [FRENCH]")],
          {:anime_movie, @movie},
          preferred_language: "french",
          original_language: "ja",
          anime_policy: policy()
        )

      assert judged.language == :off
      assert [%{dropped_at: nil, audio: nil}] = judged.rows
    end

    test "with no anime policy the movie language stage applies, untagged kept as assumed" do
      tagged = movie_release("[Group] Your Name (2016) [1080p] JAPANESE")
      untagged = movie_release("[Group] Your Name (2016) [1080p]")
      french = movie_release("[Group] Your Name (2016) [1080p] FRENCH")

      judged =
        ReleaseJudge.judge([french, untagged, tagged], {:anime_movie, @movie},
          preferred_language: "original",
          original_language: "ja"
        )

      assert judged.language == :applied
      assert Enum.map(judged.kept, & &1.title) == [untagged.title, tagged.title]
      assert row(judged, tagged.title).audio == :match
      assert row(judged, untagged.title).audio == :assumed
      assert row(judged, french.title).audio == :mismatch
    end

    test "a release with no protocol has no client to go to" do
      judged =
        ReleaseJudge.judge(
          [movie_release("[Group] Your Name (2016) [1080p]", protocol: nil)],
          {:anime_movie, @movie},
          protocols: [:torrent],
          anime_policy: policy()
        )

      assert [%{dropped_at: :protocol, verdict: {:rejected, :wrong_protocol}}] = judged.rows
    end
  end

  describe "anime movie verdicts" do
    # The sweep's order: the policy, then the quality rules, then the group wait. A release the
    # size band rules out is never taken, so "awaiting" would promise a grab that can't come.
    test "a kept row carries the anime selection's verdict: policy, quality, then group wait" do
      blocked = movie_release("[BadGroup] Your Name (2016) [1080p]")
      oversized = movie_release("[Other] Your Name (2016) [1080p] big", size: 20 * @gb)
      delayed = movie_release("[Other] Your Name (2016) [1080p]")
      undated = movie_release("[Other] Your Name (2016) [1080p] undated", published_at: nil)
      preferred = movie_release("[SubsPlease] Your Name (2016) [1080p]")

      judged =
        ReleaseJudge.judge(
          [blocked, oversized, delayed, undated, preferred],
          {:anime_movie, @movie},
          max_size: 10 * @gb,
          anime_policy: policy(preferred_groups: ["subsplease"], blocked_groups: ["badgroup"]),
          now: @now
        )

      assert Enum.all?(judged.rows, &(&1.dropped_at == nil))

      assert Map.new(judged.rows, &{&1.release.title, &1.verdict}) == %{
               blocked.title => {:rejected, :blocked_anime_group},
               oversized.title => {:rejected, :out_of_band},
               delayed.title => {:rejected, :awaiting_preferred_group},
               undated.title => {:rejected, :publication_time_required},
               preferred.title => :ok
             }

      assert hd(judged.rows).release.title == preferred.title
    end

    test "every row's release has its group read from the name, as the policy sees it" do
      judged =
        ReleaseJudge.judge(
          [movie_release("[SubsPlease] Your Name (2016) [1080p]")],
          {:anime_movie, @movie},
          anime_policy: policy()
        )

      assert [%{release: %Release{group: "SubsPlease"}}] = judged.rows
    end
  end

  describe "anime movie pick/1 agrees with the rows" do
    test "the pick is an acceptable kept row, with the policy it was taken under" do
      judged =
        ReleaseJudge.judge(
          [
            movie_release("[BadGroup] Your Name (2016) [2160p]"),
            movie_release("[SubsPlease] Your Name (2016) [1080p]")
          ],
          {:anime_movie, @movie},
          anime_policy: policy(blocked_groups: ["badgroup"]),
          now: @now
        )

      assert {:ok, picked} = ReleaseJudge.pick(judged)
      assert picked.title == "[SubsPlease] Your Name (2016) [1080p]"
      assert row(judged, picked.title).verdict == :ok
      assert picked.release_policy_snapshot["release_group"] == "subsplease"
    end

    test "with only delayed rows left, the pick waits for the earliest of them" do
      judged =
        ReleaseJudge.judge(
          [
            movie_release("[Other] Your Name (2016) [1080p]"),
            movie_release("[Later] Your Name (2016) [1080p]",
              published_at: DateTime.add(@now, 3600)
            )
          ],
          {:anime_movie, @movie},
          anime_policy: policy(preferred_groups: ["subsplease"]),
          now: @now
        )

      assert Enum.all?(judged.rows, &(&1.verdict == {:rejected, :awaiting_preferred_group}))

      assert ReleaseJudge.pick(judged) ==
               {:waiting_for_preferred_group, %{retry_at: ~U[2026-07-14 12:00:00Z]}}
    end

    test "a strict pick that empties the pool is no language match" do
      judged =
        ReleaseJudge.judge(
          [movie_release("[Group] Your Name (2016) [1080p]")],
          {:anime_movie, @movie},
          preferred_language: "french",
          original_language: "ja"
        )

      assert judged.language == :no_language_match
      assert ReleaseJudge.pick(judged) == :no_language_match
    end

    # The panel's group-wait verdict and the sweep's pick must read one clock: a release whose
    # wait ends between two reads would be "awaiting" in one and taken by the other.
    test "the judge pins the clock both read" do
      judged =
        ReleaseJudge.judge(
          [movie_release("[Other] Your Name (2016) [1080p]")],
          {:anime_movie, @movie},
          anime_policy: policy(preferred_groups: ["subsplease"])
        )

      assert %DateTime{} = judged.opts[:now]
    end
  end

  describe "anime episode stages" do
    test "each row names the first stage that drops it, and kept keeps indexer order" do
      releases = [
        episode_release("[Group] Show S01E01 [1080p] usenet", protocol: :usenet),
        episode_release("[Group] Show NCOP 1 [1080p]"),
        episode_release("[Group] Show OVA 1 [1080p]"),
        episode_release("[Group] Show S01E05 [1080p]"),
        episode_release("[Group] Show S01E02 [1080p]"),
        episode_release("[Group] Show S01E01 [1080p]")
      ]

      judged = judge_episodes(releases, protocols: [:torrent], anime_policy: policy())

      assert Enum.map(releases, &row(judged, &1.title).dropped_at) ==
               [:protocol, :role, :role, :mapping, nil, nil]

      assert Enum.map(judged.kept, & &1.title) ==
               ["[Group] Show S01E02 [1080p]", "[Group] Show S01E01 [1080p]"]

      assert Enum.map(judged.kept, & &1.resolved_episode_ids) == [[12], [11]]
      assert judged.language == :off
    end

    # The sweep never takes a typed special, but its frozen mapping makes it a safe manual grab.
    test "a row the panel can't grab says so first; a frozen typed special is manual-only" do
      judged =
        judge_episodes(
          [
            episode_release("[Group] Show S01E01 [1080p] usenet", protocol: :usenet),
            episode_release("[Group] Show NCOP 1 [1080p]"),
            episode_release("[Group] Show OVA 1 [1080p]"),
            episode_release("[Group] Show S01E05 [1080p]")
          ],
          protocols: [:torrent],
          anime_policy: policy()
        )

      assert Map.new(judged.rows, &{&1.release.title, &1.verdict}) == %{
               "[Group] Show S01E01 [1080p] usenet" => {:rejected, :wrong_protocol},
               "[Group] Show NCOP 1 [1080p]" => {:rejected, :unsafe_anime_mapping},
               "[Group] Show OVA 1 [1080p]" => {:rejected, :special_release},
               "[Group] Show S01E05 [1080p]" => {:rejected, :unsafe_anime_mapping}
             }

      assert row(judged, "[Group] Show OVA 1 [1080p]").release.resolved_episode_ids == [13]
    end

    # #699: the operator may override a title mismatch, since its frozen mapping makes the grab
    # safe; the sweep never takes it. A mismatch with no frozen mapping still says so first.
    test "a TVDB-scoped row naming another series drops at the title guard, the panel's to override" do
      other = episode_release("[Group] Other Show S01E01 [1080p]")
      unmapped = episode_release("[Group] Other Show S01E05 [1080p]")
      proved = episode_release("[Group] Other Show S01E02 [1080p]", tvdb_id: 99)
      own = episode_release("[Group] Show S01E01 [1080p]")

      judged = judge_episodes([other, unmapped, proved, own], anime_policy: policy())

      assert %{dropped_at: :title_guard, verdict: {:rejected, :title_mismatch}, release: release} =
               row(judged, other.title)

      assert release.resolved_episode_ids == [11]
      assert release.mapping_snapshot

      assert %{dropped_at: :title_guard, verdict: {:rejected, :unsafe_anime_mapping}} =
               row(judged, unmapped.title)

      assert Enum.map(judged.kept, & &1.title) == [proved.title, own.title]

      assert {:ok, %{assignments: assignments}} = ReleaseJudge.pick(judged)

      assert Map.new(assignments, &{&1.release.title, &1.episode_ids}) ==
               %{own.title => [11], proved.title => [12]}
    end

    test "a release with no protocol has no client to go to" do
      judged =
        judge_episodes([episode_release("[Group] Show S01E01 [1080p]", protocol: nil)],
          protocols: [:torrent],
          anime_policy: policy()
        )

      assert [%{dropped_at: :protocol, verdict: {:rejected, :wrong_protocol}}] = judged.rows
    end

    test "with no anime policy the season language stage applies, untagged not kept" do
      french = episode_release("[Group] Show S01E01 [1080p] FRENCH")
      untagged = episode_release("[Group] Show S01E02 [1080p]")

      judged =
        judge_episodes([french, untagged], preferred_language: "french", original_language: "ja")

      assert judged.language == :applied
      assert Enum.map(judged.kept, & &1.title) == [french.title]
      assert row(judged, untagged.title).dropped_at == :language
      assert row(judged, untagged.title).audio == :mismatch
    end
  end

  describe "anime episode verdicts" do
    test "a kept row carries the anime selection's verdict: policy, quality, then group wait" do
      blocked = episode_release("[BadGroup] Show S01E01 [1080p]")
      oversized = episode_release("[Other] Show S01E01 [1080p] big", size: 20 * @gb)
      delayed = episode_release("[Other] Show S01E01 [1080p]")
      undated = episode_release("[Other] Show S01E02 [1080p] undated", published_at: nil)
      preferred = episode_release("[SubsPlease] Show S01E02 [1080p]")

      judged =
        judge_episodes([blocked, oversized, delayed, undated, preferred],
          max_size: 10 * @gb,
          anime_policy: policy(preferred_groups: ["subsplease"], blocked_groups: ["badgroup"]),
          now: @now
        )

      assert Enum.all?(judged.rows, &(&1.dropped_at == nil))

      assert Map.new(judged.rows, &{&1.release.title, &1.verdict}) == %{
               blocked.title => {:rejected, :blocked_anime_group},
               oversized.title => {:rejected, :out_of_band},
               delayed.title => {:rejected, :awaiting_preferred_group},
               undated.title => {:rejected, :publication_time_required},
               preferred.title => :ok
             }
    end

    # The panel's verdict on a kept row and the sweep's one-release cover must agree: a release the
    # panel calls acceptable is one the sweep takes when it is the only one found.
    test "a kept row is acceptable exactly when the sweep would take it alone" do
      releases = [
        episode_release("[Group] Show S01E01 [1080p]"),
        episode_release("[Group] Show S01E01 [720p]", resolution: "720p"),
        episode_release("[Group] Show S01E01 [1080p] huge", size: 30 * @gb),
        episode_release("[Group] Show S01E01 [1080p] tiny", size: 1),
        episode_release("[Group] Show S01E01 [1080p] nosize", size: nil),
        episode_release("[Group] Show S01E01-E02 [1080p]", size: 18 * @gb),
        episode_release("[Group] Show S01E01 [1080p] CAM"),
        episode_release("[Group] Show S01E01 [1080p] blocked")
      ]

      opts = [
        min_size: 1 * @gb,
        max_size: 10 * @gb,
        preferred_resolutions: ["1080p"],
        blocked_terms: ["cam"],
        release_blocklist: ["[group] show s01e01 [1080p] blocked"],
        anime_policy: policy(),
        now: @now
      ]

      judged = judge_episodes(releases, opts)

      for release <- releases do
        taken? =
          match?(
            {:ok, %{assignments: [_ | _]}},
            Anime.select_episodes([release], @series, @wanted, opts)
          )

        assert row(judged, release.title).verdict == :ok == taken?, release.title
      end

      assert row(judged, "[Group] Show S01E01-E02 [1080p]").verdict == :ok
    end
  end

  describe "anime episode pick/1" do
    test "the pick covers the wanted ids from kept rows the panel accepts" do
      judged =
        judge_episodes(
          [
            episode_release("[BadGroup] Show S01E01 [2160p]"),
            episode_release("[Group] Show S01E01 [1080p]"),
            episode_release("[Group] Show S01E02 [1080p]"),
            episode_release("[Group] Show OVA 1 [1080p]")
          ],
          anime_policy: policy(blocked_groups: ["badgroup"]),
          now: @now
        )

      assert {:ok, %{assignments: assignments, waiting: nil}} = ReleaseJudge.pick(judged)

      assert Enum.map(assignments, &{&1.release.title, &1.episode_ids}) == [
               {"[Group] Show S01E01 [1080p]", [11]},
               {"[Group] Show S01E02 [1080p]", [12]}
             ]

      for %{release: release, mapping_snapshot: snapshot} <- assignments do
        assert row(judged, release.title).verdict == :ok
        assert snapshot == row(judged, release.title).release.mapping_snapshot
        assert release.release_policy_snapshot["release_group"] == "group"
      end
    end

    test "with only a delayed release for an episode, the pick waits for it" do
      judged =
        judge_episodes(
          [
            episode_release("[SubsPlease] Show S01E01 [1080p]"),
            episode_release("[Other] Show S01E02 [1080p]")
          ],
          anime_policy: policy(preferred_groups: ["subsplease"]),
          now: @now
        )

      assert {:ok, %{assignments: [assignment], waiting: waiting}} = ReleaseJudge.pick(judged)
      assert assignment.episode_ids == [11]
      assert waiting == %{episode_ids: [12], retry_at: ~U[2026-07-14 12:00:00Z]}
    end
  end
end
