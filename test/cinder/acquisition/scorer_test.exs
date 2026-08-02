defmodule Cinder.Acquisition.ScorerTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Release
  alias Cinder.Acquisition.Scorer

  @gb 1_000_000_000

  # Build a Release fixture from just the fields the scorer reads.
  defp release(attrs), do: struct(%Release{title: "fixture"}, attrs)

  describe "select/2" do
    test "happy path: picks the band-fitting 1080p from a mixed list" do
      releases = [
        release(resolution: "720p", group: "A", size: 4 * @gb),
        release(resolution: "1080p", group: "B", size: 9 * @gb),
        release(resolution: "2160p", group: "C", size: 40 * @gb)
      ]

      assert {:ok, %Release{group: "B", resolution: "1080p"}} =
               Scorer.select(releases, min_size: 1 * @gb, max_size: 20 * @gb)
    end

    test "a tag-satisfying release outranks an untagged one the language filter merely kept" do
      # Both survive Language.filter for a soft "original" pick on a French title. The untagged
      # one is the better release on every other axis, so only the language rank keeps the
      # confirmed-French pick ahead of it (issue #191's safety net).
      tagged = release(title: "T", language: "FRENCH", resolution: "720p", size: 4 * @gb)
      untagged = release(title: "U", language: nil, resolution: "1080p", size: 9 * @gb)
      opts = [max_size: 20 * @gb, preferred_language: "original", original_language: "fr"]

      assert {:ok, %Release{title: "T"}} = Scorer.select([untagged, tagged], opts)

      # With nothing tagged in the pool the untagged release still wins — it is ranked down,
      # not rejected, so a French title with only untagged candidates still grabs.
      assert {:ok, %Release{title: "U"}} = Scorer.select([untagged], opts)
    end

    test "the language rank is a no-op under an anime policy" do
      # The anime pools never run Language.filter, so ranking on the parsed name here would demote
      # the untagged releases that make up most of an anime pool and let a bare MULTI token beat
      # resolution. Same fixtures as above, but Japanese-original with a policy set: resolution
      # decides again.
      tagged = release(title: "T", language: "MULTI", resolution: "720p", size: 4 * @gb)
      untagged = release(title: "U", language: nil, resolution: "1080p", size: 9 * @gb)

      # A neutral policy: every anime_rank_key term ties, so language_rank alone would decide.
      policy = %{
        preferred_groups: [],
        required_audio_languages: [],
        embedded_subtitle_mode: :allow,
        subtitle_languages: []
      }

      opts = [
        max_size: 20 * @gb,
        preferred_language: "original",
        original_language: "ja",
        anime_policy: policy
      ]

      assert {:ok, %Release{title: "U"}} = Scorer.select([untagged, tagged], opts)
    end

    test "all-too-large: every release exceeds max_size -> :no_match" do
      releases = [
        release(resolution: "1080p", group: "A", size: 30 * @gb),
        release(resolution: "720p", group: "B", size: 25 * @gb)
      ]

      assert :no_match = Scorer.select(releases, max_size: 20 * @gb)
    end

    test "release_blocklist excludes a release by title (case-insensitive), still picks the rest" do
      a = release(title: "Movie.A.1080p", resolution: "1080p", group: "A", size: 9 * @gb)
      b = release(title: "Movie.B.720p", resolution: "720p", group: "B", size: 5 * @gb)

      # A is the natural winner (1080p); blocking its title (downcased) drops it -> B.
      assert {:ok, %Release{title: "Movie.B.720p"}} =
               Scorer.select([a, b], release_blocklist: ["movie.a.1080p"], max_size: 20 * @gb)

      # Both titles blocked -> :no_match.
      assert :no_match =
               Scorer.select([a, b], release_blocklist: ["movie.a.1080p", "movie.b.720p"])

      # Negative control: with no release_blocklist, A wins — the filter is load-bearing.
      assert {:ok, %Release{title: "Movie.A.1080p"}} = Scorer.select([a, b], max_size: 20 * @gb)
    end

    test "prefers 1080p over an equally-sized 720p" do
      releases = [
        release(resolution: "720p", group: "A", size: 8 * @gb),
        release(resolution: "1080p", group: "B", size: 8 * @gb)
      ]

      assert {:ok, %Release{resolution: "1080p"}} = Scorer.select(releases)
    end

    test "resolution allow-list: a resolution outside the preferred list is rejected, not down-ranked" do
      # The user asked for 1080p; a 480p must never be grabbed even when it is the only candidate.
      assert :no_match =
               Scorer.select([release(resolution: "480p", group: "A", size: 4 * @gb)],
                 preferred_resolutions: ["1080p", "720p"]
               )

      # Default preferred is ["1080p","720p"]: 2160p and an untagged (nil) release are both
      # outside it, so a list of only those parks rather than grabbing a non-asked-for resolution.
      assert :no_match =
               Scorer.select([
                 release(resolution: "2160p", group: "A", size: 30 * @gb),
                 release(resolution: nil, group: "B", size: 5 * @gb)
               ])

      # Widening the allow-list lets the higher resolution back in (now in-list, top-ranked).
      assert {:ok, %Release{resolution: "2160p"}} =
               Scorer.select(
                 [
                   release(resolution: "2160p", group: "A", size: 30 * @gb),
                   release(resolution: "1080p", group: "B", size: 8 * @gb)
                 ],
                 preferred_resolutions: ["2160p", "1080p"]
               )
    end

    test "an empty allow-list disables the resolution gate (never bricks grabs)" do
      releases = [release(resolution: nil, group: "A", size: 5 * @gb)]
      assert {:ok, %Release{group: "A"}} = Scorer.select(releases, preferred_resolutions: [])
    end

    test "empty input -> :no_match" do
      assert :no_match = Scorer.select([])
    end

    test "a release with unknown (nil) size fails a configured max band" do
      # Some indexers omit size; with a max set we can't verify the upper bound, so reject it
      # rather than let `size || 0` sail it past the band (the S2 bug).
      releases = [release(resolution: "1080p", group: "A", size: nil)]
      assert :no_match = Scorer.select(releases, max_size: 20 * @gb)
    end

    test "a release with unknown (nil) size is acceptable when no band is configured" do
      releases = [release(resolution: "1080p", group: "A", size: nil)]
      assert {:ok, %Release{group: "A"}} = Scorer.select(releases)
    end

    test "a recognized but unlisted source is rejected" do
      assert :no_match =
               Scorer.select([release(resolution: "1080p", source: "hdtv", size: 4 * @gb)],
                 preferred_sources: ["bluray", "webdl"]
               )
    end

    test "an untagged (nil) source passes the source filter" do
      assert {:ok, %Release{source: nil}} =
               Scorer.select([release(resolution: "1080p", source: nil, size: 4 * @gb)],
                 preferred_sources: ["bluray"]
               )
    end

    test "prefers the higher-ranked source within the same resolution and size" do
      releases = [
        release(resolution: "1080p", source: "webdl", size: 8 * @gb),
        release(resolution: "1080p", source: "bluray", size: 8 * @gb)
      ]

      assert {:ok, %Release{source: "bluray"}} =
               Scorer.select(releases, preferred_sources: ["bluray", "webdl"])
    end

    test "empty preferred_sources accepts any source" do
      assert {:ok, %Release{source: "cam"}} =
               Scorer.select([release(resolution: "1080p", source: "cam", size: 4 * @gb)])
    end

    test "resolution outranks source: a 1080p webdl beats a 720p bluray" do
      releases = [
        release(resolution: "720p", source: "bluray", size: 8 * @gb),
        release(resolution: "1080p", source: "webdl", size: 8 * @gb)
      ]

      assert {:ok, %Release{resolution: "1080p"}} =
               Scorer.select(releases, preferred_sources: ["bluray", "webdl"])
    end
  end

  describe "resolution_rank/2" do
    test "resolution_rank/2 ranks a resolution string by preference, nil/unknown last" do
      pref = ["1080p", "720p"]
      assert Scorer.resolution_rank("1080p", pref) == 0
      assert Scorer.resolution_rank("720p", pref) == 1
      assert Scorer.resolution_rank("2160p", pref) == 2
      assert Scorer.resolution_rank(nil, pref) == 2
    end
  end

  describe "select_for/4 (TV)" do
    test "a season pack covering the whole wanted set is chosen, paired with its coverage" do
      releases = [release(season: 1, episodes: nil, resolution: "1080p", size: 6 * @gb)]

      # The pairing reports the exact episodes the pack is responsible for (the whole want).
      assert {:ok, [{%Release{episodes: nil, resolution: "1080p"}, [1, 2, 3]}]} =
               Scorer.select_for(releases, 1, [1, 2, 3])
    end

    test "an out-of-band pack falls back to per-episode singles" do
      releases = [
        release(season: 1, episodes: nil, resolution: "1080p", size: 100 * @gb),
        release(season: 1, episodes: [1], resolution: "1080p", size: 2 * @gb),
        release(season: 1, episodes: [2], resolution: "1080p", size: 2 * @gb)
      ]

      # per-episode max 5GB: the pack covers 2 eps (budget 10GB) but is 100GB -> rejected.
      assert {:ok, chosen} = Scorer.select_for(releases, 1, [1, 2], max_size: 5 * @gb)
      assert chosen |> Enum.map(fn {r, _cov} -> r.episodes end) |> Enum.sort() == [[1], [2]]
      assert chosen |> Enum.map(fn {_r, cov} -> cov end) |> Enum.sort() == [[1], [2]]
    end

    # full_claim_only is the upgrade sweep's rule: it can only take a release whose every file it
    # can link to an episode it holds. It must filter candidates, not judge the winner — the cover
    # is greedy, so a pack takes the whole wanted set and the singles behind it are never scored.
    test "full_claim_only drops a pack carrying more than the want, falling back to singles" do
      releases = [
        release(season: 1, episodes: nil, resolution: "1080p", size: 6 * @gb),
        release(season: 1, episodes: [1], resolution: "1080p", size: 2 * @gb)
      ]

      # 10 episodes in the season, 2 wanted: the pack carries 8 files nothing can claim.
      assert {:ok, [{%Release{episodes: [1]}, [1]}]} =
               Scorer.select_for(releases, 1, [1, 2],
                 full_claim_only: true,
                 pack_episode_count: 10
               )

      # Same pack, same call, once the want IS the whole season.
      assert {:ok, [{%Release{episodes: nil}, [1, 2]}]} =
               Scorer.select_for(releases, 1, [1, 2],
                 full_claim_only: true,
                 pack_episode_count: 2
               )
    end

    # The rule has to be re-checked against the SHRINKING needed set: an up-front filter passes a
    # release that overlaps a later pick, and the cover then truncates its assignment — which is
    # the unclaimed-file case all over again.
    test "full_claim_only drops a release an earlier pick would truncate" do
      releases = [
        release(season: 1, episodes: [1, 2], resolution: "1080p", size: 4 * @gb),
        release(season: 1, episodes: [2, 3], resolution: "1080p", size: 4 * @gb)
      ]

      assert {:ok, [{%Release{episodes: [1, 2]}, [1, 2]}]} =
               Scorer.select_for(releases, 1, [1, 2, 3],
                 full_claim_only: true,
                 pack_episode_count: 3
               )

      # Off, the second release is still taken for the one episode left of it.
      assert {:ok, [_first, {%Release{episodes: [2, 3]}, [3]}]} =
               Scorer.select_for(releases, 1, [1, 2, 3])
    end

    test "full_claim_only drops a multi-episode release naming an episode outside the want" do
      releases = [release(season: 1, episodes: [1, 2], resolution: "1080p", size: 4 * @gb)]

      assert :no_match =
               Scorer.select_for(releases, 1, [1], full_claim_only: true, pack_episode_count: 10)

      # Off (every other caller), the same release still covers what it can.
      assert {:ok, [{%Release{episodes: [1, 2]}, [1]}]} = Scorer.select_for(releases, 1, [1])
    end

    test "a range and a single greedily cover a multi-episode want with disjoint coverage" do
      releases = [
        release(season: 1, episodes: [1, 2, 3], resolution: "1080p", size: 6 * @gb),
        release(season: 1, episodes: [4], resolution: "1080p", size: 2 * @gb)
      ]

      assert {:ok, chosen} = Scorer.select_for(releases, 1, [1, 2, 3, 4])
      assert Enum.map(chosen, fn {r, _cov} -> r.episodes end) == [[1, 2, 3], [4]]
      # Coverage is disjoint and exactly the wanted set, partitioned across the picks.
      assert Enum.map(chosen, fn {_r, cov} -> cov end) == [[1, 2, 3], [4]]
    end

    test "an alternate bare-season pack covers every mapped episode in that season" do
      pack = release(season: 2, episodes: nil, resolution: "1080p", size: 6 * @gb)
      numbering = %{2 => %{1 => [29], 2 => [30], 3 => [31]}}

      assert {:ok, [{^pack, [29, 30, 31]}]} =
               Scorer.select_for([pack], 1, [29, 30, 31], alternate_numbering: numbering)
    end

    test "an alternate multi-episode range covers its mapped canonical episodes" do
      range = release(season: 2, episodes: [1, 2, 3], resolution: "1080p", size: 6 * @gb)
      numbering = %{2 => %{1 => [29], 2 => [30], 3 => [31]}}

      assert {:ok, [{^range, [29, 30, 31]}]} =
               Scorer.select_for([range], 1, [29, 30, 31], alternate_numbering: numbering)
    end

    test "an unmapped alternate episode contributes zero coverage" do
      release = release(season: 2, episodes: [4], resolution: "1080p", size: 2 * @gb)
      numbering = %{2 => %{1 => [29]}}

      assert :no_match =
               Scorer.select_for([release], 1, [29], alternate_numbering: numbering)
    end

    test "an empty or absent alternate map leaves native selection unchanged" do
      native = release(season: 1, episodes: [1], resolution: "1080p", size: 2 * @gb)
      other = release(season: 2, episodes: [1], resolution: "1080p", size: 2 * @gb)

      assert Scorer.select_for([native, other], 1, [1]) ==
               Scorer.select_for([native, other], 1, [1], alternate_numbering: %{})
    end

    test "the per-episode size band scales with alternate coverage" do
      range = release(season: 2, episodes: [1, 2], resolution: "1080p", size: 9 * @gb)
      single = release(season: 2, episodes: [1], resolution: "1080p", size: 9 * @gb)
      numbering = %{2 => %{1 => [29], 2 => [30]}}

      assert {:ok, [{^range, [29, 30]}]} =
               Scorer.select_for([range], 1, [29, 30],
                 alternate_numbering: numbering,
                 max_size: 5 * @gb
               )

      assert :no_match =
               Scorer.select_for([single], 1, [29],
                 alternate_numbering: numbering,
                 max_size: 5 * @gb
               )
    end

    test "release_blocklist drops a pack by title; the wanted set is covered from the rest" do
      pack =
        release(
          title: "Show.S01.1080p",
          season: 1,
          episodes: nil,
          resolution: "1080p",
          size: 6 * @gb
        )

      e1 =
        release(
          title: "Show.S01E01.1080p",
          season: 1,
          episodes: [1],
          resolution: "1080p",
          size: 2 * @gb
        )

      e2 =
        release(
          title: "Show.S01E02.1080p",
          season: 1,
          episodes: [2],
          resolution: "1080p",
          size: 2 * @gb
        )

      # The pack would cover both in one grab and win; blocking its title forces the singles.
      assert {:ok, chosen} =
               Scorer.select_for([pack, e1, e2], 1, [1, 2], release_blocklist: ["show.s01.1080p"])

      titles = chosen |> Enum.map(fn {r, _} -> r.title end) |> Enum.sort()
      assert titles == ["Show.S01E01.1080p", "Show.S01E02.1080p"]
    end

    test "the size band scales per episode (a pack passes where a single would not)" do
      pack = release(season: 1, episodes: nil, resolution: "1080p", size: 9 * @gb)
      single = release(season: 1, episodes: [1], resolution: "1080p", size: 9 * @gb)

      # per-episode max 5GB: pack covers 3 (budget 15GB) -> ok; single covers 1 (budget 5GB) -> too big.
      assert {:ok, [{%Release{episodes: nil}, [1, 2, 3]}]} =
               Scorer.select_for([pack], 1, [1, 2, 3], max_size: 5 * @gb)

      assert :no_match = Scorer.select_for([single], 1, [1], max_size: 5 * @gb)
    end

    # #268 (Charmed S03): 4 of 22 episodes still wanted budgeted the pack at 4×4 GB = 16 GB and
    # rejected a 19.7 GB pack that is ~0.9 GB/episode — the fewer episodes remained, the harsher
    # the effective per-episode cap. `pack_episode_count` bands it by what it CONTAINS instead.
    test "pack_episode_count bands a whole-season pack by the episodes it contains" do
      pack = release(season: 3, episodes: nil, resolution: "1080p", size: 197 * div(@gb, 10))
      wanted = [19, 20, 21, 22]

      assert {:ok, [{%Release{episodes: nil}, ^wanted}]} =
               Scorer.select_for([pack], 3, wanted, max_size: 4 * @gb, pack_episode_count: 22)

      # Without the opt the band is 4 wanted × 4 GB = 16 GB and the same pack is out of band.
      assert :no_match = Scorer.select_for([pack], 3, wanted, max_size: 4 * @gb)
    end

    # The guard for the two-pass shape in `Acquisition.best_releases/4`: `cover/6` sorts by
    # coverage BEFORE rank, so a widened pack outranks every single behind it. Widening on the
    # first pass would trade four 1 GB singles for one 19.7 GB pack, which is why the widened
    # band only ever runs after a clean :no_match.
    test "a widened pack would outrank the singles it covers (why the widening is last-resort)" do
      pack =
        release(
          title: "pack",
          season: 3,
          episodes: nil,
          resolution: "1080p",
          size: 197 * div(@gb, 10)
        )

      singles =
        Enum.map(19..22, fn n ->
          release(title: "e#{n}", season: 3, episodes: [n], resolution: "1080p", size: 1 * @gb)
        end)

      wanted = [19, 20, 21, 22]
      opts = [max_size: 4 * @gb]

      # First pass (no pack_episode_count): the pack is out of band, so the singles are chosen.
      assert {:ok, chosen} = Scorer.select_for([pack | singles], 3, wanted, opts)
      assert chosen |> Enum.map(fn {r, _cov} -> r.title end) |> Enum.sort() == ~w(e19 e20 e21 e22)

      # Same pool with the widened band: the pack takes the whole want in one greedy step.
      assert {:ok, [{%Release{title: "pack"}, ^wanted}]} =
               Scorer.select_for([pack | singles], 3, wanted, opts ++ [pack_episode_count: 22])
    end

    test "releases for another season (and movies) are ignored" do
      releases = [
        release(season: 2, episodes: [1], resolution: "1080p", size: 2 * @gb),
        release(season: nil, episodes: nil, resolution: "1080p", size: 2 * @gb)
      ]

      assert :no_match = Scorer.select_for(releases, 1, [1])
    end

    test "partial coverage returns what was found; the rest stay wanted" do
      releases = [release(season: 1, episodes: [1], resolution: "1080p", size: 2 * @gb)]

      assert {:ok, [{%Release{episodes: [1]}, [1]}]} = Scorer.select_for(releases, 1, [1, 2, 3])
    end

    test "no releases -> :no_match" do
      assert :no_match = Scorer.select_for([], 1, [1])
    end

    test "honours the source filter and tiebreak per episode" do
      releases = [
        release(season: 1, episodes: [1], resolution: "1080p", source: "webdl", size: 2 * @gb),
        release(season: 1, episodes: [1], resolution: "1080p", source: "bluray", size: 2 * @gb),
        release(season: 1, episodes: [2], resolution: "1080p", source: "hdtv", size: 2 * @gb)
      ]

      assert {:ok, picks} =
               Scorer.select_for(releases, 1, [1, 2],
                 preferred_sources: ["bluray", "webdl"],
                 max_size: 5 * @gb
               )

      sources = Enum.map(picks, fn {release, _covered} -> release.source end)

      # ep1 prefers bluray over webdl; ep2's only release (hdtv) is unlisted → rejected, stays wanted.
      assert sources == ["bluray"]
    end

    test "with no size band, any release is acceptable (the band is poller-supplied)" do
      releases = [release(season: 1, episodes: [1], resolution: "1080p", size: 200 * @gb)]

      assert {:ok, [{%Release{episodes: [1]}, [1]}]} = Scorer.select_for(releases, 1, [1])
    end

    test "a pack with unknown (nil) size is rejected under a configured band (S2)" do
      releases = [release(season: 1, episodes: nil, resolution: "1080p", size: nil)]
      assert :no_match = Scorer.select_for(releases, 1, [1, 2], max_size: 5 * @gb)
    end

    test "the resolution allow-list also gates TV episode releases" do
      releases = [release(season: 1, episodes: [1], resolution: "480p", size: 2 * @gb)]

      assert :no_match =
               Scorer.select_for(releases, 1, [1], preferred_resolutions: ["1080p", "720p"])
    end
  end

  describe "select_for_ids/3" do
    test "greedily assigns disjoint stable IDs and keeps the per-episode size band" do
      pack = release(resolved_episode_ids: [11, 12], resolution: "1080p", size: 4 * @gb)
      single = release(resolved_episode_ids: [13], resolution: "1080p", size: 2 * @gb)

      assert {:ok, [{^pack, [11, 12]}, {^single, [13]}]} =
               Scorer.select_for_ids([single, pack], [11, 12, 13], max_size: 3 * @gb)
    end

    test "rejects a candidate with no wanted stable IDs" do
      release = release(resolved_episode_ids: [99], resolution: "1080p", size: @gb)
      assert :no_match = Scorer.select_for_ids([release], [11])
    end

    test "does not truncate an overlapping release to the remaining IDs" do
      first = release(resolved_episode_ids: [11, 12], resolution: "1080p", size: 4 * @gb)
      overlap = release(resolved_episode_ids: [12, 13], resolution: "720p", size: 4 * @gb)

      assert {:ok, [{^first, [11, 12]}]} =
               Scorer.select_for_ids([overlap, first], [11, 12, 13])
    end

    test "preserves non-monotonic resolved membership order" do
      release = release(resolved_episode_ids: [20, 10], resolution: "1080p", size: 2 * @gb)
      assert {:ok, [{^release, [20, 10]}]} = Scorer.select_for_ids([release], [10, 20])
    end
  end

  describe "source_rank/2 (public for Library.Upgrade)" do
    test "index in the preference list; nil/unlisted sorts last" do
      assert Scorer.source_rank("bluray", ["bluray", "webdl"]) == 0
      assert Scorer.source_rank("webdl", ["bluray", "webdl"]) == 1
      assert Scorer.source_rank("hdtv", ["bluray", "webdl"]) == 2
      assert Scorer.source_rank(nil, ["bluray", "webdl"]) == 2
    end
  end

  describe "verdict/2" do
    defp rel(attrs),
      do:
        struct(
          Release,
          Map.merge(
            %{
              title: "X",
              resolution: "1080p",
              source: "bluray",
              size: 5_000_000_000,
              language: "en",
              group: "G",
              protocol: :torrent,
              season: nil,
              episodes: nil
            },
            Map.new(attrs)
          )
        )

    test "accepts an in-band, allowed release" do
      assert Scorer.verdict(rel([]),
               preferred_resolutions: ["1080p"],
               min_size: 1,
               max_size: 10_000_000_000
             ) == :ok
    end

    test "flags an out-of-band release" do
      assert Scorer.verdict(rel(size: 99_000_000_000), max_size: 10_000_000_000) ==
               {:rejected, :out_of_band}
    end

    test "scales the band per episode a release names (k×, like select_for)" do
      assert Scorer.verdict(rel(size: 8_000_000_000, season: 1, episodes: [1, 2]),
               max_size: 5_000_000_000
             ) == :ok

      assert Scorer.verdict(rel(size: 12_000_000_000, season: 1, episodes: [1, 2]),
               max_size: 5_000_000_000
             ) == {:rejected, :out_of_band}
    end

    test "a whole-season pack is banded against pack_episode_count, not one episode's size" do
      pack = rel(size: 30_000_000_000, season: 1, episodes: nil)

      assert Scorer.verdict(pack, max_size: 5_000_000_000) == {:rejected, :out_of_band}
      assert Scorer.verdict(pack, max_size: 5_000_000_000, pack_episode_count: 10) == :ok
    end

    test "flags a blocklisted title" do
      assert Scorer.verdict(rel(title: "Bad.Release"), release_blocklist: ["bad.release"]) ==
               {:rejected, :blocklisted}
    end

    test "flags a disallowed resolution" do
      assert Scorer.verdict(rel(resolution: "480p"), preferred_resolutions: ["1080p"]) ==
               {:rejected, :wrong_resolution}
    end

    test "rank_key orders a preferred resolution ahead of a worse one" do
      a = Scorer.rank_key(rel(resolution: "1080p"), preferred_resolutions: ["1080p", "720p"])
      b = Scorer.rank_key(rel(resolution: "720p"), preferred_resolutions: ["1080p", "720p"])
      assert a < b
    end
  end
end
