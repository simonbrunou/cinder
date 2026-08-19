defmodule CinderWeb.SubtitleSyncLiveTest do
  use CinderWeb.ConnCase, async: false

  import Cinder.AccountsFixtures
  import Cinder.CatalogFixtures
  import Phoenix.LiveViewTest

  alias Cinder.Catalog.{Episode, Season, Series}
  alias Cinder.Repo
  alias Cinder.Subtitles
  alias Cinder.Subtitles.{Manifest, Sync}
  alias Cinder.Subtitles.Sync.Worker

  @moduletag :tmp_dir

  setup :register_and_log_in_admin

  setup %{tmp_dir: tmp} do
    keys = [
      :filesystem,
      :path_policy,
      :movies_library_path,
      :tv_library_path,
      :filesystem_barrier
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})
    movies = Path.join(tmp, "movies")
    tv = Path.join(tmp, "tv")
    File.mkdir_p!(movies)
    File.mkdir_p!(tv)
    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :movies_library_path, movies)
    Application.put_env(:cinder, :tv_library_path, tv)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    %{movies: movies}
  end

  test "library page mounts before sidecar discovery finishes", %{conn: conn, movies: movies} do
    {_movie, video, _sidecar, _item} = managed_movie!(movies, "Slow")
    managed_movie!(movies, "Uncached")

    worker =
      start_supervised!(
        {Worker,
         initial_scan: false,
         interval: :timer.hours(1),
         analyze: fn ^video -> [%{status: :aligned, label: "Slow"}] end}
      )

    assert :ok = Worker.enqueue_units([%{video_path: video, label: "Slow"}], worker)
    assert_eventually(fn -> MapSet.member?(Worker.managed_video_paths(), video) end)

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :find_files,
      contains: "/Slow",
      once: true
    })

    {:ok, view, _html} = live(conn, ~p"/subtitle-sync")
    assert has_element?(view, "#subtitle-sync-loading")
    assert_receive {:filesystem_barrier, pid, ref, :find_files, _path}

    send(pid, {ref, :continue})
    render_async(view)
    refute has_element?(view, "#subtitle-sync-loading")
    refute render(view) =~ "Uncached"
  end

  test "worker results received during discovery keep the newest state", %{
    conn: conn,
    movies: movies
  } do
    {movie, _video, _sidecar, item} = managed_movie!(movies, "Racing")
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :find_files,
      contains: "/Racing",
      once: true
    })

    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    assert_receive {:filesystem_barrier, pid, ref, :find_files, _path}

    result = fn method, offset ->
      %{
        id: item.id,
        video_path: item.video_path,
        status: :corrected,
        method: method,
        offset_ms: offset,
        rate: 1.0,
        reason: nil
      }
    end

    send(
      view.pid,
      {:subtitle_sync_status,
       status_with_results([result.("newest", 2_000), result.("older", 1_000)])}
    )

    send(pid, {ref, :continue})
    render_async(view)
    assert render(view) =~ "Aligned via newest: 2000 ms"
  end

  test "worker results discover sidecars added after mount", %{conn: conn, movies: movies} do
    video = Path.join(movies, "Added/Added.mkv")
    sidecar = Path.rootname(video) <> ".en.srt"
    content = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, String.duplicate("v", 131_072))

    movie =
      %{title: "Added", status: :available}
      |> movie_fixture()
      |> Ecto.Changeset.change(file_path: video)
      |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(view)
    refute has_element?(view, "[id^=subtitle-sync-item-]")

    File.write!(sidecar, content)
    {:ok, hash} = Subtitles.Moviehash.of_file(video)
    :ok = Manifest.put(video, hash, "en", "opensubtitles_hash", sidecar, digest(content))
    [item] = Sync.items({:movie, movie.id})

    result = %{
      id: item.id,
      video_path: video,
      status: :aligned,
      method: "audio",
      offset_ms: 0,
      rate: 1.0,
      reason: nil
    }

    send(view.pid, {:subtitle_sync_status, status_with_results([result])})
    render_async(view)
    assert has_element?(view, "#subtitle-sync-item-#{item.id}")
  end

  test "library results discover catalog videos added after mount", %{conn: conn, movies: movies} do
    {:ok, view, _html} = live(conn, ~p"/subtitle-sync")
    render_async(view)

    {movie, video, _sidecar, item} = managed_movie!(movies, "Imported")
    unit = Enum.find(Sync.units(:library), &(&1.video_path == video))
    assert MapSet.member?(unit.scopes, {:movie, movie.id})

    result = %{
      id: item.id,
      video_path: video,
      scopes: unit.scopes,
      status: :aligned,
      method: "audio",
      offset_ms: 0,
      rate: 1.0,
      reason: nil
    }

    send(view.pid, {:subtitle_sync_status, status_with_results([result])})
    render_async(view)
    assert has_element?(view, "#subtitle-sync-item-#{item.id}")
  end

  test "post-download results discover files added to an open movie scope", %{
    conn: conn,
    movies: movies
  } do
    movie = movie_fixture(%{title: "PostDownload", status: :available})
    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(view)
    refute has_element?(view, "[id^=subtitle-sync-item-]")

    video = Path.join(movies, "PostDownload/PostDownload.mkv")
    sidecar = Path.rootname(video) <> ".en.srt"
    content = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, String.duplicate("v", 131_072))
    File.write!(sidecar, content)

    movie |> Ecto.Changeset.change(file_path: video) |> Repo.update!()
    {:ok, hash} = Subtitles.Moviehash.of_file(video)
    :ok = Manifest.put(video, hash, "en", "opensubtitles_hash", sidecar, digest(content))
    [item] = Sync.items({:movie, movie.id})

    result = %{
      id: item.id,
      video_path: video,
      status: :aligned,
      method: "audio",
      offset_ms: 0,
      rate: 1.0,
      reason: nil
    }

    previous_status = Worker.status()
    on_exit(fn -> :persistent_term.put({Worker, :status}, previous_status) end)

    worker =
      start_supervised!(
        {Worker,
         name: :subtitle_sync_after_download_worker,
         initial_scan: false,
         interval: :timer.hours(1),
         analyze: fn ^video -> [result] end}
      )

    assert :ok = Worker.enqueue_after_download(video, worker)
    assert_eventually(fn -> has_element?(view, "#subtitle-sync-item-#{item.id}") end)
  end

  test "admin previews/applies/resets by server ID and raw client paths are rejected", %{
    conn: conn,
    movies: movies
  } do
    video = Path.join(movies, "Movie/Movie.mkv")
    sidecar = Path.rootname(video) <> ".en.srt"
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, String.duplicate("v", 131_072))
    File.write!(sidecar, "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n")
    {:ok, hash} = Subtitles.Moviehash.of_file(video)

    assert :ok =
             Manifest.put(
               video,
               hash,
               "en",
               "opensubtitles_hash",
               sidecar,
               digest(File.read!(sidecar))
             )

    movie =
      %{title: "Movie", status: :available}
      |> movie_fixture()
      |> Ecto.Changeset.change(file_path: video)
      |> Repo.update!()

    [item] = Sync.items({:movie, movie.id})
    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(view)
    assert has_element?(view, "#subtitle-sync-items")
    assert has_element?(view, "#subtitle-sync-item-#{item.id}")

    view |> element("#subtitle-sync-item-#{item.id} button", "Adjust") |> render_click()

    view
    |> form("#subtitle-sync-form", %{
      "adjustment" => %{"mode" => "direct", "delay_ms" => "1000", "rate" => "1.0"}
    })
    |> render_change()

    assert has_element?(view, "#subtitle-sync-preview", "1.000 s")

    view
    |> form("#subtitle-sync-form", %{
      "adjustment" => %{"mode" => "direct", "delay_ms" => "1000", "rate" => "1.0"}
    })
    |> render_submit()

    assert File.read!(sidecar) =~ "00:00:02,000"
    {:ok, reset_view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(reset_view)
    reset_view |> element("#reset-subtitle-#{item.id}") |> render_click()
    render_async(reset_view)
    assert File.read!(sidecar) =~ "00:00:01,000"

    render_click(view, "select", %{"id" => sidecar})
    refute render(view) =~ sidecar
  end

  test "apply requires a matching preview and unchanged sidecar bytes", %{
    conn: conn,
    movies: movies
  } do
    video = Path.join(movies, "Bound/Bound.mkv")
    sidecar = Path.rootname(video) <> ".en.srt"
    original = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, String.duplicate("v", 131_072))
    File.write!(sidecar, original)
    {:ok, hash} = Subtitles.Moviehash.of_file(video)

    assert :ok =
             Manifest.put(
               video,
               hash,
               "en",
               "opensubtitles_hash",
               sidecar,
               digest(original)
             )

    movie =
      %{title: "Bound", status: :available}
      |> movie_fixture()
      |> Ecto.Changeset.change(file_path: video)
      |> Repo.update!()

    [item] = Sync.items({:movie, movie.id})
    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(view)
    view |> element("#subtitle-sync-item-#{item.id} button", "Adjust") |> render_click()

    params = %{"adjustment" => %{"mode" => "direct", "delay_ms" => "1000", "rate" => "1.0"}}
    view |> form("#subtitle-sync-form", params) |> render_change()
    external = String.replace(original, "One", "External edit")
    File.write!(sidecar, external)
    view |> form("#subtitle-sync-form", params) |> render_submit()
    assert File.read!(sidecar) == external

    File.write!(sidecar, original)
    view |> form("#subtitle-sync-form", params) |> render_submit()
    assert File.read!(sidecar) == original

    view |> form("#subtitle-sync-form", params) |> render_change()

    changed_params = %{
      "adjustment" => %{"mode" => "direct", "delay_ms" => "2000", "rate" => "1.0"}
    }

    view |> form("#subtitle-sync-form", changed_params) |> render_submit()
    assert File.read!(sidecar) == original
  end

  test "worker status broadcasts refresh persisted sidecar results", %{conn: conn, movies: movies} do
    {movie, _video, _sidecar, item} = managed_movie!(movies, "Refresh")
    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(view)
    assert render(view) =~ "Not analyzed"

    assert {:ok, :corrected, _item} = Sync.manual(item, 1_000, 1.0)

    result = %{
      id: item.id,
      video_path: item.video_path,
      status: :corrected,
      method: "manual",
      offset_ms: 1_000,
      rate: 1.0,
      reason: nil
    }

    send(view.pid, {:subtitle_sync_status, status_with_results([result])})

    assert_eventually(fn -> render(view) =~ "Aligned via manual" end)
  end

  test "historic worker results are ignored until an identical analysis runs again", %{
    conn: conn,
    movies: movies
  } do
    {movie, _video, _sidecar, item} = managed_movie!(movies, "Historic")
    assert {:ok, :corrected, _item} = Sync.manual(item, 1_000, 1.0)

    result = %{
      id: item.id,
      video_path: item.video_path,
      status: :corrected,
      method: "manual",
      offset_ms: 1_000,
      rate: 1.0,
      reason: nil
    }

    previous_status = Worker.status()
    historic_status = status_with_results([result], previous_status)
    :persistent_term.put({Worker, :status}, historic_status)
    on_exit(fn -> :persistent_term.put({Worker, :status}, previous_status) end)

    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(view)
    assert render(view) =~ "Aligned via manual"

    view |> element("#reset-subtitle-#{item.id}") |> render_click()
    render_async(view)
    assert render(view) =~ "Not analyzed"

    send(view.pid, {:subtitle_sync_status, historic_status})
    assert render(view) =~ "Not analyzed"

    send(view.pid, {:subtitle_sync_status, status_with_results([result], historic_status)})
    assert_eventually(fn -> render(view) =~ "Aligned via manual" end)
  end

  test "worker batches larger than recent history trigger an authoritative reload", %{
    conn: conn,
    movies: movies
  } do
    {movie, _video, _sidecar, item} = managed_movie!(movies, "LargeBatch")
    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(view)
    assert render(view) =~ "Not analyzed"

    assert {:ok, :corrected, _item} = Sync.manual(item, 1_000, 1.0)

    unrelated =
      for index <- 1..20 do
        %{
          id: "unrelated-#{index}",
          video_path: "/outside/#{index}.mkv",
          status: :aligned,
          method: "audio",
          offset_ms: 0,
          rate: 1.0,
          reason: nil
        }
      end

    result = %{
      id: item.id,
      video_path: item.video_path,
      status: :corrected,
      method: "manual",
      offset_ms: 1_000,
      rate: 1.0,
      reason: nil
    }

    status =
      unrelated
      |> Kernel.++([result])
      |> status_with_results()
      |> Map.update!(:recent, &Enum.take(&1, 20))

    send(view.pid, {:subtitle_sync_status, status})
    render_async(view)
    assert render(view) =~ "Aligned via manual"
  end

  test "scoped pages ignore worker results for other titles", %{conn: conn, movies: movies} do
    {movie, _video, _sidecar, _item} = managed_movie!(movies, "Scoped")
    {other_movie, other_video, _other_sidecar, other_item} = managed_movie!(movies, "Other")
    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(view)

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :find_files,
      contains: "/Scoped",
      once: true
    })

    result = %{
      id: other_item.id,
      video_path: other_video,
      scopes: MapSet.new([{:movie, other_movie.id}]),
      status: :aligned,
      method: "audio",
      offset_ms: 0,
      rate: 1.0,
      reason: nil
    }

    send(view.pid, {:subtitle_sync_status, status_with_results([result])})
    render(view)
    refute_receive {:filesystem_barrier, _pid, _ref, :find_files, _path}, 100
  end

  test "unexpected backups remain visibly quarantined across page loads", %{
    conn: conn,
    movies: movies
  } do
    {movie, _video, sidecar, item} = managed_movie!(movies, "Quarantined")
    File.write!(Sync.backup_path(sidecar), "unproven backup")

    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(view)
    assert render(view) =~ "Needs review: replacement_cleanup_failed"
    refute has_element?(view, "#reset-subtitle-#{item.id}")
  end

  test "apply reauthorizes the selected item against the current catalog scope", %{
    conn: conn,
    movies: movies
  } do
    video = Path.join(movies, "Moved/Moved.mkv")
    replacement_video = Path.join(movies, "Moved/Replacement.mkv")
    sidecar = Path.rootname(video) <> ".en.srt"
    original = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, String.duplicate("v", 131_072))
    File.write!(replacement_video, String.duplicate("r", 131_072))
    File.write!(sidecar, original)
    {:ok, hash} = Subtitles.Moviehash.of_file(video)

    assert :ok =
             Manifest.put(
               video,
               hash,
               "en",
               "opensubtitles_hash",
               sidecar,
               digest(original)
             )

    movie =
      %{title: "Moved", status: :available}
      |> movie_fixture()
      |> Ecto.Changeset.change(file_path: video)
      |> Repo.update!()

    [item] = Sync.items({:movie, movie.id})
    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(view)
    view |> element("#subtitle-sync-item-#{item.id} button", "Adjust") |> render_click()

    params = %{"adjustment" => %{"mode" => "direct", "delay_ms" => "1000", "rate" => "1.0"}}
    view |> form("#subtitle-sync-form", params) |> render_change()

    movie |> Ecto.Changeset.change(file_path: replacement_video) |> Repo.update!()
    view |> form("#subtitle-sync-form", params) |> render_submit()

    assert File.read!(sidecar) == original
  end

  test "scoped apply holds the catalog write reservation through filesystem publication", %{
    movies: movies
  } do
    video = Path.join(movies, "Reserved/Reserved.mkv")
    replacement_video = Path.join(movies, "Reserved/Replacement.mkv")
    sidecar = Path.rootname(video) <> ".en.srt"
    original = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, String.duplicate("v", 131_072))
    File.write!(replacement_video, String.duplicate("r", 131_072))
    File.write!(sidecar, original)
    {:ok, hash} = Subtitles.Moviehash.of_file(video)

    assert :ok =
             Manifest.put(
               video,
               hash,
               "en",
               "opensubtitles_hash",
               sidecar,
               digest(original)
             )

    movie =
      %{title: "Reserved", status: :available}
      |> movie_fixture()
      |> Ecto.Changeset.change(file_path: video)
      |> Repo.update!()

    [item] = Sync.items({:movie, movie.id})
    assert {:ok, fingerprint} = Sync.fingerprint(item)
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :moviehash_data,
      contains: Path.basename(video),
      once: true
    })

    apply =
      Task.async(fn ->
        Sync.manual_in_scope({:movie, movie.id}, item.id, 1_000, 1.0, fingerprint)
      end)

    assert_receive {:filesystem_barrier, pid, ref, :moviehash_data, ^video}

    update =
      Task.async(fn ->
        movie |> Ecto.Changeset.change(file_path: replacement_video) |> Repo.update!()
      end)

    assert Task.yield(update, 100) == nil
    send(pid, {ref, :continue})
    assert {:ok, :corrected, _} = Task.await(apply)
    assert %{file_path: ^replacement_video} = Task.await(update)
    assert File.read!(sidecar) =~ "00:00:02,000"
  end

  test "extreme numeric adjustments are rejected without crashing the LiveView", %{
    conn: conn,
    movies: movies
  } do
    video = Path.join(movies, "Extreme/Extreme.mkv")
    sidecar = Path.rootname(video) <> ".en.srt"
    original = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, String.duplicate("v", 131_072))
    File.write!(sidecar, original)
    {:ok, hash} = Subtitles.Moviehash.of_file(video)

    assert :ok =
             Manifest.put(
               video,
               hash,
               "en",
               "opensubtitles_hash",
               sidecar,
               digest(original)
             )

    movie =
      %{title: "Extreme", status: :available}
      |> movie_fixture()
      |> Ecto.Changeset.change(file_path: video)
      |> Repo.update!()

    [item] = Sync.items({:movie, movie.id})
    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(view)
    view |> element("#subtitle-sync-item-#{item.id} button", "Adjust") |> render_click()

    params = %{
      "adjustment" => %{"mode" => "direct", "delay_ms" => "0", "rate" => "1.0e307"}
    }

    html = view |> form("#subtitle-sync-form", params) |> render_change()
    refute html =~ "subtitle-sync-preview"
    assert Process.alive?(view.pid)
  end

  test "reset with a missing backup reports failure and retains sync metadata", %{
    conn: conn,
    movies: movies
  } do
    video = Path.join(movies, "MissingBackup/MissingBackup.mkv")
    sidecar = Path.rootname(video) <> ".en.srt"
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, String.duplicate("v", 131_072))
    File.write!(sidecar, "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n")
    {:ok, hash} = Subtitles.Moviehash.of_file(video)

    assert :ok =
             Manifest.put(
               video,
               hash,
               "en",
               "opensubtitles_hash",
               sidecar,
               digest(File.read!(sidecar))
             )

    movie =
      %{title: "Missing Backup", status: :available}
      |> movie_fixture()
      |> Ecto.Changeset.change(file_path: video)
      |> Repo.update!()

    [item] = Sync.items({:movie, movie.id})
    assert {:ok, :corrected, _} = Sync.manual(item, 1_000, 1.0)
    corrected = File.read!(sidecar)
    metadata = Manifest.sync(Manifest.read(video), "en")
    File.rm!(Sync.backup_path(sidecar))

    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?movie=#{movie.id}")
    render_async(view)
    html = view |> element("#reset-subtitle-#{item.id}") |> render_click()

    refute html =~ "Original subtitle restored."
    assert html =~ "Original subtitle could not be restored."
    assert File.read!(sidecar) == corrected
    assert Manifest.sync(Manifest.read(video), "en") == metadata
  end

  test "subtitle sync route is admin-only", %{conn: conn} do
    conn = conn |> recycle() |> log_in_user(user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/subtitle-sync")
  end

  test "series scope exposes season bulk enqueue", %{conn: conn} do
    series = Repo.insert!(%Series{tmdb_id: 91_001, title: "Show", year: 2024})
    season = Repo.insert!(%Season{series_id: series.id, season_number: 1})

    Repo.insert!(%Episode{
      season_id: season.id,
      tmdb_episode_id: 91_001,
      episode_number: 1,
      title: "Pilot"
    })

    parent = self()

    start_supervised!(
      {Worker,
       name: Worker,
       initial_scan: false,
       scan: fn scope ->
         send(parent, {:scanned, scope})
         []
       end,
       analyze: fn _ -> :ok end}
    )

    {:ok, view, _html} = live(conn, ~p"/subtitle-sync?series=#{series.id}")
    render_async(view)

    view |> element("#enqueue-season-#{season.id}") |> render_click()
    season_id = season.id
    assert_receive {:scanned, {:season, ^season_id}}
  end

  test "Activity shows worker status and enqueues the whole library", %{conn: conn} do
    parent = self()

    start_supervised!(
      {Worker,
       name: Worker,
       initial_scan: false,
       scan: fn scope ->
         send(parent, {:scanned, scope})
         []
       end,
       analyze: fn _ ->
         [%{status: :failed, label: "Movie", reason: {:manifest, :eio}}]
       end}
    )

    {:ok, view, _html} = live(conn, ~p"/activity")
    assert has_element?(view, "#subtitle-sync-activity", "Subtitle synchronization")

    view |> element("#enqueue-subtitle-library") |> render_click()
    assert_receive {:scanned, :library}

    assert :ok = Worker.enqueue_units([%{video_path: "/media/Movie.mkv", label: "Movie"}])
    assert_eventually(fn -> render(view) =~ "manifest" end)
  end

  defp digest(content),
    do: content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp status_with_results(results, status \\ Worker.status()) do
    counts =
      Enum.reduce(results, status.counts, fn result, counts ->
        Map.update!(counts, result.status, &(&1 + 1))
      end)

    %{status | counts: counts, recent: results ++ status.recent}
  end

  defp managed_movie!(movies, title) do
    video = Path.join(movies, "#{title}/#{title}.mkv")
    sidecar = Path.rootname(video) <> ".en.srt"
    content = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, String.duplicate("v", 131_072))
    File.write!(sidecar, content)
    {:ok, hash} = Subtitles.Moviehash.of_file(video)
    :ok = Manifest.put(video, hash, "en", "opensubtitles_hash", sidecar, digest(content))

    movie =
      %{title: title, status: :available}
      |> movie_fixture()
      |> Ecto.Changeset.change(file_path: video)
      |> Repo.update!()

    [item] = Sync.items({:movie, movie.id})
    {movie, video, sidecar, item}
  end

  defp assert_eventually(fun, attempts \\ 30)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
