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

    test "all-too-large: every release exceeds max_size -> :no_match" do
      releases = [
        release(resolution: "1080p", group: "A", size: 30 * @gb),
        release(resolution: "720p", group: "B", size: 25 * @gb)
      ]

      assert :no_match = Scorer.select(releases, max_size: 20 * @gb)
    end

    test "blocklisted group is excluded even when it would otherwise win" do
      releases = [
        release(resolution: "1080p", group: "EVIL", size: 10 * @gb),
        release(resolution: "1080p", group: "GOOD", size: 8 * @gb)
      ]

      # EVIL out-ranks GOOD on size; the blocklist must drop it and pick GOOD.
      assert {:ok, %Release{group: "GOOD"}} =
               Scorer.select(releases, blocklist: ["evil"], max_size: 20 * @gb)

      # Negative control: with no blocklist, EVIL wins — proving the filter is load-bearing.
      assert {:ok, %Release{group: "EVIL"}} = Scorer.select(releases, max_size: 20 * @gb)
    end

    test "prefers 1080p over an equally-sized 720p" do
      releases = [
        release(resolution: "720p", group: "A", size: 8 * @gb),
        release(resolution: "1080p", group: "B", size: 8 * @gb)
      ]

      assert {:ok, %Release{resolution: "1080p"}} = Scorer.select(releases)
    end

    test "unlisted/nil resolutions rank last; size breaks the tie without crashing" do
      releases = [
        release(resolution: "2160p", group: "A", size: 30 * @gb),
        release(resolution: nil, group: "B", size: 5 * @gb)
      ]

      assert {:ok, %Release{group: "A", resolution: "2160p"}} = Scorer.select(releases)
    end

    test "empty input -> :no_match" do
      assert :no_match = Scorer.select([])
    end
  end

  describe "select_for/4 (TV)" do
    test "a season pack covering the whole wanted set is chosen" do
      releases = [release(season: 1, episodes: nil, resolution: "1080p", size: 6 * @gb)]

      assert {:ok, [%Release{episodes: nil, resolution: "1080p"}]} =
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
      assert chosen |> Enum.map(& &1.episodes) |> Enum.sort() == [[1], [2]]
    end

    test "a range and a single greedily cover a multi-episode want" do
      releases = [
        release(season: 1, episodes: [1, 2, 3], resolution: "1080p", size: 6 * @gb),
        release(season: 1, episodes: [4], resolution: "1080p", size: 2 * @gb)
      ]

      assert {:ok, chosen} = Scorer.select_for(releases, 1, [1, 2, 3, 4])
      assert Enum.map(chosen, & &1.episodes) == [[1, 2, 3], [4]]
    end

    test "a blocklisted group is dropped even if it would cover more" do
      releases = [
        release(season: 1, episodes: nil, group: "EVIL", resolution: "1080p", size: 6 * @gb),
        release(season: 1, episodes: [1], group: "GOOD", resolution: "1080p", size: 2 * @gb)
      ]

      assert {:ok, [%Release{group: "GOOD", episodes: [1]}]} =
               Scorer.select_for(releases, 1, [1], blocklist: ["evil"])
    end

    test "the size band scales per episode (a pack passes where a single would not)" do
      pack = release(season: 1, episodes: nil, resolution: "1080p", size: 9 * @gb)
      single = release(season: 1, episodes: [1], resolution: "1080p", size: 9 * @gb)

      # per-episode max 5GB: pack covers 3 (budget 15GB) -> ok; single covers 1 (budget 5GB) -> too big.
      assert {:ok, [%Release{episodes: nil}]} =
               Scorer.select_for([pack], 1, [1, 2, 3], max_size: 5 * @gb)

      assert :no_match = Scorer.select_for([single], 1, [1], max_size: 5 * @gb)
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

      assert {:ok, [%Release{episodes: [1]}]} = Scorer.select_for(releases, 1, [1, 2, 3])
    end

    test "no releases -> :no_match" do
      assert :no_match = Scorer.select_for([], 1, [1])
    end

    test "with no size band, any release is acceptable (the band is poller-supplied)" do
      releases = [release(season: 1, episodes: [1], resolution: "1080p", size: 200 * @gb)]

      assert {:ok, [%Release{episodes: [1]}]} = Scorer.select_for(releases, 1, [1])
    end
  end
end
