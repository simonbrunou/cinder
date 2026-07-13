defmodule Cinder.Download.TvPollerTest do
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  # The poller logs warnings/errors on the park/retry paths exercised below; capture them so
  # test output stays pristine (they print on failure).
  @moduletag :capture_log

  alias Cinder.Acquisition.{Anime, AnimePreferences, Release}
  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, Episode, Grab, Identity, Season, Series}
  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Download.TvPoller
  alias Cinder.Library.ImportStage
  alias Cinder.Repo

  import Cinder.CatalogFixtures
  import Cinder.LibraryStubs
  import Cinder.PollerHelpers

  # The poller runs in its own process (and a fresh pid after a crash), so the mock must be
  # global. Shared Sandbox (async: false) lets those processes use the test-owned DB connection.
  setup :set_mox_global

  @past ~D[2001-01-01]

  defp series_tree do
    series = series_fixture(%{tvdb_id: 99, monitor_strategy: :all})
    season = season_fixture(series)
    {series, season}
  end

  defp episode(season, ep_num, attrs \\ %{}) do
    episode_fixture(season, Map.merge(%{episode_number: ep_num}, Map.new(attrs)))
  end

  # A successful single-file import (content_path is the file itself). Episodes use a realistic
  # per-episode size so any size-band logic behaves as in production.
  defp stub_single_file_import, do: stub_import_ok(3_000_000_000)

  defp use_real_tv_library(tmp) do
    downloads = Path.join(tmp, "downloads")
    tv = Path.join(tmp, "tv")
    File.mkdir_p!(downloads)
    File.mkdir_p!(tv)

    saved =
      Map.new([:filesystem, :path_policy, :import_roots, :tv_library_path], fn key ->
        {key, Application.get_env(:cinder, key)}
      end)

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :tv_library_path, tv)

    on_exit(fn ->
      Enum.each(saved, fn {key, value} -> Application.put_env(:cinder, key, value) end)
      Application.delete_env(:cinder, :filesystem_barrier)
      Application.delete_env(:cinder, :filesystem_failure)
    end)

    %{downloads: downloads, tv: tv}
  end

  defp import_stat(path, size) do
    if String.contains?(path, ".cinder-stage-") or
         not String.starts_with?(path, "/tmp/cinder-test-tv-library/"),
       do: {:ok, %File.Stat{size: size, inode: 1, major_device: 1}},
       else: {:error, :enoent}
  end

  defp stub_accept_then_crash(remote_id) do
    {:ok, accepted} = Agent.start_link(fn -> %{adds: 0, jobs: %{}} end)

    stub(Cinder.Download.ClientMock, :add, fn _release, operation_key: key ->
      Agent.update(accepted, fn state ->
        %{state | adds: state.adds + 1, jobs: Map.put(state.jobs, key, remote_id)}
      end)

      Process.exit(self(), :kill)
    end)

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn key ->
      case Agent.get(accepted, &Map.get(&1.jobs, key)) do
        nil -> :not_found
        id -> {:ok, id}
      end
    end)

    stub(Cinder.Download.ClientMock, :status, fn ^remote_id ->
      {:ok, %{state: :downloading, progress: 0.0}}
    end)

    accepted
  end

  test "anime poll groups wanted episodes across seasons by series and reserves marked assignments" do
    series =
      series_fixture(%{tvdb_id: 99, monitor_strategy: :all, media_profile: :anime})

    first = episode(season_fixture(series, %{season_number: 1}), 25)
    second = episode(season_fixture(series, %{season_number: 2}), 1)
    release = raw_release("[Group] Show S01E25-S02E01 [1080p]", "anime-cross-season")
    counter = start_supervised!({Agent, fn -> 0 end})

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb_id, _title, _season ->
      Agent.update(counter, &(&1 + 1))
      {:ok, [release]}
    end)

    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, categories: [5070] ->
      Agent.update(counter, &(&1 + 1))
      {:ok, []}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:error, :timeout} end)
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    assert :ok = TvPoller.poll()

    assert %Intent{
             mapping_snapshot: %{"version" => 2},
             release_policy_snapshot: %{"version" => 1}
           } = intent = Repo.one!(Intent)

    assert Enum.sort(intent.episode_ids) == Enum.sort([first.id, second.id])

    assert Enum.sort(intent.mapping_snapshot["reserved_episode_ids"]) ==
             Enum.sort([first.id, second.id])

    assert Agent.get(counter, & &1) == 5
  end

  test "Anime preferred-group waiting holds only uncovered IDs without consuming attempts" do
    series =
      series_fixture(%{
        tvdb_id: 99,
        monitor_strategy: :all,
        media_profile: :anime,
        audio_mode: :any,
        preferred_release_groups: ["subsplease"],
        group_fallback_delay: 3_600
      })

    season = season_fixture(series, %{season_number: 1})
    first = episode(season, 1)
    second = episode(season, 2)

    releases = [
      %{
        title: "[SubsPlease] Show S01E01 [1080p]",
        size: 2_000_000_000,
        download_url: "preferred-one"
      },
      %{
        title: "[Other] Show S01E02 [1080p]",
        size: 2_000_000_000,
        download_url: "delayed-two",
        published_at: DateTime.utc_now(:second)
      }
    ]

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 -> {:ok, releases} end)

    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, categories: [5070] ->
      {:ok, releases}
    end)

    adds = start_supervised!({Agent, fn -> 0 end})

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      Agent.update(adds, &(&1 + 1))
      {:ok, "grab-#{release.download_url}"}
    end)

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    assert :ok = TvPoller.poll()

    assert Repo.get!(Episode, first.id).grab_id
    assert %Episode{grab_id: nil, search_attempts: 0} = Repo.get!(Episode, second.id)
    assert Agent.get(adds, & &1) == 1
  end

  test "invalid Anime series preferences hold the group without search or attempt bumps" do
    series =
      series_fixture(%{
        tvdb_id: 99,
        monitor_strategy: :all,
        media_profile: :anime,
        embedded_subtitle_mode: :require,
        subtitle_languages: []
      })

    wanted = episode(season_fixture(series), 1)
    searches = start_supervised!({Agent, fn -> 0 end})

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
      Agent.update(searches, &(&1 + 1))
      {:ok, []}
    end)

    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, _opts ->
      Agent.update(searches, &(&1 + 1))
      {:ok, []}
    end)

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    assert :ok = TvPoller.poll()

    assert %Episode{grab_id: nil, search_attempts: 0} = Repo.get!(Episode, wanted.id)
    assert Agent.get(searches, & &1) == 0
  end

  test "restart reconciliation creates one snapshot grab with every reserved episode" do
    series = series_fixture(%{monitor_strategy: :all, media_profile: :anime})
    first = episode(season_fixture(series, %{season_number: 1}), 25)
    second = episode(season_fixture(series, %{season_number: 2}), 1)
    assignment = anime_assignment(series, [first, second])

    assert {:ok, intent} =
             Download.reserve_intent(%{
               kind: :season_pack,
               target_id: first.id,
               episode_ids: assignment.episode_ids,
               protocol: :torrent,
               release: assignment.release,
               mapping_snapshot: assignment.mapping_snapshot,
               release_policy_snapshot: assignment.release.release_policy_snapshot
             })

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-anime-restart"})
      |> Repo.update!()

    frozen_policy = assignment.release.release_policy_snapshot
    assert intent.release_policy_snapshot == frozen_policy

    series
    |> Series.anime_preferences_changeset(%{
      audio_mode: :any,
      embedded_subtitle_mode: :require,
      subtitle_languages: ["fr"]
    })
    |> Repo.update!()

    {:ok, current_policy} =
      AnimePreferences.resolve(Repo.get!(Series, series.id), Cinder.Settings.anime_defaults())

    current_snapshot = AnimePreferences.snapshot(current_policy, assignment.release)
    refute current_snapshot == frozen_policy

    stub(Cinder.Download.ClientMock, :status, fn "hash-anime-restart" ->
      {:ok, %{state: :downloading, progress: 0.0}}
    end)

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    assert :ok = TvPoller.poll()

    assert %Grab{mapping_snapshot: snapshot} = grab = Repo.one!(Grab)
    assert snapshot == assignment.mapping_snapshot
    assert grab.release_policy_snapshot == frozen_policy
    refute grab.release_policy_snapshot == current_snapshot

    assert grab
           |> Repo.preload(:episodes)
           |> Map.fetch!(:episodes)
           |> Enum.map(& &1.id)
           |> Enum.sort() ==
             Enum.sort(intent.episode_ids)

    refute Repo.get(Intent, intent.id)
  end

  @tag :tmp_dir
  test "restart import keeps the reserved parser context after provider aliases refresh", %{
    tmp_dir: tmp
  } do
    %{downloads: downloads} = use_real_tv_library(tmp)
    series = series_fixture(%{monitor_strategy: :all, media_profile: :anime})
    episode = episode(season_fixture(series), 1)

    assert {:ok, _coordinate} =
             Catalog.put_episode_coordinate(
               series,
               %{
                 source: "manual",
                 scheme: "absolute",
                 namespace: "manual",
                 canonical_value: "1",
                 precedence: :manual
               },
               [episode.id]
             )

    assert {:ok, [_alias]} =
             Identity.replace_provider_aliases(
               series,
               "tmdb",
               "alternative_titles",
               :inferred,
               [%{title: "Frozen Alias", kind: :alternative}]
             )

    assignment =
      anime_assignment(series, [episode], "[Group] Frozen Alias - 1 [1080p]")

    assert assignment.mapping_snapshot["parser_context"]["aliases"] == ["Frozen Alias"]

    assert {:ok, intent} =
             Download.reserve_intent(%{
               kind: :episode,
               target_id: episode.id,
               episode_ids: [episode.id],
               protocol: :torrent,
               release: assignment.release,
               mapping_snapshot: assignment.mapping_snapshot,
               release_policy_snapshot: assignment.release.release_policy_snapshot
             })

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-frozen-context"})
      |> Repo.update!()

    assert {:ok, [_alias]} =
             Identity.replace_provider_aliases(
               series,
               "tmdb",
               "alternative_titles",
               :inferred,
               [%{title: "Replacement Alias", kind: :alternative}]
             )

    refute Enum.any?(Catalog.anime_series_acquisition_context(series).aliases, fn alias_record ->
             alias_record.title == "Frozen Alias"
           end)

    source = Path.join(downloads, "Frozen Alias - 1.mkv")
    File.write!(source, "candidate")

    stub(Cinder.Download.ClientMock, :status, fn "hash-frozen-context" ->
      {:ok, %{state: :completed, content_path: source}}
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)
    start_supervised!({TvPoller, interval: 60_000})

    assert :ok = TvPoller.poll()

    refute Repo.get(Intent, intent.id)
    assert Repo.get!(Episode, episode.id).file_path =~ "S01E01"
    assert Repo.aggregate(Grab, :count) == 0
  end

  test "advances a completed single-file grab through download to import in one tick" do
    {series, season} = series_tree()
    e1 = episode(season, 3)
    {:ok, grab} = Catalog.create_grab("hash-a", :torrent, [e1.id])
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-a" ->
      {:ok, %{state: :completed, content_path: "/dl/Show.S01E03.1080p.mkv"}}
    end)

    stub_single_file_import()

    assert :ok = TvPoller.poll()

    # advance marked it downloaded, then import (same tick) hardlinked + finalized.
    assert Repo.get(Grab, grab.id) == nil
    imported = Repo.get!(Episode, e1.id)

    assert imported.file_path ==
             "/tmp/cinder-test-tv-library/Show (2008) {tmdb-#{series.tmdb_id}}/Season 01/Show (2008) {tmdb-#{series.tmdb_id}} - S01E03.mkv"

    assert is_nil(imported.grab_id)
  end

  @tag :tmp_dir
  test "a resolved snapshot persists decisions before the first stage link", %{tmp_dir: tmp} do
    %{downloads: downloads} = use_real_tv_library(tmp)
    {_series, season} = series_tree()
    episode = episode(season, 1)
    source = Path.join(downloads, "Show.S01E01.1080p.mkv")
    File.write!(source, "candidate")

    grab =
      downloaded_snapshot_grab(
        [episode],
        source,
        anime_standard_snapshot(episode)
      )

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :ln,
      contains: "Season 01",
      once: true
    })

    stub(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)
    start_supervised!({TvPoller, interval: 60_000})

    poll = Task.async(fn -> TvPoller.poll() end)
    assert_receive {:filesystem_barrier, pid, ref, :ln, _candidate}, 1_000

    assert %Grab{
             mapping_status: :resolved,
             automatic_mapping_decisions: %{"files" => [%{"relative_path" => relative_path}]}
           } = Repo.get!(Grab, grab.id)

    assert relative_path == Path.basename(source)
    send(pid, {ref, :continue})

    assert :ok = Task.await(poll)
    refute Repo.get(Grab, grab.id)
    assert Repo.get!(Episode, episode.id).file_path =~ "S01E01"
  end

  test "an ambiguous snapshot grab is held once without attempts, stages, or client removal" do
    {_series, season} = series_tree()
    episodes = Enum.map(1..3, &episode(season, &1))
    source = "/downloads/Show - 11-12.mkv"
    snapshot = anime_ambiguous_snapshot(episodes)
    grab = downloaded_snapshot_grab(episodes, source, snapshot)

    saved_import_roots = Application.get_env(:cinder, :import_roots)
    Application.put_env(:cinder, :import_roots, ["/downloads"])
    on_exit(fn -> Application.put_env(:cinder, :import_roots, saved_import_roots) end)

    expect(Cinder.Library.FilesystemMock, :dir?, 1, fn ^source -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, 1, fn ^source ->
      {:ok,
       %File.Stat{
         type: :regular,
         size: 1016,
         major_device: 1,
         inode: 116,
         mtime: {{2026, 7, 13}, {12, 0, 0}}
       }}
    end)

    start_supervised!({TvPoller, interval: 60_000})

    assert :ok = TvPoller.poll()

    assert %Grab{
             mapping_status: :needs_mapping,
             download_attempts: 0,
             mapping_issue: %{"reason" => "unresolved_file"}
           } = Repo.get!(Grab, grab.id)

    assert Repo.aggregate(ImportStage, :count) == 0
    assert Enum.all?(episodes, &(Repo.get!(Episode, &1.id).grab_id == grab.id))
    assert Catalog.list_grabs_downloaded() == []

    assert :ok = TvPoller.poll()
    assert Repo.get!(Grab, grab.id).mapping_status == :needs_mapping
  end

  @tag :tmp_dir
  test "inventory mutation restarts a fresh preflight next tick without a retry bump", %{
    tmp_dir: tmp
  } do
    %{downloads: downloads} = use_real_tv_library(tmp)
    Application.put_env(:cinder, :path_policy, Cinder.Test.PermissivePathPolicy)
    {_series, season} = series_tree()
    episode = episode(season, 1)
    source = Path.join(downloads, "Show.S01E01.1080p.mkv")
    File.write!(source, "before")

    grab =
      downloaded_snapshot_grab(
        [episode],
        source,
        anime_standard_snapshot(episode)
      )

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :lstat,
      contains: Path.basename(source),
      once: true
    })

    stub(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)
    start_supervised!({TvPoller, interval: 60_000})

    poll = Task.async(fn -> TvPoller.poll() end)
    assert_receive {:filesystem_barrier, pid, ref, :lstat, ^source}, 1_000
    File.write!(source, "after-mutation")
    send(pid, {ref, :continue})

    assert :ok = Task.await(poll)

    assert %Grab{mapping_status: :resolved, download_attempts: 0} = Repo.get!(Grab, grab.id)
    assert Repo.aggregate(ImportStage, :count) == 0
    assert Repo.get!(Episode, episode.id).file_path == nil

    assert :ok = TvPoller.poll()
    refute Repo.get(Grab, grab.id)
    assert Repo.get!(Episode, episode.id).file_path =~ "S01E01"
  end

  defp anime_assignment(series, episodes, title \\ "[Group] Show S01E25-S02E01 [1080p]") do
    candidate = title |> raw_release("anime-assignment") |> Release.new()
    context = Catalog.anime_series_acquisition_context(series)
    {:ok, policy} = AnimePreferences.resolve(series, Cinder.Settings.anime_defaults())

    assert {:ok, %{assignments: [assignment]}} =
             Anime.select_episodes(
               [candidate],
               context,
               Enum.map(episodes, & &1.id),
               AnimePreferences.selection_opts(policy)
             )

    assignment
  end

  defp raw_release(title, download_url) do
    %{title: title, size: 4_000_000_000, download_url: download_url, seeders: 10}
  end

  defp anime_standard_snapshot(episode) do
    canonical_value =
      "S01E#{episode.episode_number |> Integer.to_string() |> String.pad_leading(2, "0")}"

    %{
      "version" => 2,
      "parser_context" => %{"title" => "Show", "aliases" => [], "year" => 2008},
      "mappings" => [
        %{
          "identity" => %{
            "source" => "cinder",
            "scheme" => "standard",
            "namespace" => "canonical",
            "canonical_value" => canonical_value
          },
          "precedence" => "manual",
          "episode_ids" => [episode.id],
          "evidence" => nil
        }
      ]
    }
  end

  defp anime_ambiguous_snapshot([first, second, third]) do
    %{
      "version" => 2,
      "parser_context" => %{"title" => "Show", "aliases" => [], "year" => 2008},
      "mappings" => [
        anime_absolute_mapping("one", "11", [first.id]),
        anime_absolute_mapping("one", "12", [second.id]),
        anime_absolute_mapping("two", "12", [third.id])
      ]
    }
  end

  defp anime_absolute_mapping(source, value, episode_ids) do
    %{
      "identity" => %{
        "source" => source,
        "scheme" => "absolute",
        "namespace" => source,
        "canonical_value" => value
      },
      "precedence" => "manual",
      "episode_ids" => episode_ids,
      "evidence" => nil
    }
  end

  defp downloaded_snapshot_grab(episodes, content_path, snapshot) do
    grab =
      Repo.insert!(%Grab{
        download_id: "anime-#{System.unique_integer([:positive])}",
        download_protocol: :torrent,
        content_path: content_path,
        mapping_snapshot: snapshot
      })

    ids = Enum.map(episodes, & &1.id)
    Repo.update_all(from(e in Episode, where: e.id in ^ids), set: [grab_id: grab.id])
    grab
  end

  test "publishes a downloading grab snapshot without rewriting an equal poll" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("hash-progress", :torrent, [e1.id])
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-progress" ->
      {:ok, %{state: :downloading, progress: 0.42, speed: nil, eta: 90}}
    end)

    assert :ok = TvPoller.poll()

    assert %Grab{
             download_progress: 0.42,
             download_speed: nil,
             download_eta: 90,
             updated_at: updated_at
           } = Repo.get!(Grab, grab.id)

    # Timestamps are second-precision, so make an unintended write observable.
    Process.sleep(1_100)
    assert :ok = TvPoller.poll()
    assert Repo.get!(Grab, grab.id).updated_at == updated_at
  end

  test "clears a downloading grab snapshot after a transient client error" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("hash-timeout", :torrent, [e1.id])

    assert {:ok, _grab} =
             Catalog.update_grab_download_metrics(grab, %{
               download_progress: 0.42,
               download_speed: 1_500_000,
               download_eta: 90
             })

    start_supervised!({TvPoller, interval: 60_000})
    stub(Cinder.Download.ClientMock, :status, fn "hash-timeout" -> {:error, :timeout} end)

    assert :ok = TvPoller.poll()

    assert %Grab{
             download_attempts: 0,
             download_progress: nil,
             download_speed: nil,
             download_eta: nil
           } = Repo.get!(Grab, grab.id)
  end

  test "marking a grab downloaded clears its snapshot and rejects a stale observation" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("hash-complete", :torrent, [e1.id])

    assert {:ok, progressed_grab} =
             Catalog.update_grab_download_metrics(grab, %{
               download_progress: 0.42,
               download_speed: 1_500_000,
               download_eta: 90
             })

    assert {:ok, _grab} =
             Catalog.mark_grab_downloaded(progressed_grab, "/dl/Show.S01E01.1080p.mkv")

    assert %Grab{
             content_path: "/dl/Show.S01E01.1080p.mkv",
             download_progress: nil,
             download_speed: nil,
             download_eta: nil
           } = Repo.get!(Grab, grab.id)

    assert {:error, :stale_grab} =
             Catalog.update_grab_download_metrics(progressed_grab, %{
               download_progress: 0.5,
               download_speed: 2_000_000,
               download_eta: 60
             })
  end

  test "imports a downloaded season pack, mapping each file to its episode, then finalizes" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    e2 = episode(season, 2)
    {:ok, grab} = Catalog.create_grab("hash-p", :torrent, [e1.id, e2.id])
    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn "/dl/pack" -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn "/dl/pack" ->
      {:ok,
       [
         {"/dl/pack/Show.S01E01.1080p.mkv", 3_000_000_000},
         {"/dl/pack/Show.S01E02.1080p.mkv", 3_000_000_000}
       ]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, &import_stat(&1, 3_000_000_000))

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rename, fn _src, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert :ok = TvPoller.poll()

    assert Repo.get(Grab, grab.id) == nil
    assert Repo.get!(Episode, e1.id).file_path =~ "S01E01"
    assert Repo.get!(Episode, e2.id).file_path =~ "S01E02"
  end

  @tag :tmp_dir
  test "cancelling a grab after file staging rolls every destination back", %{tmp_dir: tmp} do
    %{downloads: downloads} = use_real_tv_library(tmp)
    {series, season} = series_tree()
    episode = episode(season, 1)
    source = Path.join(downloads, "Show.S01E01.1080p.mkv")
    File.write!(source, "candidate")
    {:ok, grab} = Catalog.create_grab("race-grab", :torrent, [episode.id])
    {:ok, _} = Catalog.mark_grab_downloaded(grab, source)
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :remove, fn "race-grab", delete_files: true -> :ok end)

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :ln,
      contains: "Show (2008) {tmdb-#{series.tmdb_id}} - S01E01.mkv"
    })

    poll = Task.async(fn -> TvPoller.poll() end)
    assert_receive {:filesystem_barrier, pid, ref, operation, dest}, 1_000
    assert operation == :ln
    assert File.read!(dest) == "candidate"
    assert {:ok, _} = Catalog.cancel_grab(Repo.get!(Grab, grab.id))
    send(pid, {ref, :continue})

    assert :ok = Task.await(poll)
    refute File.exists?(dest)
    assert Repo.get(Grab, grab.id) == nil
    assert Repo.get!(Episode, episode.id).file_path == nil
  end

  test "finish_grab rejects an episode that lost monitoring after staging" do
    {_series, season} = series_tree()
    episode = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("stale-owner", :torrent, [episode.id])

    Repo.update_all(from(e in Episode, where: e.id == ^episode.id), set: [monitored: false])

    quality = %{
      resolution: "1080p",
      size: 3_000_000_000,
      language: nil,
      source: "web",
      audio_languages: [],
      embedded_subtitles: [],
      sidecar_subtitles: []
    }

    assert {:error, :stale_grab} =
             Catalog.finish_grab(grab, [{episode.id, "/library/Show.S01E01.mkv", quality}])

    assert Repo.get(Grab, grab.id)
    stale = Repo.get!(Episode, episode.id)
    assert stale.file_path == nil
    assert stale.grab_id == grab.id
  end

  test "parks a downloaded grab whose content matches no episode; its episode re-searches" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("hash-u", :torrent, [e1.id])
    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
    # The file clearly names E09, which the grab does not want — never mislabel it as E01.
    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/dl/pack/Show.S01E09.1080p.mkv", 3_000_000_000}]}
    end)

    assert :ok = TvPoller.poll()

    assert Repo.get(Grab, grab.id) == nil
    parked = Repo.get!(Episode, e1.id)
    assert is_nil(parked.file_path)
    assert is_nil(parked.grab_id)
    assert parked.search_attempts >= 1
  end

  test "searches a wanted episode and grabs the matching release" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    # Patterns confirm the series' tvdb_id, title, and season number are passed through.
    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [
         %{
           title: "Show.S01E01.1080p.WEB-DL-GRP",
           size: 2_000_000_000,
           download_url: "u",
           seeders: 5
         }
       ]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-new"} end)

    assert :ok = TvPoller.poll()

    linked = Repo.get!(Episode, e1.id)
    assert linked.grab_id
    grab = Repo.get!(Grab, linked.grab_id)
    assert grab.download_id == "hash-new"
    assert grab.download_protocol == :torrent
  end

  test "a definite add rejection releases the episode for the next search tick" do
    {_series, season} = series_tree()
    episode = episode(season, 1)
    {:ok, adds} = Agent.start_link(fn -> 0 end)

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [
         %{
           title: "Show.S01E01.1080p.WEB-DL-GRP",
           size: 2_000_000_000,
           download_url: "u",
           seeders: 5
         }
       ]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      case Agent.get_and_update(adds, &{&1, &1 + 1}) do
        0 -> {:error, :add_rejected}
        _ -> {:ok, "hash-tv-after-rejection"}
      end
    end)

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    assert :ok = TvPoller.poll()
    assert Repo.get!(Episode, episode.id).grab_id == nil
    assert MapSet.size(Cinder.Download.pending_episode_ids()) == 0

    assert :ok = TvPoller.poll()
    linked = Repo.get!(Episode, episode.id)
    assert Repo.get!(Grab, linked.grab_id).download_id == "hash-tv-after-rejection"
  end

  test "recovers a remotely accepted episode after process death without submitting twice" do
    {_series, season} = series_tree()
    episode = episode(season, 1)

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [
         %{
           title: "Show.S01E01.1080p.WEB-GRP",
           size: 2_000_000_000,
           download_url: "episode",
           seeders: 1
         }
       ]}
    end)

    accepted = stub_accept_then_crash("hash-episode-crash")
    pid = start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    catch_exit(TvPoller.poll(pid))

    new_pid = await_restart(TvPoller, pid)
    assert :ok = TvPoller.poll(new_pid)
    assert %{adds: 1} = Agent.get(accepted, & &1)

    linked = Repo.get!(Episode, episode.id)
    assert linked.grab_id
    assert Repo.get!(Grab, linked.grab_id).download_id == "hash-episode-crash"
  end

  test "recovers a remotely accepted season pack after process death without submitting twice" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    e2 = episode(season, 2)

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [
         %{
           title: "Show.S01.1080p.WEB-GRP",
           size: 4_000_000_000,
           download_url: "pack",
           seeders: 1
         }
       ]}
    end)

    accepted = stub_accept_then_crash("hash-pack-crash")
    pid = start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    catch_exit(TvPoller.poll(pid))

    new_pid = await_restart(TvPoller, pid)
    assert :ok = TvPoller.poll(new_pid)
    assert %{adds: 1} = Agent.get(accepted, & &1)

    grab_id = Repo.get!(Episode, e1.id).grab_id
    assert grab_id
    assert Repo.get!(Episode, e2.id).grab_id == grab_id
    assert Repo.get!(Grab, grab_id).download_id == "hash-pack-crash"
  end

  test "sanitizes remote release titles in client failure logs" do
    {_series, season} = series_tree()
    _episode = episode(season, 1)
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [
         %{
           title: "Show.S01E01.1080p.WEB-DL-GRP\r\nFORGED",
           size: 2_000_000_000,
           download_url: "u",
           seeders: 5
         }
       ]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:error, :remote_rejected} end)

    log = capture_log(fn -> assert :ok = TvPoller.poll() end)

    assert log =~ "Show.S01E01.1080p.WEB-DL-GRPFORGED"
    assert log =~ ":remote_rejected"
    refute log =~ "\nFORGED"
  end

  test "rejects a same-season release of a different series (does not grab)" do
    # tvdb_id: nil — the wrong-series title guard applies only to the free-text
    # fallback search; a TvdbId-token search is already scoped to the right show.
    series = series_fixture(%{tvdb_id: nil, monitor_strategy: :all})
    season = season_fixture(series)
    e1 = episode(season, 1)
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    # A different series at the same season number: its name does not contain "Show",
    # so the title guard drops it before scoring (no client.add — nothing is grabbed).
    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
      {:ok,
       [
         %{
           title: "Parks.and.Recreation.S01E01.1080p.WEB-DL-GRP",
           size: 2_000_000_000,
           download_url: "u"
         }
       ]}
    end)

    assert :ok = TvPoller.poll()

    e1 = Repo.get!(Episode, e1.id)
    assert is_nil(e1.grab_id)
    assert e1.search_attempts == 1
  end

  test "does not re-grab a blocklisted pack; covers the wanted set from the remaining releases" do
    {series, season} = series_tree()
    e1 = episode(season, 1)
    e2 = episode(season, 2)

    # The season pack covers both episodes and would win greedily; blocking it (scoped to the
    # series) forces the two single-episode releases instead.
    Repo.insert!(%BlockedRelease{
      release_title: "Show.S01.1080p.WEB-GRP",
      reason: "no_files_matched",
      series_id: series.id
    })

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [
         %{
           title: "Show.S01.1080p.WEB-GRP",
           size: 4_000_000_000,
           download_url: "pack",
           seeders: 9
         },
         %{
           title: "Show.S01E01.1080p.WEB-GRP",
           size: 2_000_000_000,
           download_url: "e1",
           seeders: 5
         },
         %{
           title: "Show.S01E02.1080p.WEB-GRP",
           size: 2_000_000_000,
           download_url: "e2",
           seeders: 5
         }
       ]}
    end)

    # Use the title as the download id so each grab is traceable to its release. Assertions go on
    # the resulting DB state, not inside the stub — a raise here runs in the poller's isolated
    # process and would be swallowed, never failing the test.
    stub(Cinder.Download.ClientMock, :add, fn release, _opts -> {:ok, release.title} end)

    assert :ok = TvPoller.poll()

    assert Repo.get!(Episode, e1.id).grab_id
    assert Repo.get!(Episode, e2.id).grab_id

    # The blocked pack is never the release of any created grab; the two singles cover the want.
    titles = Repo.all(Grab) |> Enum.map(& &1.release_title) |> Enum.sort()
    assert titles == ["Show.S01E01.1080p.WEB-GRP", "Show.S01E02.1080p.WEB-GRP"]
  end

  test "recovers from a crash and still advances + imports, with no double-grab (OTP payoff)" do
    {_series, season} = series_tree()
    e1 = episode(season, 3)
    {:ok, grab} = Catalog.create_grab("hash-c", :torrent, [e1.id])
    pid = start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-c" ->
      {:ok, %{state: :completed, content_path: "/dl/Show.S01E03.1080p.mkv"}}
    end)

    stub_single_file_import()

    Process.exit(pid, :kill)
    new_pid = await_restart(TvPoller, pid)
    assert new_pid != pid

    assert :ok = TvPoller.poll(new_pid)

    assert Repo.get(Grab, grab.id) == nil
    recovered = Repo.get!(Episode, e1.id)
    assert recovered.file_path
    assert is_nil(recovered.grab_id)
  end

  test "parks a persistently failing download after max attempts; the episode re-searches" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("hash-z", :torrent, [e1.id])
    # Default search_retry_after (60s): the freed episode is not re-attempted the same tick.
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-z" -> {:ok, %{state: :error}} end)

    # Bounded: retried each tick (still downloading), then parked.
    Enum.each(1..9, fn _ -> TvPoller.poll() end)
    assert Repo.get(Grab, grab.id)

    assert :ok = TvPoller.poll()
    assert Repo.get(Grab, grab.id) == nil
    parked = Repo.get!(Episode, e1.id)
    assert is_nil(parked.grab_id)
    assert parked.search_attempts >= 1
  end

  test "a wanted episode that never finds a release search-parks after max attempts" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season -> {:ok, []} end)

    Cinder.TestNotifier.subscribe()

    Enum.each(1..9, fn _ -> TvPoller.poll() end)
    # Crossing the cap is announced exactly once — not on every failed attempt.
    refute_receive {:notify, {:episodes_search_exhausted, _}}

    assert :ok = TvPoller.poll()
    parked = Repo.get!(Episode, e1.id)
    assert parked.search_attempts == 10
    # The UI derives the give-up state from the same cap the sweep uses.
    assert Catalog.episode_state(parked) == :search_parked
    assert_receive {:notify, {:episodes_search_exhausted, [%Episode{id: id}]}}
    assert id == e1.id

    # Search-parked now (search_attempts >= max): further ticks no longer attempt it.
    assert :ok = TvPoller.poll()
    assert Repo.get!(Episode, e1.id).search_attempts == 10
  end

  test "a search-exhausted Anime story special stays in the wanted set but is skipped" do
    series = series_fixture(%{media_profile: :anime, monitor_strategy: :all})
    specials = season_fixture(series, %{season_number: 0})

    special =
      episode(specials, 0, %{
        classification: :story_special,
        monitored: true,
        search_attempts: Catalog.max_search_attempts()
      })

    assert special.id in Enum.map(Catalog.wanted_episodes(), & &1.id)

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    assert :ok = TvPoller.poll()

    assert Repo.reload!(special).search_attempts == Catalog.max_search_attempts()
    assert Repo.all(Intent) == []
    assert Repo.all(Grab) == []
  end

  test "a grab park that crosses the search cap announces exhaustion (finish_grab bump path)" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("hash-cap", :torrent, [e1.id])
    Repo.update_all(from(e in Episode, where: e.id == ^e1.id), set: [search_attempts: 9])

    Cinder.TestNotifier.subscribe()
    assert {:ok, _} = Catalog.park_grab(grab)

    assert_receive {:notify, {:episodes_search_exhausted, [%Episode{id: id}]}}
    assert id == e1.id
    assert Repo.get!(Episode, e1.id).search_attempts == 10
  end

  test "a parked grab of just-unmonitored episodes does not announce exhaustion" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("hash-unmon", :torrent, [e1.id])

    Repo.update_all(from(e in Episode, where: e.id == ^e1.id),
      set: [search_attempts: 9, monitored: false]
    )

    Cinder.TestNotifier.subscribe()
    assert {:ok, _} = Catalog.park_grab(grab)

    refute_receive {:notify, {:episodes_search_exhausted, _}}
  end

  test "a late-dated monitored episode becomes wanted after a refresh and grabs (M6 Done-when)" do
    series =
      Repo.insert!(%Series{
        tmdb_id: System.unique_integer([:positive]),
        tvdb_id: 99,
        title: "Show",
        year: 2008,
        monitored: true,
        monitor_strategy: :future
      })

    season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})

    # Announced but undated → monitored under :future, yet NOT wanted (air_date is nil).
    ep =
      Repo.insert!(%Episode{
        season_id: season.id,
        tmdb_episode_id: 700,
        episode_number: 1,
        monitored: true,
        air_date: nil
      })

    assert Catalog.wanted_episodes() == []

    # TMDB now carries a (past) air_date for the same episode.
    stub(Cinder.Catalog.TMDBMock, :get_series, fn _ ->
      {:ok,
       %{
         tmdb_id: series.tmdb_id,
         tvdb_id: 99,
         title: "Show",
         year: 2008,
         poster_path: nil,
         original_language: nil,
         seasons: [%{season_number: 1}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn _, 1 ->
      {:ok,
       %{
         season_number: 1,
         episodes: [%{tmdb_episode_id: 700, episode_number: 1, title: "Aired", air_date: @past}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ -> {:ok, []} end)

    assert {:ok, _} = Catalog.refresh_series(series)
    assert [%Episode{id: id}] = Catalog.wanted_episodes()
    assert id == ep.id

    # The poller now finds and grabs it.
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [
         %{
           title: "Show.S01E01.1080p.WEB-DL-GRP",
           size: 2_000_000_000,
           download_url: "u",
           seeders: 5
         }
       ]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-m6"} end)

    assert :ok = TvPoller.poll()

    linked = Repo.get!(Episode, ep.id)
    assert linked.grab_id
    assert Repo.get!(Grab, linked.grab_id).download_id == "hash-m6"
  end

  test "a downloaded grab is held (not parked, not a raise-loop) when the TV root is unset, then imports once set" do
    {series, season} = series_tree()
    e1 = episode(season, 3)
    {:ok, grab} = Catalog.create_grab("hash-x", :torrent, [e1.id])
    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/Show.S01E03.1080p.mkv")

    # Strict separate TV root (M8): with :tv_library_path unset, import returns an error tuple
    # (never a re-raise hot loop). A missing root is a config error, not transient — the grab is
    # held downloaded (no park, no re-download), preserving the content until the operator sets it.
    saved = Application.get_env(:cinder, :tv_library_path)
    Application.delete_env(:cinder, :tv_library_path)
    on_exit(fn -> Application.put_env(:cinder, :tv_library_path, saved) end)

    start_supervised!({TvPoller, interval: 60_000})

    Enum.each(1..12, fn _ -> TvPoller.poll() end)

    # Not parked, not re-searched: the grab is intact and still linked to its episode.
    assert Repo.get(Grab, grab.id)
    held = Repo.get!(Episode, e1.id)
    assert is_nil(held.file_path)
    assert held.grab_id == grab.id
    assert held.search_attempts == 0

    # Configure the root + a successful single-file import: the held grab now imports and finalizes.
    Application.put_env(:cinder, :tv_library_path, saved)
    stub_single_file_import()

    assert :ok = TvPoller.poll()

    assert Repo.get(Grab, grab.id) == nil
    imported = Repo.get!(Episode, e1.id)

    assert imported.file_path ==
             "/tmp/cinder-test-tv-library/Show (2008) {tmdb-#{series.tmdb_id}}/Season 01/Show (2008) {tmdb-#{series.tmdb_id}} - S01E03.mkv"
  end

  test "missing download roots hold a downloaded grab without consuming attempts" do
    {_series, season} = series_tree()
    e1 = episode(season, 3)
    {:ok, grab} = Catalog.create_grab("hash-roots", :torrent, [e1.id])
    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/downloads/Show.S01E03.mkv")

    saved = Application.get_env(:cinder, :import_roots)
    Application.put_env(:cinder, :import_roots, [])
    on_exit(fn -> Application.put_env(:cinder, :import_roots, saved) end)
    start_supervised!({TvPoller, interval: 60_000})

    log = capture_log(fn -> Enum.each(1..12, fn _ -> TvPoller.poll() end) end)

    assert %Grab{download_attempts: 0} = Repo.get!(Grab, grab.id)
    assert %Episode{grab_id: grab_id, search_attempts: 0} = Repo.get!(Episode, e1.id)
    assert grab_id == grab.id
    assert log =~ "download import roots not configured"
    refute log =~ "/downloads/Show.S01E03.mkv"
  end

  test "respects the TV size band: a too-large pack is not grabbed when tv_max_size is set" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)

    # 1 GB/episode cap (k=1); the only release is 5 GB → rejected → nothing grabbed. Without
    # the cap the existing search tests grab a 2 GB release, so this proves the band is plumbed
    # through and that blank ⇒ unbounded (no M5 regression).
    Application.put_env(:cinder, :tv_max_size, 1_000_000_000)
    on_exit(fn -> Application.delete_env(:cinder, :tv_max_size) end)

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok, [%{title: "Show.S01E01.1080p.WEB-DL-GRP", size: 5_000_000_000, download_url: "u"}]}
    end)

    # No client.add stub: if scoring let the oversized release through, the grab would raise here.
    assert :ok = TvPoller.poll()

    e1 = Repo.get!(Episode, e1.id)
    assert is_nil(e1.grab_id)
    assert e1.search_attempts == 1
  end

  test "a successful import emits the season-available notifier event" do
    Cinder.TestNotifier.subscribe()
    {_series, season} = series_tree()
    e1 = episode(season, 3)
    {:ok, _grab} = Catalog.create_grab("hash-n", :torrent, [e1.id])
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-n" ->
      {:ok, %{state: :completed, content_path: "/dl/Show.S01E03.1080p.mkv"}}
    end)

    stub_single_file_import()

    assert :ok = TvPoller.poll()

    assert_receive {:notify,
                    {:season_available, %{title: "Show", season_number: 1, poster_path: nil}}}
  end

  test "a parked grab emits the grab-failed notifier event (symmetric with :movie_failed)" do
    Cinder.TestNotifier.subscribe()
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("hash-f", :torrent, [e1.id])
    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/dl/pack/Show.S01E09.1080p.mkv", 3_000_000_000}]}
    end)

    assert :ok = TvPoller.poll()
    assert_receive {:notify, {:grab_failed, %Grab{id: gid}, :no_files_matched}}
    assert gid == grab.id
  end
end
