defmodule Cinder.Download.IntentIndexerSourceTest do
  @moduledoc """
  A download intent stores the indexer source, id and credentials version of its release
  (#1645). An intent that stored no source is Prowlarr's. Two copies of one link from two sources,
  from two indexers of one source, or from one native indexer under two credentials versions are
  different releases to an intent. The block row Cinder writes when the client refuses a TV
  intent the search picked records the intent's indexer id with its source, and neither when the
  intent stored no id.
  """
  use Cinder.DataCase, async: false

  import Ecto.Query
  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Acquisition.Release
  alias Cinder.Catalog.BlockedRelease
  alias Cinder.Download
  alias Cinder.Download.{ClientMock, Intent}
  alias Cinder.Repo

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  @title "Show.S01E01.1080p.WEB-DL-GRP"
  @link "magnet:?xt=urn:btih:one-link"

  describe "the stored release" do
    test "a movie grab stores the release's indexer source, id and credentials version" do
      movie = movie_fixture(%{status: :searching})
      expect(ClientMock, :find_by_operation_key, fn _key -> {:error, :timeout} end)

      release =
        Release.new(%{
          title: "Movie.2010.1080p-GRP",
          download_url: @link,
          indexer_id: 4,
          indexer_source: "native",
          credentials_version: 2
        })

      assert {:error, :timeout} = Download.grab_movie(movie, release)

      assert %{
               "indexer_source" => "native",
               "indexer_id" => 4,
               "credentials_version" => 2
             } = movie_intent(movie).release
    end

    test "a release with no credentials version or no source stores no such key" do
      for {release, absent} <- [
            {Release.new(%{title: "Movie.2010.1080p-GRP", download_url: @link, indexer_id: 4}),
             "credentials_version"},
            {%Release{title: "Movie.2010.1080p-GRP", download_url: @link, protocol: :torrent},
             "indexer_source"}
          ] do
        movie = movie_fixture(%{status: :searching})
        assert {:ok, %Intent{release: stored}} = reserve(:movie, movie.id, [], release)
        refute Map.has_key?(stored, absent)
      end
    end
  end

  describe "a grab against a stored movie intent" do
    setup do
      %{movie: movie_fixture(%{status: :searching})}
    end

    # Each row: the release the intent stored, the release the grab offers, and whether the grab
    # adopts the intent (true) or answers busy (false).
    for {name, stored, offered, adopts} <- [
          {"another source's copy is busy", {"prowlarr", 4, nil}, {"native", 4, nil}, false},
          {"the same source and id adopt", {"prowlarr", 4, nil}, {"prowlarr", 4, nil}, true},
          {"another indexer's copy is busy", {"prowlarr", 4, nil}, {"prowlarr", 5, nil}, false},
          {"a copy with no id is busy for an intent with one", {"prowlarr", 4, nil},
           {"prowlarr", nil, nil}, false},
          {"an intent with no id is busy for a copy with one", {"prowlarr", nil, nil},
           {"prowlarr", 4, nil}, false},
          {"an intent with no source adopts a Prowlarr copy", {nil, 4, nil}, {"prowlarr", 4, nil},
           true},
          {"an intent with no source is busy for a native copy", {nil, 4, nil},
           {"native", 4, nil}, false},
          {"a copy with no source adopts an intent with no source", {nil, nil, nil},
           {nil, nil, nil}, true},
          {"a native copy of another credentials version is busy", {"native", 4, 1},
           {"native", 4, 2}, false},
          {"a native copy of the same credentials version adopts", {"native", 4, 2},
           {"native", 4, 2}, true},
          {"a Prowlarr copy of another credentials version adopts", {"prowlarr", 4, 1},
           {"prowlarr", 4, 2}, true}
        ] do
      @stored stored
      @offered offered

      @outcome (cond do
                  not adopts -> :busy
                  elem(stored, 0) == "native" -> :adopts_unmapped
                  true -> :adopts
                end)

      test name, %{movie: movie} do
        {:ok, _intent} = reserve(:movie, movie.id, [], release(@stored))
        assert_grab(movie, release(@offered), @outcome)
      end
    end
  end

  describe "a grab against a stored episode intent" do
    setup do
      series = series_fixture(%{monitor_strategy: :all})
      %{episode: series |> season_fixture() |> episode_fixture()}
    end

    test "another source's copy is busy", %{episode: episode} do
      {:ok, _intent} = reserve(:episode, episode.id, [episode.id], release({"prowlarr", 4, nil}))

      assert {:error, :download_intent_busy} =
               Download.grab_episodes(release({"native", 4, nil}), [episode.id])
    end

    test "the same source and id adopt", %{episode: episode} do
      {:ok, _intent} = reserve(:episode, episode.id, [episode.id], release({"prowlarr", 4, nil}))
      expect_add("hash-adopted")

      assert {:ok, _grab} = Download.grab_episodes(release({"prowlarr", 4, nil}), [episode.id])
    end
  end

  describe "a refused episode intent" do
    setup do
      series = series_fixture(%{monitor_strategy: :all})
      %{series: series, episode: series |> season_fixture() |> episode_fixture()}
    end

    for {name, stored, row} <- [
          {"with an id and no source writes a row with the Prowlarr source and its id",
           {nil, 1, nil}, {"prowlarr", 1}},
          {"with the Prowlarr source writes a row with that source and its id",
           {"prowlarr", 1, nil}, {"prowlarr", 1}},
          {"with no id writes a row with no source and no id", {nil, nil, nil}, {nil, nil}},
          {"with a source and no id writes a row with no source and no id",
           {"prowlarr", nil, nil}, {nil, nil}}
        ] do
      @stored stored
      @row row

      test name, %{series: series, episode: episode} do
        {:ok, intent} = reserve(:episode, episode.id, [episode.id], release(@stored))
        expect(ClientMock, :find_by_operation_key, fn _key -> :not_found end)
        expect(ClientMock, :add, fn _release, _opts -> {:error, :bad_torrent} end)

        assert {:error, :bad_torrent} = Download.reconcile_intent(intent)

        {source, id} = @row
        assert blocked(series.id) == [{@title, "bad_torrent", source, id}]
      end
    end

    # No fetch source maps "native" before #1651 (#1650), so the client's add/2 never gets the
    # release, cannot refuse it, and no row is written: the intent retries.
    test "with a native source never reaches the client's add/2 and writes no row", %{
      series: series,
      episode: episode
    } do
      {:ok, intent} = reserve(:episode, episode.id, [episode.id], release({"native", 1, nil}))
      test_pid = self()
      stub(ClientMock, :find_by_operation_key, fn _key -> :not_found end)

      stub(ClientMock, :add, fn _release, _opts ->
        send(test_pid, :added)
        {:error, :bad_torrent}
      end)

      assert {:error, :unknown_indexer_source} = Download.reconcile_intent(intent)
      refute_received :added
      assert blocked(series.id) == []
      assert %Intent{status: :reserved, attempt_count: 1} = Repo.get(Intent, intent.id)
    end
  end

  defp release({source, id, credentials_version}) do
    %Release{
      title: @title,
      download_url: @link,
      protocol: :torrent,
      indexer_source: source,
      indexer_id: id,
      credentials_version: credentials_version
    }
  end

  defp reserve(kind, target_id, episode_ids, release) do
    Download.reserve_intent(%{
      kind: kind,
      target_id: target_id,
      episode_ids: episode_ids,
      protocol: :torrent,
      release: release
    })
  end

  defp expect_add(remote_id) do
    expect(ClientMock, :find_by_operation_key, fn _key -> :not_found end)
    expect(ClientMock, :add, fn _release, _opts -> {:ok, remote_id} end)
  end

  defp assert_grab(movie, offered, :busy) do
    assert {:error, :download_intent_busy} = Download.grab_movie(movie, offered)
    assert %Intent{status: :reserved, attempt_count: 0} = movie_intent(movie)
  end

  # No fetch source maps "native" before #1651 (#1650): the grab adopts the intent, whose
  # submission then retries with no add/2 call.
  defp assert_grab(movie, offered, :adopts_unmapped) do
    assert {:error, :unknown_indexer_source} = Download.grab_movie(movie, offered)
    assert %Intent{status: :reserved, attempt_count: 1} = movie_intent(movie)
  end

  defp assert_grab(movie, offered, :adopts) do
    expect_add("hash-adopted")
    assert {:ok, %{download_id: "hash-adopted"}} = Download.grab_movie(movie, offered)
  end

  defp movie_intent(movie), do: Repo.get_by!(Intent, kind: :movie, target_id: movie.id)

  defp blocked(series_id),
    do:
      Repo.all(
        from b in BlockedRelease,
          where: b.series_id == ^series_id,
          order_by: b.id,
          select: {b.release_title, b.reason, b.indexer_source, b.indexer_id}
      )
end
