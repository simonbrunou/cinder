defmodule Cinder.Download.ReleasePolicyCleanupTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, Episode, Grab, Movie}
  alias Cinder.Download.Intent
  alias Cinder.Library.ImportStage
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  setup :set_mox_global
  setup :verify_on_exit!

  test "rejects a downloaded movie atomically without consuming retry budgets" do
    movie = policy_movie(:downloaded, "hash-rejected-movie")
    expect_cleanup_failure(movie.download_id)

    assert {:ok, requested} = Catalog.reject_movie_release(movie, mismatch_evidence())

    assert %Movie{
             status: :requested,
             download_id: nil,
             download_protocol: nil,
             release_title: nil,
             file_path: nil,
             release_policy_snapshot: nil,
             search_attempts: 4,
             import_attempts: 3
           } = requested

    assert Catalog.blocked_release_titles(requested) == [movie.release_title]
    assert cleanup_pending_for?(movie.download_id)
    refute Repo.exists?(ImportStage)
  end

  test "rejects an upgrade while preserving the live file and imported quality" do
    movie = policy_movie(:upgrading, "hash-rejected-upgrade")
    expect_cleanup_failure(movie.download_id)

    assert {:ok, available} = Catalog.reject_movie_release(movie, mismatch_evidence())

    assert %Movie{
             status: :available,
             download_id: nil,
             download_protocol: nil,
             release_title: nil,
             release_policy_snapshot: nil,
             file_path: "/library/Anime Movie.mkv",
             imported_resolution: "720p",
             imported_size: 1_234,
             imported_audio_languages: ["ja"],
             search_attempts: 4,
             import_attempts: 3
           } = available

    assert Catalog.blocked_release_titles(available) == [movie.release_title]
    assert cleanup_pending_for?(movie.download_id)
  end

  test "stale movie status, release title, or policy snapshot rolls back every rejection write" do
    mutations = [
      status: [status: :requested],
      release_title: [release_title: "Changed.Release"],
      policy_snapshot: [release_policy_snapshot: policy_snapshot("Changed.Release")],
      version: [updated_at: DateTime.add(DateTime.utc_now(:second), 60)]
    ]

    for {case_name, updates} <- mutations do
      movie = policy_movie(:downloaded, "hash-stale-#{case_name}")
      Repo.update_all(from(m in Movie, where: m.id == ^movie.id), set: updates)

      assert {:error, :stale_release} =
               Catalog.reject_movie_release(movie, mismatch_evidence())

      assert Repo.aggregate(BlockedRelease, :count, :id) == 0
      refute cleanup_pending_for?(movie.download_id)
    end
  end

  test "a same-second movie update invalidates the rejection claim" do
    movie = policy_movie(:downloaded, "hash-same-second-movie")

    Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
      set: [download_progress: 0.5, updated_at: movie.updated_at]
    )

    changed = Repo.get!(Movie, movie.id)
    assert changed.updated_at == movie.updated_at
    assert changed.row_version == movie.row_version + 1
    stub_cleanup_failure()

    assert {:error, :stale_release} = Catalog.reject_movie_release(movie, mismatch_evidence())
    assert Repo.get!(Movie, movie.id).download_progress == 0.5
    assert Repo.aggregate(BlockedRelease, :count, :id) == 0
    refute cleanup_pending_for?(movie.download_id)
  end

  test "row versions advance for every movie and grab update without changing Standard behavior" do
    movie = movie_fixture(%{media_profile: :standard}) |> Repo.reload!()
    series = series_fixture(%{media_profile: :standard, monitor_strategy: :all})
    episode = episode_fixture(season_fixture(series))
    {:ok, grab} = Catalog.create_grab("hash-standard-token", :torrent, [episode.id])
    grab = Repo.reload!(grab)

    assert is_integer(Map.get(movie, :row_version))
    assert is_integer(Map.get(grab, :row_version))

    Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
      set: [download_progress: 0.25, updated_at: movie.updated_at]
    )

    Repo.update_all(from(g in Grab, where: g.id == ^grab.id),
      set: [download_progress: 0.25, updated_at: grab.updated_at]
    )

    updated_movie = Repo.get!(Movie, movie.id)
    updated_grab = Repo.get!(Grab, grab.id)

    assert updated_movie.row_version == movie.row_version + 1
    assert updated_grab.row_version == grab.row_version + 1
    assert updated_movie.updated_at == movie.updated_at
    assert updated_grab.updated_at == grab.updated_at
    assert updated_movie.media_profile == :standard
    assert Repo.reload!(episode).grab_id == grab.id
  end

  test "rejects exactly one resolved grab without touching counters or sibling ownership" do
    {series, _season, [first, second, unrelated]} = episode_tree()
    grab = policy_grab([first, second], "hash-rejected-grab", "[Group] Show S01E01-E02")
    {:ok, other_grab} = Catalog.create_grab("hash-other-grab", :torrent, [unrelated.id])
    expect_cleanup_failure(grab.download_id)

    assert {:ok, deleted} = Catalog.reject_grab_release(grab, mismatch_evidence())

    assert deleted.id == grab.id
    refute Repo.get(Grab, grab.id)
    assert Repo.reload!(first).grab_id == nil
    assert Repo.reload!(second).grab_id == nil
    assert Repo.reload!(unrelated).grab_id == other_grab.id
    assert Repo.reload!(first).search_attempts == first.search_attempts
    assert Repo.reload!(second).search_attempts == second.search_attempts
    assert Catalog.blocked_release_titles_for_series(series.id) == [grab.release_title]
    assert cleanup_pending_for?(grab.download_id)
    refute Repo.exists?(ImportStage)
  end

  test "deleted grab rolls back its blocklist and cleanup fence" do
    {_series, _season, [episode | _]} = episode_tree()
    grab = policy_grab([episode], "hash-deleted-grab", "[Group] Show S01E01")
    Repo.delete!(Repo.get!(Grab, grab.id))

    assert {:error, :stale_release} = Catalog.reject_grab_release(grab, mismatch_evidence())
    assert Repo.aggregate(BlockedRelease, :count, :id) == 0
    refute cleanup_pending_for?(grab.download_id)
  end

  test "resolved preloaded ownership overrides the grab's original reservation ids" do
    {series, _season, [original, remapped, _unrelated]} = episode_tree()
    {:ok, other_grab} = Catalog.create_grab("hash-original-owner", :torrent, [original.id])
    grab = policy_grab([remapped], "hash-remapped-grab", "[Group] Show Remapped")

    mapping_snapshot =
      Map.put(grab.mapping_snapshot, "reserved_episode_ids", [original.id])

    Repo.update_all(from(g in Grab, where: g.id == ^grab.id),
      set: [mapping_snapshot: mapping_snapshot]
    )

    grab = Repo.get!(Grab, grab.id) |> Repo.preload(:episodes)
    expect_cleanup_failure(grab.download_id)

    assert {:ok, _deleted} = Catalog.reject_grab_release(grab, mismatch_evidence())
    assert Repo.reload!(original).grab_id == other_grab.id
    assert Repo.reload!(remapped).grab_id == nil
    assert Repo.reload!(remapped).search_attempts == remapped.search_attempts
    assert Catalog.blocked_release_titles_for_series(series.id) == [grab.release_title]
    assert cleanup_pending_for?(grab.download_id)
  end

  test "changed grab ownership rolls back its blocklist, cleanup fence, and delete" do
    {_series, _season, [first, second, unrelated]} = episode_tree()
    grab = policy_grab([first, second], "hash-stale-owner", "[Group] Show S01E01-E02")
    {:ok, other_grab} = Catalog.create_grab("hash-new-owner", :torrent, [unrelated.id])

    Repo.update_all(from(e in Episode, where: e.id == ^second.id),
      set: [grab_id: other_grab.id]
    )

    assert {:error, :stale_release} = Catalog.reject_grab_release(grab, mismatch_evidence())
    assert Repo.get!(Grab, grab.id)
    assert Repo.reload!(first).grab_id == grab.id
    assert Repo.reload!(second).grab_id == other_grab.id
    assert Repo.aggregate(BlockedRelease, :count, :id) == 0
    refute cleanup_pending_for?(grab.download_id)
  end

  test "same-second grab version changes roll back blocklist, cleanup fence, and delete" do
    {_series, _season, [episode | _]} = episode_tree()
    grab = policy_grab([episode], "hash-stale-version", "[Group] Show Version")

    Repo.update_all(from(g in Grab, where: g.id == ^grab.id),
      set: [download_progress: 0.5, updated_at: grab.updated_at]
    )

    changed = Repo.get!(Grab, grab.id)
    assert changed.updated_at == grab.updated_at
    assert changed.row_version == grab.row_version + 1
    stub_cleanup_failure()

    assert {:error, :stale_release} = Catalog.reject_grab_release(grab, mismatch_evidence())
    assert Repo.get!(Grab, grab.id).download_progress == 0.5
    assert Repo.reload!(episode).grab_id == grab.id
    assert Repo.aggregate(BlockedRelease, :count, :id) == 0
    refute cleanup_pending_for?(grab.download_id)
  end

  test "changed grab mapping status, title, or policy snapshot rolls back every rejection write" do
    mutations = [
      mapping_status: [mapping_status: :needs_mapping],
      release_title: [release_title: "Changed.Show.Release"],
      policy_snapshot: [release_policy_snapshot: policy_snapshot("Changed.Show.Release")]
    ]

    for {case_name, updates} <- mutations do
      {_series, _season, [episode | _]} = episode_tree()
      download_id = "hash-stale-grab-#{case_name}"
      grab = policy_grab([episode], download_id, "[Group] Show #{case_name}")
      Repo.update_all(from(g in Grab, where: g.id == ^grab.id), set: updates)

      assert {:error, :stale_release} = Catalog.reject_grab_release(grab, mismatch_evidence())
      persisted = Repo.get!(Grab, grab.id)

      for {field, value} <- updates do
        assert Map.fetch!(persisted, field) == value
      end

      assert Repo.reload!(episode).grab_id == grab.id
      assert Repo.aggregate(BlockedRelease, :count, :id) == 0
      refute cleanup_pending_for?(download_id)
    end
  end

  test "a grab linked across series rolls back blocklist, cleanup fence, and delete" do
    first_series = series_fixture(%{media_profile: :anime, monitor_strategy: :all})
    first = episode_fixture(season_fixture(first_series))
    second_series = series_fixture(%{media_profile: :anime, monitor_strategy: :all})
    second = episode_fixture(season_fixture(second_series))

    grab =
      policy_grab([first, second], "hash-cross-series", "[Group] Malformed Cross Series")

    stub_cleanup_failure()

    assert {:error, :stale_release} = Catalog.reject_grab_release(grab, mismatch_evidence())
    assert Repo.get!(Grab, grab.id)
    assert Repo.reload!(first).grab_id == grab.id
    assert Repo.reload!(second).grab_id == grab.id
    assert Repo.aggregate(BlockedRelease, :count, :id) == 0
    refute cleanup_pending_for?(grab.download_id)
  end

  test "a client removal failure leaves the committed rejection fence retryable" do
    movie = policy_movie(:downloaded, "hash-cleanup-retry")
    expect_cleanup_failure(movie.download_id)

    assert {:ok, %Movie{status: :requested}} =
             Catalog.reject_movie_release(movie, mismatch_evidence())

    assert %Intent{
             status: :cleanup_pending,
             remote_id: "hash-cleanup-retry",
             attempt_count: 1,
             next_attempt_at: %DateTime{},
             last_error: ":client_down"
           } = Repo.get_by!(Intent, remote_id: movie.download_id)
  end

  defp policy_movie(status, download_id) do
    file_path =
      if status == :upgrading,
        do: "/library/Anime Movie.mkv",
        else: "/downloads/Anime Movie.mkv"

    movie =
      movie_fixture(%{
        title: "Anime Movie",
        status: status,
        download_id: download_id,
        download_protocol: :torrent,
        release_title: "[Group] Anime Movie [1080p]",
        file_path: file_path,
        imported_resolution: "720p",
        imported_size: 1_234,
        imported_audio_languages: ["ja"]
      })

    {:ok, movie} =
      Catalog.transition(movie, %{
        status: status,
        release_policy_snapshot: policy_snapshot(movie.release_title),
        search_attempts: 4,
        import_attempts: 3
      })

    Repo.reload!(movie)
  end

  defp episode_tree do
    series = series_fixture(%{media_profile: :anime, monitor_strategy: :all})
    season = season_fixture(series)

    episodes =
      for number <- 1..3 do
        episode_fixture(season, %{episode_number: number, search_attempts: number})
      end

    {series, season, episodes}
  end

  defp policy_grab(episodes, download_id, release_title) do
    episode_ids = Enum.map(episodes, & &1.id)

    grab =
      Repo.insert!(%Grab{
        download_id: download_id,
        download_protocol: :torrent,
        release_title: release_title,
        content_path: "/downloads/#{release_title}.mkv",
        mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => episode_ids},
        release_policy_snapshot: policy_snapshot(release_title),
        mapping_status: :resolved
      })

    Repo.update_all(from(e in Episode, where: e.id in ^episode_ids), set: [grab_id: grab.id])
    Repo.preload(grab, :episodes)
  end

  defp policy_snapshot(release_title) do
    %{
      "version" => 1,
      "required_audio_languages" => ["ja", "fr"],
      "required_embedded_subtitle_languages" => [],
      "release_group" => "group",
      "release_title" => release_title
    }
  end

  defp mismatch_evidence,
    do: %{source: "Anime.Movie.mkv", missing_audio: ["fr"]}

  defp expect_cleanup_failure(remote_id) do
    expect(Cinder.Download.ClientMock, :remove, fn ^remote_id, delete_files: true ->
      {:error, :client_down}
    end)
  end

  defp stub_cleanup_failure do
    stub(Cinder.Download.ClientMock, :remove, fn _remote_id, delete_files: true ->
      {:error, :client_down}
    end)
  end

  defp cleanup_pending_for?(remote_id) do
    Repo.exists?(
      from i in Intent, where: i.remote_id == ^remote_id and i.status == :cleanup_pending
    )
  end
end
