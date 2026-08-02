defmodule Cinder.Catalog.UpgradeHunterTest do
  # async: false — the sweep runs in its own process against the test-owned (shared Sandbox)
  # connection, it stamps process-global :persistent_term, and the enable/cutoff toggles are
  # Application env.
  use Cinder.DataCase, async: false

  import Mox

  @moduletag :capture_log

  alias Cinder.Catalog.{Episode, Movie, UpgradeHunter}

  import Cinder.CatalogFixtures

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    on_exit(fn -> :persistent_term.erase({UpgradeHunter, :last_run}) end)
    put_env(UpgradeHunter, enabled: true)
    start_supervised!({UpgradeHunter, interval: 60_000})
    :ok
  end

  defp put_env(key, value) do
    saved = Application.get_env(:cinder, key)
    Application.put_env(:cinder, key, value)

    on_exit(fn ->
      if is_nil(saved),
        do: Application.delete_env(:cinder, key),
        else: Application.put_env(:cinder, key, saved)
    end)
  end

  defp poll, do: assert(:ok = UpgradeHunter.poll())

  # A 720p movie in the library: the thing an upgrade hunt exists for.
  defp library_movie(attrs \\ %{}) do
    movie_fixture(
      Enum.into(attrs, %{
        title: "Inception",
        imdb_id: "tt1375666",
        status: :available,
        file_path: "/lib/Inception/Inception.mkv",
        imported_resolution: "720p",
        imported_size: 4_000_000_000,
        imported_source: "WEBDL"
      })
    )
  end

  defp indexer_offers(title, results) do
    stub(Cinder.Acquisition.IndexerMock, :search, fn ^title -> {:ok, results} end)
  end

  defp release(title, extra \\ %{}) do
    Map.merge(
      %{title: title, size: 9_000_000_000, download_url: "magnet:?x", seeders: 40},
      extra
    )
  end

  # Every "nothing was grabbed" assertion has to go through this pair rather than leaving `add`
  # unstubbed (or stubbing it with `flunk`). The sweep wraps each unit in `isolate/2`, which
  # swallows ANY raise — so a test that relies on an unstubbed mock blowing up passes whether the
  # sweep declined the release or grabbed it and crashed. A succeeding stub that reports itself is
  # the only way to tell those apart.
  defp watch_grabs do
    test_pid = self()

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      send(test_pid, :grab_attempted)
      {:ok, "unexpected-#{System.unique_integer([:positive])}"}
    end)
  end

  defp refute_grabbed, do: refute_received(:grab_attempted)

  describe "movies" do
    test "grabs a better release and moves the movie to :upgrading, live file intact" do
      movie = library_movie()
      indexer_offers("tt1375666", [release("Inception.2010.1080p.BluRay.x264-GRP")])
      stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "upgrade-hash"} end)

      poll()

      assert %Movie{
               status: :upgrading,
               download_id: "upgrade-hash",
               file_path: "/lib/Inception/Inception.mkv"
             } = Repo.get!(Movie, movie.id)
    end

    test "leaves the movie alone when nothing on offer beats the file it has" do
      movie = library_movie()
      watch_grabs()
      # Same resolution, smaller — a sideways move at best.
      indexer_offers("tt1375666", [
        release("Inception.2010.720p.WEBDL-GRP", %{size: 2_000_000_000})
      ])

      poll()

      refute_grabbed()
      assert %Movie{status: :available, download_id: nil} = Repo.get!(Movie, movie.id)
    end

    # There is deliberately no resolution cutoff: better?/5 ranks language FIRST, so a file at the
    # top resolution with the wrong audio language is still upgradable and must still be searched.
    test "still searches a top-resolution movie whose language is wrong" do
      put_env(:movies_preferred_resolutions, ["1080p", "720p"])

      movie =
        library_movie(%{
          imported_resolution: "1080p",
          imported_language: "en",
          preferred_language: "french",
          original_language: "en"
        })

      indexer_offers("tt1375666", [release("Inception.2010.1080p.BluRay.FRENCH-GRP")])
      stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "lang-upgrade"} end)

      poll()

      assert %Movie{status: :upgrading} = Repo.get!(Movie, movie.id)
    end

    test "stamps every examined movie so the rotation advances" do
      movie = library_movie()
      indexer_offers("tt1375666", [release("Inception.2010.720p.WEBDL-GRP", %{size: 1})])

      assert Repo.get!(Movie, movie.id).upgrade_checked_at == nil

      poll()

      assert %DateTime{} = Repo.get!(Movie, movie.id).upgrade_checked_at
    end

    test "examines the least-recently-checked movies first, up to the batch size" do
      put_env(UpgradeHunter, enabled: true, batch: 1)

      old = library_movie(%{tmdb_id: 101, imdb_id: "tt0000101"})
      fresh = library_movie(%{tmdb_id: 102, imdb_id: "tt0000102"})

      # `fresh` was checked a moment ago; `old` never has been (nil sorts first).
      Repo.update_all(from(m in Movie, where: m.id == ^fresh.id),
        set: [upgrade_checked_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      before = Repo.get!(Movie, fresh.id).upgrade_checked_at
      indexer_offers("tt0000101", [])

      poll()

      assert %DateTime{} = Repo.get!(Movie, old.id).upgrade_checked_at
      assert Repo.get!(Movie, fresh.id).upgrade_checked_at == before
    end

    test "ignores a movie that is not :available or has no file" do
      requested = movie_fixture(%{tmdb_id: 201, status: :requested})
      downloading = movie_fixture(%{tmdb_id: 202, status: :downloading, download_id: "x"})

      watch_grabs()

      # No indexer stub: neither may be searched.
      poll()

      refute_grabbed()

      assert Repo.get!(Movie, requested.id).status == :requested
      assert Repo.get!(Movie, downloading.id).status == :downloading
    end

    test "an indexer failure leaves the movie alone but still counts as checked" do
      movie = library_movie()
      watch_grabs()
      stub(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:error, :timeout} end)

      poll()

      refute_grabbed()

      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      assert %DateTime{} = Repo.get!(Movie, movie.id).upgrade_checked_at
    end

    test "does nothing at all when disabled" do
      put_env(UpgradeHunter, enabled: false)
      movie = library_movie()
      watch_grabs()

      # No indexer stub: a disabled hunter must not search.
      poll()

      refute_grabbed()

      assert Repo.get!(Movie, movie.id).upgrade_checked_at == nil
    end
  end

  describe "episodes" do
    setup do
      series = series_fixture(%{tvdb_id: 4242, title: "Show", monitor_strategy: :all})
      season = season_fixture(series)

      episode =
        episode_fixture(season, %{
          episode_number: 1,
          file_path: "/lib/Show/S01E01.mkv",
          imported_resolution: "720p",
          imported_size: 1_000_000_000
        })

      %{series: series, season: season, episode: episode}
    end

    test "grabs a better release for an imported episode", ctx do
      stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 4242, "Show", 1 ->
        {:ok, [release("Show.S01E01.1080p.BluRay-GRP", %{size: 4_000_000_000})]}
      end)

      stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "tv-upgrade"} end)

      poll()

      episode = Repo.get!(Episode, ctx.episode.id)
      assert episode.grab_id
      # The live file stays put until the replacement imports and swaps.
      assert episode.file_path == "/lib/Show/S01E01.mkv"
    end

    test "leaves an episode alone when the offer is not better", ctx do
      watch_grabs()

      stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 4242, "Show", 1 ->
        {:ok, [release("Show.S01E01.720p.WEBDL-GRP", %{size: 500_000_000})]}
      end)

      poll()

      refute_grabbed()
      assert Repo.get!(Episode, ctx.episode.id).grab_id == nil
    end

    test "ignores an episode with no file or one already grabbed", ctx do
      wanted = episode_fixture(ctx.season, %{episode_number: 2})

      # Only episode 1 has a file, so only its season is searched; episode 2 must not appear in
      # the wanted numbers (this stub asserts the exact set the hunter asked for).
      stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 4242, "Show", 1 -> {:ok, []} end)

      poll()

      assert Repo.get!(Episode, wanted.id).upgrade_checked_at == nil
      assert %DateTime{} = Repo.get!(Episode, ctx.episode.id).upgrade_checked_at
    end

    # A pack that ties on resolution, source and language is not an upgrade for any of the
    # episodes it covers, however big the pack is: `candidate?/4` doesn't weigh size (#278).
    test "a same-resolution season pack is not an upgrade for its episodes", ctx do
      imported =
        for n <- 2..10 do
          episode_fixture(ctx.season, %{
            episode_number: n,
            file_path: "/lib/Show/S01E#{n}.mkv",
            imported_resolution: "720p",
            imported_size: 1_000_000_000
          })
        end

      stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 4242, "Show", 1 ->
        # 10 GB across the 10-episode season = 1 GB/episode: exactly what is already imported,
        # so this is a sideways move, not an upgrade.
        {:ok, [release("Show.S01.720p.WEBDL-GRP", %{size: 10_000_000_000})]}
      end)

      watch_grabs()

      poll()

      refute_grabbed()

      for ep <- [ctx.episode | imported] do
        assert Repo.get!(Episode, ep.id).grab_id == nil
      end
    end

    test "a genuinely better season pack is still grabbed, linking every episode it covers",
         ctx do
      # batch: 1 so the season arrives as a slice and hunt_season/1's widening is what puts the
      # other nine episodes in the ask — with the default batch of 10 the season fits in one batch
      # and this would pass with the widening reverted.
      put_env(UpgradeHunter, enabled: true, batch: 1)

      imported =
        for n <- 2..10 do
          episode_fixture(ctx.season, %{
            episode_number: n,
            file_path: "/lib/Show/S01E#{n}.mkv",
            imported_resolution: "720p",
            imported_size: 1_000_000_000
          })
        end

      stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 4242, "Show", 1 ->
        {:ok, [release("Show.S01.1080p.BluRay-GRP", %{size: 30_000_000_000})]}
      end)

      stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "pack-upgrade"} end)

      poll()

      # Every episode the pack covers is linked, so no delivered file arrives unclaimed at import
      # and the grab can close without an operator residual decision (#247).
      grab_ids = for ep <- [ctx.episode | imported], do: Repo.get!(Episode, ep.id).grab_id
      assert Enum.all?(grab_ids, &is_integer/1)
      assert Enum.uniq(grab_ids) == [hd(grab_ids)]
    end

    # A pack that improves only part of the season is left alone: #250 removed the data-loss reason
    # (the import now declines per episode), but taking a whole pack for the subset it improves is
    # its own trade. See the guard's comment and issue #257.
    test "skips a pack that does not improve every episode it covers", ctx do
      # E01 is 720p (upgradable); the rest of the season is already 1080p at a bigger size.
      kept =
        for n <- 2..10 do
          episode_fixture(ctx.season, %{
            episode_number: n,
            file_path: "/lib/Show/S01E#{n}.mkv",
            imported_resolution: "1080p",
            imported_source: "BLURAY",
            imported_size: 4_000_000_000
          })
        end

      stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 4242, "Show", 1 ->
        # 1080p WEB-DL at 2 GB/episode: better than E01's 720p, worse than the other nine.
        {:ok, [release("Show.S01.1080p.WEBDL-GRP", %{size: 20_000_000_000})]}
      end)

      watch_grabs()

      poll()

      refute_grabbed()

      for ep <- [ctx.episode | kept] do
        assert Repo.get!(Episode, ep.id).grab_id == nil
      end
    end

    # Same hold, other cause: a pack for a season we only partly hold delivers files for the
    # episodes we don't (missing, unmonitored, already grabbing) and nothing can claim them (#247).
    test "skips a better pack when part of the season is not ours to claim", ctx do
      for n <- 2..9 do
        episode_fixture(ctx.season, %{
          episode_number: n,
          file_path: "/lib/Show/S01E#{n}.mkv",
          imported_resolution: "720p",
          imported_size: 1_000_000_000
        })
      end

      # E10 exists and airs in the pack, but has no file of ours to link it to.
      episode_fixture(ctx.season, %{episode_number: 10})

      stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 4242, "Show", 1 ->
        # A real upgrade for all nine we hold — still declined: its tenth file has no claimant.
        {:ok, [release("Show.S01.1080p.BluRay-GRP", %{size: 30_000_000_000})]}
      end)

      watch_grabs()

      poll()

      refute_grabbed()
      assert Repo.get!(Episode, ctx.episode.id).grab_id == nil
    end

    # Declining the unclaimable pack must not take the season's other offers down with it: the
    # greedy cover hands the whole wanted set to the pack and never scores the singles behind it,
    # so the claim rule has to filter candidates BEFORE selection (`full_claim_only`). Judging the
    # winner afterwards left the season permanently unupgradable — same pool, same decline, every
    # pass.
    test "still takes the per-episode release the unclaimable pack was hiding", ctx do
      for n <- 2..9 do
        episode_fixture(ctx.season, %{
          episode_number: n,
          file_path: "/lib/Show/S01E#{n}.mkv",
          imported_resolution: "720p",
          imported_size: 1_000_000_000
        })
      end

      # E10 airs in the pack but we hold no file for it, so the pack is unclaimable.
      episode_fixture(ctx.season, %{episode_number: 10})

      stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 4242, "Show", 1 ->
        {:ok,
         [
           release("Show.S01.1080p.BluRay-GRP", %{size: 30_000_000_000}),
           release("Show.S01E01.1080p.BluRay-GRP", %{size: 4_000_000_000})
         ]}
      end)

      test_pid = self()

      stub(Cinder.Download.ClientMock, :add, fn rel, _opts ->
        send(test_pid, {:grabbed, rel.title})
        {:ok, "single-upgrade"}
      end)

      poll()

      assert_received {:grabbed, "Show.S01E01.1080p.BluRay-GRP"}
      assert Repo.get!(Episode, ctx.episode.id).grab_id
    end

    # Same rule one round later: the cover's second pick must not be handed a truncated assignment
    # either, or the release delivers a file for an episode the earlier pick already owns and it
    # arrives at import unclaimed.
    test "does not grab a release an earlier pick truncated", ctx do
      for n <- 2..3 do
        episode_fixture(ctx.season, %{
          episode_number: n,
          file_path: "/lib/Show/S01E#{n}.mkv",
          imported_resolution: "720p",
          imported_size: 1_000_000_000
        })
      end

      stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 4242, "Show", 1 ->
        {:ok,
         [
           release("Show.S01E01E02.1080p.BluRay-GRP", %{size: 8_000_000_000}),
           release("Show.S01E02E03.1080p.BluRay-GRP", %{size: 8_000_000_000})
         ]}
      end)

      test_pid = self()

      stub(Cinder.Download.ClientMock, :add, fn rel, _opts ->
        send(test_pid, {:grabbed, rel.title})
        {:ok, "pair-upgrade"}
      end)

      poll()

      assert_received {:grabbed, "Show.S01E01E02.1080p.BluRay-GRP"}
      refute_received {:grabbed, "Show.S01E02E03.1080p.BluRay-GRP"}

      # E03 keeps waiting rather than being served by a release that also delivers E02.
      [_e1, _e2, e3] = Repo.all(from e in Episode, order_by: e.episode_number)
      assert e3.grab_id == nil
    end

    # The batch is a slice of the library, not of a season, so the season arrives partial. Both
    # held episodes must still be asked about and linked, or the pack's file for the one left out
    # lands unclaimed at import as a residual hold (#247).
    test "widens a batch-sliced season back to every episode it holds", ctx do
      put_env(UpgradeHunter, enabled: true, batch: 1)

      second =
        episode_fixture(ctx.season, %{
          episode_number: 2,
          file_path: "/lib/Show/S01E02.mkv",
          imported_resolution: "720p",
          imported_size: 1_000_000_000
        })

      test_pid = self()

      stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 4242, "Show", 1 ->
        send(test_pid, :searched)
        {:ok, [release("Show.S01.1080p.BluRay-GRP", %{size: 8_000_000_000})]}
      end)

      stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "pack-upgrade"} end)

      poll()

      assert_received :searched
      assert Repo.get!(Episode, ctx.episode.id).grab_id
      assert Repo.get!(Episode, second.id).grab_id == Repo.get!(Episode, ctx.episode.id).grab_id
      assert %DateTime{} = Repo.get!(Episode, second.id).upgrade_checked_at
    end

    test "skips an anime-profile series", ctx do
      Repo.update_all(from(s in Cinder.Catalog.Series, where: s.id == ^ctx.series.id),
        set: [media_profile: :anime]
      )

      watch_grabs()

      # No indexer stub: the anime path is not reused here (see the module's Scope section).
      poll()

      refute_grabbed()
      assert Repo.get!(Episode, ctx.episode.id).grab_id == nil
    end
  end

  # #278 on the TV side: the pack's advertised size is the whole container, each episode's is one
  # file, so a pack out-weighs every file it itself delivered. Deliberately its own series and
  # season: the "episodes" describe seeds a 720p E01, and a genuine resolution winner anywhere in
  # the covered set would hide the size question entirely.
  describe "a pack whose only claim over its own output is size" do
    test "is not grabbed, whatever the season's real sizes are" do
      series = series_fixture(%{tvdb_id: 909, title: "Straddle", monitor_strategy: :all})
      season = season_fixture(series)

      # 9 GB of season already imported, split 6 + 1 + 2, every file tying the offer below on
      # resolution, source and language. The offer is the same 9 GB — bigger than any one file it
      # holds, and bigger than the 3 GB mean too. Nothing here is a quality win in either
      # direction, so nothing may be grabbed.
      episodes =
        for {number, size} <- [{1, 6_000_000_000}, {2, 1_000_000_000}, {3, 2_000_000_000}] do
          episode_fixture(season, %{
            episode_number: number,
            file_path: "/lib/Straddle/S01E0#{number}.mkv",
            imported_resolution: "1080p",
            imported_source: "webdl",
            imported_size: size
          })
        end

      stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 909, "Straddle", 1 ->
        {:ok, [release("Straddle.S01.1080p.WEBDL-GRP", %{size: 9_000_000_000})]}
      end)

      watch_grabs()

      poll()

      # Taking this would re-download 9 GB for an import that declines all three episodes, and
      # the next rotation would offer it again — unbounded, since a declined arbitration still
      # stages held files, so no blocklist entry and no search_attempts bump ever lands.
      refute_grabbed()

      for ep <- episodes, do: assert(Repo.get!(Episode, ep.id).grab_id == nil)
    end
  end
end
