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

    # Without per-episode size scaling, a season pack's whole size beats one imported file on
    # better?/5's size tiebreak, so EVERY same-resolution pack reads as an upgrade — it downloads,
    # the import declines it per-file, nothing is blocklisted, and it re-downloads every sweep.
    #
    # The season needs REAL length: with a single episode the divisor is 1, `per_episode/2` is a
    # no-op, and the test would pass with the fix reverted.
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

    # The divisor has to be what the RELEASE carries, not what the sweep asked about. With a season
    # longer than the batch those differ: Scorer.coverage/2 intersects the pack with the 10 episodes
    # this pass examined, so dividing by that inflates the pack's per-episode size and it reads as
    # an upgrade — grabbed, declined per-file at import, re-grabbed every sweep forever.
    test "a season longer than the batch still divides by the whole season", ctx do
      put_env(UpgradeHunter, enabled: true, batch: 10)

      for n <- 2..22 do
        episode_fixture(ctx.season, %{
          episode_number: n,
          file_path: "/lib/Show/S01E#{n}.mkv",
          imported_resolution: "720p",
          imported_size: 1_000_000_000
        })
      end

      stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 4242, "Show", 1 ->
        # 22 GB over the real 22-episode season = 1 GB/episode: a tie, not an upgrade. Divided by
        # the 10 the batch happened to ask about it would look like 2.2 GB/episode.
        {:ok, [release("Show.S01.720p.WEBDL-GRP", %{size: 22_000_000_000})]}
      end)

      watch_grabs()

      poll()

      refute_grabbed()
    end

    test "a genuinely better season pack is still grabbed", ctx do
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

      assert Repo.get!(Episode, ctx.episode.id).grab_id
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
end
