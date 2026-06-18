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
end
