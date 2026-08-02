defmodule Cinder.Download.TvPollerTest do
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  # The poller logs warnings/errors on the park/retry paths exercised below; capture them so
  # test output stays pristine (they print on failure).
  @moduletag :capture_log

  alias Cinder.Acquisition.{Anime, AnimePreferences, Release}
  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, Episode, Grab, GrabFile, Identity, Season, Series}
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

  # A poll stamps last-run into process-global :persistent_term (PollerSkeleton's `status/0`,
  # read by /healthz); erase it so a recorded run can't bleed into another test/suite.
  setup do
    on_exit(fn -> :persistent_term.erase({TvPoller, :last_run}) end)
    stub_clean_content()
  end

  @past ~D[2001-01-01]

  defp series_tree do
    series = series_fixture(%{tvdb_id: 99, monitor_strategy: :all})
    season = season_fixture(series)
    {series, season}
  end

  defp episode(season, ep_num, attrs \\ %{}) do
    episode_fixture(season, Map.merge(%{episode_number: ep_num}, Map.new(attrs)))
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Anime preferences are global-only (no per-title override) — a test needing a non-default
  # policy overrides the global settings env for its duration and restores it on exit.
  defp set_anime_defaults!(overrides) do
    saved = Application.fetch_env!(:cinder, :anime_preferences)
    Application.put_env(:cinder, :anime_preferences, Keyword.merge(saved, overrides))
    on_exit(fn -> Application.put_env(:cinder, :anime_preferences, saved) end)
  end

  # Drives the free-disk prober (Cinder.Test.StubDisk) for a test's duration; restored on exit.
  defp set_disk_stub!(result) do
    saved = Application.get_env(:cinder, :disk_stats_stub)
    Application.put_env(:cinder, :disk_stats_stub, result)

    on_exit(fn ->
      if is_nil(saved),
        do: Application.delete_env(:cinder, :disk_stats_stub),
        else: Application.put_env(:cinder, :disk_stats_stub, saved)
    end)
  end

  defp set_anime_subtitle_languages!(csv) do
    saved = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])

    Application.put_env(
      :cinder,
      Cinder.Subtitles.Provider.OpenSubtitles,
      Keyword.put(saved, :languages, csv)
    )

    on_exit(fn ->
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, saved)
    end)
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

  defp enable_policy_probe do
    saved_media_info = Application.get_env(:cinder, :media_info)
    saved_import_roots = Application.get_env(:cinder, :import_roots)
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    Application.put_env(:cinder, :import_roots, ["/downloads"])

    on_exit(fn ->
      if saved_media_info,
        do: Application.put_env(:cinder, :media_info, saved_media_info),
        else: Application.delete_env(:cinder, :media_info)

      if saved_import_roots,
        do: Application.put_env(:cinder, :import_roots, saved_import_roots),
        else: Application.delete_env(:cinder, :import_roots)
    end)
  end

  defp stub_policy_inventory(source) do
    stat = %File.Stat{
      type: :regular,
      size: 2_000_000_000,
      major_device: 1,
      inode: 116,
      mtime: {{2026, 7, 13}, {12, 0, 0}}
    }

    stub(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)
    stub(Cinder.Library.FilesystemMock, :lstat, fn ^source -> {:ok, stat} end)
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

  defp cleanup_pending_for?(remote_id) do
    Repo.exists?(
      from i in Intent, where: i.remote_id == ^remote_id and i.status == :cleanup_pending
    )
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
    set_anime_defaults!(preferred_groups: ["subsplease"], group_fallback_delay: 3_600)

    series = series_fixture(%{tvdb_id: 99, monitor_strategy: :all, media_profile: :anime})

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

  test "search skips the grab (no attempt bump) when the download root can't hold the release" do
    {_series, season} = series_tree()
    ep = episode(season, 1)

    set_disk_stub!({:ok, %{free_bytes: 1_000_000_000, total_bytes: 100_000_000_000}})

    release = %{
      title: "Show.S01E01.1080p.WEB.x264-GRP",
      size: 8_000_000_000,
      download_url: "big-one"
    }

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 -> {:ok, [release]} end)

    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, _opts ->
      {:ok, [release]}
    end)

    # ClientMock.add is intentionally NOT stubbed — a disk-blocked grab must never reach the client.
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    log = capture_log(fn -> assert :ok = TvPoller.poll() end)

    assert %Episode{grab_id: nil, search_attempts: 0} = Repo.get!(Episode, ep.id)
    assert log =~ "insufficient free disk space"
    assert Repo.aggregate(Grab, :count) == 0
  end

  test "import holds (no attempt bump, no park) when the tv library root is nearly full" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("hash-full", :torrent, [e1.id])
    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")

    set_disk_stub!({:ok, %{free_bytes: 500_000_000, total_bytes: 100_000_000_000}})

    # No filesystem stubs: a held import must never reach Library.stage_episodes.
    start_supervised!({TvPoller, interval: 60_000})

    log = capture_log(fn -> assert :ok = TvPoller.poll() end)

    assert %Grab{download_attempts: attempts} = Repo.get!(Grab, grab.id)
    assert (attempts || 0) == 0
    assert Repo.get!(Episode, e1.id).file_path == nil
    assert log =~ "nearly full"
  end

  test "an operator season offset makes Second-Season episodes grab, incl. a native-collision episode (issue #156)" do
    series =
      series_fixture(%{
        tvdb_id: 99,
        monitor_strategy: :all,
        media_profile: :anime,
        title: "Monogatari"
      })

    # Second Season = TMDB S3 (wanted); Hanamonogatari = TMDB S4 (present, not wanted) so its native
    # S04E01..E05 codes collide with the offset-derived Second-Season S04 coords. Episodes 6..7 have
    # no native S04 twin, exercising the non-collision path in the same poll.
    s3 = season_fixture(series, %{season_number: 3})
    s4 = season_fixture(series, %{season_number: 4})
    second_season = for n <- 1..7, do: episode(s3, n)
    for n <- 1..5, do: episode(s4, n, %{monitored: false})

    {:ok, _} = Catalog.save_scene_offset_coordinates(series, 3, 1)

    releases =
      for n <- 1..7 do
        %{
          title: "[smol] Monogatari Series Second Season S04E#{pad2(n)} [1080p]",
          size: 2_000_000_000,
          download_url: "smol-#{n}"
        }
      end

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn
      99, _title, 4 -> {:ok, releases}
      99, _title, _season -> {:ok, []}
    end)

    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, categories: [5070] ->
      {:ok, []}
    end)

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      {:ok, "grab-#{release.download_url}"}
    end)

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    assert :ok = TvPoller.poll()

    for ep <- second_season do
      assert %Episode{grab_id: grab_id, search_attempts: 0} = Repo.get!(Episode, ep.id)
      assert grab_id, "expected Second-Season episode #{ep.episode_number} to grab"
    end
  end

  test "invalid Anime series preferences hold the group without search or attempt bumps" do
    set_anime_defaults!(embedded_subtitle_mode: :require)
    series = series_fixture(%{tvdb_id: 99, monitor_strategy: :all, media_profile: :anime})

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

    # The hold is DB-visible (issue #107) — not just a log line.
    assert Repo.get!(Series, series.id).anime_hold_reason == "subtitle_language_required"

    # Preferences become satisfiable → the next sweep clears the hold and searches normally.
    set_anime_defaults!(embedded_subtitle_mode: :prefer)
    assert :ok = TvPoller.poll()

    assert Repo.get!(Series, series.id).anime_hold_reason == nil
    assert Agent.get(searches, & &1) > 0
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

    set_anime_defaults!(embedded_subtitle_mode: :require)
    set_anime_subtitle_languages!("fr")

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

    episode_coordinate_fixture(
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
  test "a resolved preflight persists before the first stage link", %{tmp_dir: tmp} do
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

    # The preflight decision (mapping_status: :resolved) commits before the hardlink is even
    # attempted — so a crash mid-link never leaves a grab that looks unexamined.
    assert %Grab{mapping_status: :resolved} = Repo.get!(Grab, grab.id)
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
  test "an operator rename resolves a held grab, and Retry import finishes it", %{tmp_dir: tmp} do
    %{downloads: downloads} = use_real_tv_library(tmp)
    {_series, season} = series_tree()
    # Two reserved episodes (not one) so the lone-file release-inference fallback (issue #123)
    # doesn't auto-resolve this on the first poll — it's this test's job to prove the manual
    # rename + retry path still works for a batch it can't safely infer.
    episode1 = episode(season, 1)
    episode2 = episode(season, 2)
    release_dir = Path.join(downloads, "Show.Batch")
    File.mkdir_p!(release_dir)
    bad_path = Path.join(release_dir, "Show.mkv")
    good_path = Path.join(release_dir, "Show.S01E01.mkv")
    File.write!(bad_path, "content")
    File.write!(Path.join(release_dir, "Show.S01E02.mkv"), "content")

    base_mappings = anime_standard_snapshot(episode1)["mappings"]
    other_mappings = anime_standard_snapshot(episode2)["mappings"]

    snapshot = %{
      anime_standard_snapshot(episode1)
      | "mappings" => base_mappings ++ other_mappings
    }

    grab = downloaded_snapshot_grab([episode1, episode2], release_dir, snapshot)

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    held = Repo.get!(Grab, grab.id)
    assert held.mapping_status == :needs_mapping
    assert held.mapping_issue["reason"] == "unresolved_file"
    refute Repo.get!(Episode, episode1.id).file_path
    assert File.exists?(bad_path)

    # The operator fixes the release on disk, then asks for a retry.
    File.rename!(bad_path, good_path)
    assert {:ok, retried} = Catalog.retry_grab_mapping(held)
    assert retried.mapping_status == :resolved
    assert retried.download_attempts == 0

    stub(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)
    assert :ok = TvPoller.poll()

    refute Repo.get(Grab, grab.id)
    assert Repo.get!(Episode, episode1.id).file_path =~ "S01E01"
    assert Repo.get!(Episode, episode2.id).file_path =~ "S01E02"
  end

  test "a mapping retry with still-bad files re-holds with a fresh reason, no infinite loop" do
    {_series, season} = series_tree()
    episodes = Enum.map(1..3, &episode(season, &1))
    source = "/downloads/Show - 11-12.mkv"
    grab = downloaded_snapshot_grab(episodes, source, anime_ambiguous_snapshot(episodes))

    saved_import_roots = Application.get_env(:cinder, :import_roots)
    Application.put_env(:cinder, :import_roots, ["/downloads"])
    on_exit(fn -> Application.put_env(:cinder, :import_roots, saved_import_roots) end)

    stat = %File.Stat{
      type: :regular,
      size: 1016,
      major_device: 1,
      inode: 116,
      mtime: {{2026, 7, 13}, {12, 0, 0}}
    }

    stub(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)
    stub(Cinder.Library.FilesystemMock, :lstat, fn ^source -> {:ok, stat} end)

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    held = Repo.get!(Grab, grab.id)
    assert held.mapping_status == :needs_mapping
    first_issue = held.mapping_issue

    assert {:ok, retried} = Catalog.retry_grab_mapping(held)
    assert retried.download_attempts == 0

    # The files on disk are unchanged, so the fresh preflight fails the same way and re-holds —
    # not a bump-and-park loop, just a single re-derived hold.
    assert :ok = TvPoller.poll()

    re_held = Repo.get!(Grab, grab.id)
    assert re_held.mapping_status == :needs_mapping
    assert re_held.mapping_issue == first_issue
    assert re_held.download_attempts == 0
    assert Catalog.list_grabs_downloaded() == []

    # A held grab is excluded from the downloaded-import query, so further ticks are no-ops —
    # not a hot loop re-touching it every 5s.
    assert :ok = TvPoller.poll()
    assert Repo.get!(Grab, grab.id).mapping_status == :needs_mapping
  end

  test "a mapping hold survives a poller crash and restart, still skipped after" do
    {_series, season} = series_tree()
    episodes = Enum.map(1..3, &episode(season, &1))
    source = "/downloads/Show - 11-12.mkv"
    grab = downloaded_snapshot_grab(episodes, source, anime_ambiguous_snapshot(episodes))

    saved_import_roots = Application.get_env(:cinder, :import_roots)
    Application.put_env(:cinder, :import_roots, ["/downloads"])
    on_exit(fn -> Application.put_env(:cinder, :import_roots, saved_import_roots) end)

    stat = %File.Stat{
      type: :regular,
      size: 1016,
      major_device: 1,
      inode: 116,
      mtime: {{2026, 7, 13}, {12, 0, 0}}
    }

    stub(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)
    stub(Cinder.Library.FilesystemMock, :lstat, fn ^source -> {:ok, stat} end)

    pid = start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()
    assert Repo.get!(Grab, grab.id).mapping_status == :needs_mapping

    Process.exit(pid, :kill)
    new_pid = await_restart(TvPoller, pid)
    assert new_pid != pid

    assert :ok = TvPoller.poll(new_pid)
    assert Repo.get!(Grab, grab.id).mapping_status == :needs_mapping
    assert Catalog.list_grabs_downloaded() == []
  end

  test "a confirmed episodic policy mismatch releases the targets and grabs an exact sibling" do
    enable_policy_probe()
    series = series_fixture(%{monitor_strategy: :all, media_profile: :anime})
    episode = episode(season_fixture(series), 1)
    source = "/downloads/Show.S01E01.1080p.mkv"
    old_title = "[Group] Show S01E01 [1080p]"
    sibling_title = "[Group] Show S01E01 v2 [1080p]"
    grab = downloaded_policy_grab(episode, source, old_title)
    stub_policy_inventory(source)

    expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source ->
      {:ok, %{audio: ["ja"], subtitles: [], audio_unknown?: false, subtitle_unknown?: false}}
    end)

    remote_id = grab.download_id

    expect(Cinder.Download.ClientMock, :remove, fn ^remote_id, delete_files: true -> :ok end)

    releases = [
      raw_release(old_title, "old-policy-release"),
      raw_release(sibling_title, "sibling-policy-release")
    ]

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
      {:ok, releases}
    end)

    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, categories: [5070] ->
      {:ok, releases}
    end)

    selected = start_supervised!({Agent, fn -> nil end})

    expect(Cinder.Download.ClientMock, :add, fn release, _opts ->
      Agent.update(selected, fn _ -> release.title end)
      {:ok, "hash-policy-sibling"}
    end)

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    assert :ok = TvPoller.poll()

    assert Agent.get(selected, & &1) == sibling_title
    refute Repo.get(Grab, grab.id)

    assert %Grab{release_title: ^sibling_title, mapping_issue: nil} = sibling = Repo.one!(Grab)
    assert Repo.reload!(episode).grab_id == sibling.id
    assert Repo.reload!(episode).search_attempts == episode.search_attempts
    assert Catalog.blocked_release_titles_for_series(series.id) == [old_title]
    refute Repo.exists?(ImportStage)
  end

  test "an unavailable episodic policy probe holds the tenth attempt without losing evidence" do
    enable_policy_probe()
    Cinder.TestNotifier.subscribe()
    series = series_fixture(%{monitor_strategy: :all, media_profile: :anime})
    episode = episode(season_fixture(series), 1, %{search_attempts: 4})
    source = "/downloads/Show.S01E01.Unavailable.mkv"
    grab = downloaded_policy_grab(episode, source, "[Group] Show S01E01 [1080p]")
    stub_policy_inventory(source)

    stub(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source -> {:error, :timeout} end)

    start_supervised!({TvPoller, interval: 60_000})

    assert :ok = TvPoller.poll()
    first_attempt = Repo.get!(Grab, grab.id)
    assert first_attempt.mapping_status == :resolved
    assert first_attempt.download_attempts == 1

    for attempt <- 2..9 do
      assert :ok = TvPoller.poll()

      assert %Grab{mapping_status: :resolved, download_attempts: ^attempt} =
               Repo.get!(Grab, grab.id)
    end

    assert Enum.any?(Catalog.list_grabs_downloaded(), &(&1.id == grab.id))
    assert :ok = TvPoller.poll()

    assert %Grab{mapping_status: :verification_blocked, download_attempts: 10} =
             held =
             Repo.get!(Grab, grab.id)

    assert held.download_id == grab.download_id
    assert held.release_title == grab.release_title
    assert held.content_path == grab.content_path
    assert held.mapping_snapshot == grab.mapping_snapshot
    assert held.mapping_issue == grab.mapping_issue
    assert held.release_policy_snapshot == grab.release_policy_snapshot
    assert Repo.reload!(episode).grab_id == grab.id
    assert Repo.reload!(episode).search_attempts == episode.search_attempts
    assert Catalog.blocked_release_titles_for_series(series.id) == []
    refute Enum.any?(Catalog.list_grabs_downloaded(), &(&1.id == grab.id))
    assert Enum.any?(Catalog.list_grabs(), &(&1.id == grab.id))
    assert Catalog.get_grab(grab.id).mapping_status != :needs_mapping
    refute cleanup_pending_for?(grab.download_id)
    assert Repo.all(Intent) == []
    refute Repo.exists?(ImportStage)
    refute_receive {:notify, {:grab_failed, _, _}}

    assert {:ok, retried} = Catalog.retry_grab_verification(held)
    assert retried.mapping_status == :resolved
    assert retried.download_attempts == 0
    assert retried.content_path == held.content_path
    assert retried.download_id == held.download_id
    assert retried.mapping_snapshot == held.mapping_snapshot
    assert retried.release_policy_snapshot == held.release_policy_snapshot
    assert Repo.reload!(episode).grab_id == held.id

    assert {:error, :verification_not_held} =
             Catalog.retry_grab_verification(retried)
  end

  test "verification hold rejects a stale resolved observation" do
    series = series_fixture(%{monitor_strategy: :all, media_profile: :anime})
    episode = episode(season_fixture(series), 1)

    grab =
      downloaded_policy_grab(
        episode,
        "/downloads/Show.S01E01.StaleVerification.mkv",
        "[Group] Show S01E01 [1080p]"
      )

    Repo.update_all(from(g in Grab, where: g.id == ^grab.id),
      set: [download_attempts: 9, download_progress: 0.5]
    )

    assert {:error, :stale_grab} = Catalog.hold_grab_verification(grab)

    assert %Grab{mapping_status: :resolved, download_attempts: 9, download_progress: 0.5} =
             Repo.get!(Grab, grab.id)
  end

  test "a stale episodic rejection is skipped without attempts, mapping issues, or cleanup" do
    enable_policy_probe()
    series = series_fixture(%{monitor_strategy: :all, media_profile: :anime})
    episode = episode(season_fixture(series), 1)
    source = "/downloads/Show.S01E01.Stale.mkv"
    grab = downloaded_policy_grab(episode, source, "[Group] Show S01E01 [1080p]")
    stub_policy_inventory(source)

    expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source ->
      Repo.update_all(from(g in Grab, where: g.id == ^grab.id),
        set: [release_title: "Concurrent.Release"]
      )

      {:ok, %{audio: ["ja"], subtitles: [], audio_unknown?: false, subtitle_unknown?: false}}
    end)

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    assert %Grab{
             release_title: "Concurrent.Release",
             download_attempts: 0,
             mapping_status: :resolved,
             mapping_issue: nil
           } = Repo.get!(Grab, grab.id)

    assert Repo.reload!(episode).grab_id == grab.id
    assert Catalog.blocked_release_titles_for_series(series.id) == []
    assert Repo.all(Intent) == []
    refute Repo.exists?(ImportStage)
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
    ids = Enum.map(episodes, & &1.id)

    # Real v2 snapshots always carry the frozen reserved set (enforced at intent reservation);
    # preflight fails closed without it, so the fixture mirrors the real shape.
    snapshot = Map.put_new(snapshot, "reserved_episode_ids", ids)

    grab =
      Repo.insert!(%Grab{
        download_id: "anime-#{System.unique_integer([:positive])}",
        download_protocol: :torrent,
        content_path: content_path,
        mapping_snapshot: snapshot
      })

    Repo.update_all(from(e in Episode, where: e.id in ^ids), set: [grab_id: grab.id])
    grab
  end

  defp downloaded_policy_grab(episode, content_path, release_title) do
    snapshot = anime_standard_snapshot(episode) |> Map.put("reserved_episode_ids", [episode.id])

    grab =
      Repo.insert!(%Grab{
        download_id: "anime-policy-#{System.unique_integer([:positive])}",
        download_protocol: :torrent,
        release_title: release_title,
        content_path: content_path,
        mapping_snapshot: snapshot,
        release_policy_snapshot: policy_snapshot(release_title),
        mapping_status: :resolved
      })

    Repo.update_all(from(e in Episode, where: e.id == ^episode.id), set: [grab_id: grab.id])
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
             download_eta: 90
           } = Repo.get!(Grab, grab.id)

    # Force updated_at to a distinct sentinel so any rewrite by an equal poll is observable
    # immediately — no waiting on the second-precision clock to tick past `updated_at`.
    sentinel = ~U[2000-01-01 00:00:00Z]

    {1, _} =
      Repo.update_all(from(g in Grab, where: g.id == ^grab.id), set: [updated_at: sentinel])

    assert :ok = TvPoller.poll()
    assert Repo.get!(Grab, grab.id).updated_at == sentinel
  end

  test "keeps a grab's progress high-water after a transient client error" do
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
             download_progress: 0.42,
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
  test "mixed Standard pack commits matches, holds residual identity, and survives a poller death",
       %{tmp_dir: tmp} do
    %{downloads: downloads, tv: tv} = use_real_tv_library(tmp)
    release_dir = Path.join(downloads, "Show.S01")
    File.mkdir_p!(release_dir)
    matched_source = Path.join(release_dir, "Show.S01E01.1080p.mkv")
    residual_source = Path.join(release_dir, "Show.S01E99.1080p.mkv")
    File.write!(matched_source, "matched")
    File.write!(residual_source, "split provider part")

    {_series, season} = series_tree()
    matched = episode(season, 1)
    missing = episode(season, 2)
    {:ok, grab} = Catalog.create_grab("mixed-pack", :usenet, [matched.id, missing.id])
    {:ok, grab} = Catalog.mark_grab_downloaded(grab, release_dir)
    parent = self()

    stub(Cinder.Library.MediaServerMock, :scan, fn :tv ->
      send(parent, :scan_started_after_catalog_commit)
      Process.exit(self(), :kill)
    end)

    pid = start_supervised!({TvPoller, interval: 60_000})
    catch_exit(TvPoller.poll(pid))
    assert_receive :scan_started_after_catalog_commit
    restarted = await_restart(TvPoller, pid)

    imported = Repo.get!(Episode, matched.id)
    assert imported.file_path
    assert File.exists?(imported.file_path)

    still_reserved = Repo.get!(Episode, missing.id)
    assert still_reserved.grab_id == grab.id
    assert still_reserved.search_attempts == 0

    assert %GrabFile{
             relative_path: "Show.S01E99.1080p.mkv",
             source: "tvdb",
             scheme: "aired",
             namespace: "99",
             canonical_value: "S01E99",
             decision: nil
           } = residual = Repo.get_by!(GrabFile, grab_id: grab.id)

    stat = File.lstat!(residual_source)
    assert residual.size == stat.size
    assert residual.device == stat.major_device
    assert residual.inode == stat.inode
    assert File.dir?(release_dir)
    assert {:error, :unresolved_grab_files} = Catalog.close_grab(grab)

    imported_stat = File.lstat!(imported.file_path)
    assert :ok = TvPoller.poll(restarted)
    assert Repo.aggregate(from(f in GrabFile, where: f.grab_id == ^grab.id), :count) == 1
    assert File.lstat!(imported.file_path).inode == imported_stat.inode
    assert length(Path.wildcard(Path.join([tv, "**", "*.mkv"]))) == 1
  end

  @tag :tmp_dir
  test "an available episode upgrade atomically swaps bytes before deleting old primary/part files",
       %{tmp_dir: tmp} do
    %{downloads: downloads, tv: tv} = use_real_tv_library(tmp)
    {series, season} = series_tree()

    dest =
      Path.join([
        tv,
        "Show (2008) {tmdb-#{series.tmdb_id}}",
        "Season 01",
        "Show (2008) {tmdb-#{series.tmdb_id}} - S01E01.mkv"
      ])

    part = Path.join(Path.dirname(dest), "Show (2008) - S01E01-part2.mkv")
    source = Path.join(downloads, "Show.S01E01.720p.mkv")
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, "original")
    File.write!(part, "original-part")
    File.write!(source, "candidate")

    episode =
      episode(season, 1, %{
        monitored: false,
        file_path: dest,
        part_file_paths: [part],
        imported_resolution: "2160p"
      })

    {:ok, grab} =
      Catalog.create_grab("upgrade-grab", :torrent, [episode.id], "Show.S01E01.720p",
        allow_available: true
      )

    assert %Episode{file_path: ^dest, grab_id: grab_id} = Repo.reload!(episode)
    assert grab_id == grab.id
    {:ok, _} = Catalog.mark_grab_downloaded(grab, source)

    stub(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)
    start_supervised!({TvPoller, interval: 60_000})

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :ln,
      contains: Path.basename(dest),
      excludes: ".cinder-rollback",
      once: true
    })

    poll = Task.async(fn -> TvPoller.poll() end)
    assert_receive {:filesystem_barrier, pid, ref, :ln, ^dest}, 1_000

    assert File.read!(dest) == "candidate"
    assert File.exists?(part)
    assert Enum.any?(File.ls!(Path.dirname(dest)), &String.starts_with?(&1, ".cinder-rollback-"))

    send(pid, {ref, :continue})
    assert :ok = Task.await(poll)

    upgraded = Repo.reload!(episode)
    assert upgraded.file_path == dest
    assert upgraded.part_file_paths == []
    assert upgraded.grab_id == nil
    assert upgraded.imported_resolution == "720p"
    assert File.read!(dest) == "candidate"
    refute File.exists?(part)
    refute Enum.any?(File.ls!(Path.dirname(dest)), &String.contains?(&1, ".cinder-"))
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

  test "parks a downloaded video that matches no episode and requeues its episode" do
    {series, season} = series_tree()
    e1 = episode(season, 1)
    title = "Show.S01E09.1080p.WEB-DL-GRP"
    {:ok, grab} = Catalog.create_grab("hash-u", :torrent, [e1.id], title)
    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
    # The file clearly names E09, which the grab does not want — never mislabel it as E01.
    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/dl/pack/Show.S01E09.1080p.mkv", 3_000_000_000}]}
    end)

    assert :ok = TvPoller.poll()

    refute Repo.get(Grab, grab.id)
    parked = Repo.get!(Episode, e1.id)
    assert is_nil(parked.file_path)
    assert is_nil(parked.grab_id)
    assert parked.search_attempts == 1
    assert Catalog.blocked_release_titles_for_series(series.id) == [title]
    refute Repo.get_by(GrabFile, grab_id: grab.id)
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

  @tag :tmp_dir
  test "Standard alternate-season grab imports scene-named files into canonical episodes", %{
    tmp_dir: tmp
  } do
    %{downloads: downloads} = use_real_tv_library(tmp)
    release_dir = Path.join(downloads, "Frieren.S02")
    File.mkdir_p!(release_dir)

    for number <- 1..10 do
      File.write!(
        Path.join(release_dir, "Frieren.S02E#{pad2(number)}.1080p.mkv"),
        "episode #{number}"
      )
    end

    series =
      series_fixture(%{
        title: "Frieren",
        tvdb_id: 209_867,
        monitor_strategy: :all,
        media_profile: :standard,
        scene_numbering_group_id: "seasons-group"
      })

    season = season_fixture(series, %{season_number: 1})

    episodes =
      Map.new(1..38, fn number ->
        episode = episode(season, number, %{monitored: number >= 29})
        {number, episode}
      end)

    coordinates =
      Enum.map(1..38, fn number ->
        {scene_season, scene_episode} = if number <= 28, do: {1, number}, else: {2, number - 28}

        %{
          scheme: "scene",
          canonical_value: Episode.code(scene_season, scene_episode),
          precedence: :inferred,
          episode_ids: [Map.fetch!(episodes, number).id]
        }
      end)

    assert {:ok, _coordinates} =
             Identity.replace_provider_coordinates(
               series,
               "tmdb",
               "seasons-group",
               "scene",
               coordinates
             )

    test_pid = self()

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 209_867, "Frieren", season_number ->
      send(test_pid, {:searched_season, season_number})

      if season_number == 2 do
        {:ok,
         [
           %{
             title: "Frieren.S02.1080p.WEB-DL-GRP",
             size: 20_000_000_000,
             download_url: "scene-release"
           }
         ]}
      else
        {:ok, []}
      end
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      {:ok, "hash-standard-scene"}
    end)

    stub(Cinder.Download.ClientMock, :status, fn "hash-standard-scene" ->
      {:ok, %{state: :completed, content_path: release_dir}}
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)
    Cinder.TestNotifier.subscribe()
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    assert :ok = TvPoller.poll()
    assert_receive {:searched_season, 1}
    assert_receive {:searched_season, 2}

    assert %Grab{download_id: "hash-standard-scene"} = Repo.one!(Grab)
    assert :ok = TvPoller.poll()

    refute Repo.exists?(Grab)
    assert Catalog.blocked_release_titles_for_series(series.id) == []
    refute_receive {:notify, {:grab_failed, _, _}}

    for number <- 29..38 do
      imported = Repo.get!(Episode, Map.fetch!(episodes, number).id)

      assert Path.basename(imported.file_path) ==
               "Frieren (2008) {tmdb-#{series.tmdb_id}} - S01E#{pad2(number)}.mkv"
    end
  end

  @tag :tmp_dir
  test "migrated TVDB aired coordinates search and import alternate-season files", %{
    tmp_dir: tmp
  } do
    %{downloads: downloads} = use_real_tv_library(tmp)
    release_dir = Path.join(downloads, "Migrated.Show.S02")
    File.mkdir_p!(release_dir)
    File.write!(Path.join(release_dir, "Migrated.Show.S02E01.1080p.mkv"), "episode 29")
    File.write!(Path.join(release_dir, "Migrated.Show.S02E02.1080p.mkv"), "episode 30")

    series =
      series_fixture(%{
        title: "Migrated Show",
        tvdb_id: 321,
        monitor_strategy: :all,
        media_profile: :standard
      })

    season = season_fixture(series, %{season_number: 1})
    episode29 = episode(season, 29)
    episode30 = episode(season, 30)

    assert {:ok, _} =
             Identity.replace_provider_coordinates(series, "tvdb", "321", "aired", [
               %{
                 scheme: "aired",
                 canonical_value: Episode.code(2, 1),
                 precedence: :inferred,
                 episode_ids: [episode29.id]
               },
               %{
                 scheme: "aired",
                 canonical_value: Episode.code(2, 2),
                 precedence: :inferred,
                 episode_ids: [episode30.id]
               }
             ])

    assert {:ok, _} =
             Identity.replace_provider_coordinates(series, "tvdb", "321", "episode_id", [
               %{
                 scheme: "episode_id",
                 canonical_value: "90029",
                 precedence: :inferred,
                 episode_ids: [episode29.id]
               },
               %{
                 scheme: "episode_id",
                 canonical_value: "90030",
                 precedence: :inferred,
                 episode_ids: [episode30.id]
               }
             ])

    test_pid = self()

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 321, "Migrated Show", season_number ->
      send(test_pid, {:searched_migrated_season, season_number})

      if season_number == 2 do
        {:ok,
         [
           %{
             title: "Migrated.Show.S02.1080p.WEB-DL-GRP",
             size: 6_000_000_000,
             download_url: "migrated-release"
           }
         ]}
      else
        {:ok, []}
      end
    end)

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      assert release.title == "Migrated.Show.S02.1080p.WEB-DL-GRP"
      {:ok, "hash-standard-aired"}
    end)

    stub(Cinder.Download.ClientMock, :status, fn "hash-standard-aired" ->
      {:ok, %{state: :completed, content_path: release_dir}}
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    assert :ok = TvPoller.poll()
    assert_receive {:searched_migrated_season, 1}
    assert_receive {:searched_migrated_season, 2}
    refute_receive {:searched_migrated_season, _other}
    assert %Grab{download_id: "hash-standard-aired"} = Repo.one!(Grab)

    assert :ok = TvPoller.poll()
    refute Repo.exists?(Grab)

    assert Path.basename(Repo.get!(Episode, episode29.id).file_path) ==
             "Migrated Show (2008) {tmdb-#{series.tmdb_id}} - S01E29.mkv"

    assert Path.basename(Repo.get!(Episode, episode30.id).file_path) ==
             "Migrated Show (2008) {tmdb-#{series.tmdb_id}} - S01E30.mkv"
  end

  @tag :tmp_dir
  test "manual Standard search freezes scene and aired mappings through grab and import", %{
    tmp_dir: tmp
  } do
    %{downloads: downloads} = use_real_tv_library(tmp)
    scene_file = Path.join(downloads, "Manual.Bridge.S02E01.1080p.mkv")
    aired_file = Path.join(downloads, "Manual.Bridge.S03E01.1080p.mkv")
    File.write!(scene_file, "scene episode")
    File.write!(aired_file, "aired episode")

    series =
      series_fixture(%{
        title: "Manual Bridge",
        tvdb_id: 777,
        monitor_strategy: :all,
        media_profile: :standard,
        scene_numbering_group_id: "operator-group"
      })

    season = season_fixture(series, %{season_number: 1})
    episode29 = episode(season, 29)
    episode30 = episode(season, 30)

    assert {:ok, _} =
             Identity.replace_provider_coordinates(
               series,
               "tmdb",
               "operator-group",
               "scene",
               [
                 %{
                   scheme: "scene",
                   canonical_value: Episode.code(2, 1),
                   precedence: :inferred,
                   episode_ids: [episode29.id]
                 }
               ]
             )

    assert {:ok, _} =
             Identity.replace_provider_coordinates(series, "tvdb", "777", "aired", [
               %{
                 scheme: "aired",
                 canonical_value: Episode.code(3, 1),
                 precedence: :inferred,
                 episode_ids: [episode30.id]
               }
             ])

    test_pid = self()

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 777, "Manual Bridge", season_number ->
      send(test_pid, {:searched_manual_season, season_number})

      case season_number do
        1 -> {:ok, []}
        2 -> {:ok, [raw_release("Manual.Bridge.S02E01.1080p.WEB-DL-GRP", "manual-scene")]}
        3 -> {:ok, [raw_release("Manual.Bridge.S03E01.1080p.WEB-DL-GRP", "manual-aired")]}
      end
    end)

    candidates = Catalog.manual_search_episodes(series.id, 1)

    numbering =
      series
      |> Catalog.anime_series_acquisition_context()
      |> Cinder.Acquisition.standard_tv_numbering(candidates, MapSet.new([1]))

    assert {:ok, results} =
             Cinder.Acquisition.list_releases_tv(series, 1, standard_numbering: numbering)

    assert_receive {:searched_manual_season, 1}
    assert_receive {:searched_manual_season, 2}
    assert_receive {:searched_manual_season, 3}

    releases = Map.new(results, fn {release, _verdict} -> {release.download_url, release} end)
    assert releases["manual-scene"].resolved_episode_ids == [episode29.id]
    assert releases["manual-aired"].resolved_episode_ids == [episode30.id]

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      {:ok, "hash-#{release.download_url}"}
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)

    for {key, episode, source} <- [
          {"manual-scene", episode29, scene_file},
          {"manual-aired", episode30, aired_file}
        ] do
      assert {:ok, grab} = Catalog.manual_grab_tv(series, 1, Map.fetch!(releases, key))
      assert [linked] = grab |> Repo.preload(:episodes) |> Map.fetch!(:episodes)
      assert linked.id == episode.id
      assert {:ok, _} = Catalog.mark_grab_downloaded(grab, source)
    end

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 86_400})
    assert :ok = TvPoller.poll()

    for episode <- [episode29, episode30] do
      imported = Repo.get!(Episode, episode.id)

      assert Path.basename(imported.file_path) ==
               "Manual Bridge (2008) {tmdb-#{series.tmdb_id}} - S01E#{pad2(episode.episode_number)}.mkv"
    end
  end

  test "scene coordinates outrank conflicting migrated aired coordinates" do
    series =
      series_fixture(%{
        title: "Preferred Scene",
        tvdb_id: 654,
        monitor_strategy: :all,
        media_profile: :standard,
        scene_numbering_group_id: "operator-group"
      })

    season = season_fixture(series, %{season_number: 1})
    episode = episode(season, 29)

    assert {:ok, _} =
             Identity.replace_provider_coordinates(
               series,
               "tmdb",
               "operator-group",
               "scene",
               [
                 %{
                   scheme: "scene",
                   canonical_value: Episode.code(2, 1),
                   precedence: :inferred,
                   episode_ids: [episode.id]
                 }
               ]
             )

    assert {:ok, _} =
             Identity.replace_provider_coordinates(series, "tvdb", "654", "aired", [
               %{
                 scheme: "aired",
                 canonical_value: Episode.code(3, 1),
                 precedence: :inferred,
                 episode_ids: [episode.id]
               }
             ])

    test_pid = self()

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 654, "Preferred Scene", season_number ->
      send(test_pid, {:searched_precedence_season, season_number})

      if season_number == 2 do
        {:ok,
         [
           %{
             title: "Preferred.Scene.S02E01.1080p.WEB-DL-GRP",
             size: 3_000_000_000,
             download_url: "scene-precedence-release"
           }
         ]}
      else
        {:ok, []}
      end
    end)

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      assert release.title == "Preferred.Scene.S02E01.1080p.WEB-DL-GRP"
      {:ok, "hash-scene-precedence"}
    end)

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    log = capture_log([level: :info], fn -> assert :ok = TvPoller.poll() end)

    assert_receive {:searched_precedence_season, 1}
    assert_receive {:searched_precedence_season, 2}
    refute_receive {:searched_precedence_season, 3}
    assert length(:binary.matches(log, "ignored TVDB aired coordinates")) == 1

    grab = Repo.one!(Grab)
    assert grab.download_id == "hash-scene-precedence"
    assert {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/dl/pack/Preferred.Scene.S03E01.1080p.mkv", 3_000_000_000}]}
    end)

    assert :ok = TvPoller.poll()
    refute Repo.get(Grab, grab.id)
    assert Repo.get!(Episode, episode.id).file_path == nil
  end

  test "Standard alternate-season file without scene coordinates is parked and blocklisted" do
    {series, season} = series_tree()
    episode = episode(season, 29)
    title = "Show.S02E01.1080p.WEB-DL-GRP"

    {:ok, grab} = Catalog.create_grab("hash-no-scene", :torrent, [episode.id], title)
    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/dl/pack/Show.S02E01.1080p.mkv", 3_000_000_000}]}
    end)

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    refute Repo.get(Grab, grab.id)
    parked = Repo.get!(Episode, episode.id)
    assert parked.file_path == nil
    assert parked.grab_id == nil
    assert parked.search_attempts == 1
    assert Catalog.blocked_release_titles_for_series(series.id) == [title]
    refute Repo.get_by(GrabFile, grab_id: grab.id)
  end

  # Never-guess: a scene coordinate that shadows another episode's native code inside one grab
  # makes the file ambiguous — it must park, not be filed onto both episodes.
  test "a file claimed via both native and alternate numbering is parked instead of double-filing" do
    series =
      series_fixture(%{
        title: "Shadow",
        tvdb_id: 99,
        monitor_strategy: :all,
        media_profile: :standard,
        scene_numbering_group_id: "shadow-group"
      })

    season1 = season_fixture(series, %{season_number: 1})
    season2 = season_fixture(series, %{season_number: 2})
    bridged = episode(season1, 29)
    native = episode(season2, 1)

    assert {:ok, _} =
             Identity.replace_provider_coordinates(series, "tmdb", "shadow-group", "scene", [
               %{
                 scheme: "scene",
                 canonical_value: Episode.code(2, 1),
                 precedence: :inferred,
                 episode_ids: [bridged.id]
               }
             ])

    title = "Shadow.S02E01.1080p.WEB-DL-GRP"
    {:ok, grab} = Catalog.create_grab("hash-shadow", :torrent, [bridged.id, native.id], title)
    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/dl/pack/Shadow.S02E01.1080p.mkv", 3_000_000_000}]}
    end)

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    refute Repo.get(Grab, grab.id)

    for id <- [bridged.id, native.id] do
      ep = Repo.get!(Episode, id)
      assert ep.file_path == nil
      assert ep.grab_id == nil
      assert ep.search_attempts == 1
    end

    assert Catalog.blocked_release_titles_for_series(series.id) == [title]
    refute Repo.get_by(GrabFile, grab_id: grab.id)
  end

  test "searches an explicitly monitored Standard S00 special and grabs the matching release (Sonarr parity)" do
    {series, _season} = series_tree()
    specials = season_fixture(series, %{season_number: 0})
    e1 = episode(specials, 5)
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    # Confirms the season-0 group reaches the indexer with a sane {Season:0}-shaped query.
    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 0 ->
      {:ok,
       [
         %{
           title: "Show.S00E05.1080p.WEB-DL-GRP",
           size: 2_000_000_000,
           download_url: "u",
           seeders: 5
         }
       ]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-special"} end)

    assert :ok = TvPoller.poll()

    linked = Repo.get!(Episode, e1.id)
    assert linked.grab_id
    grab = Repo.get!(Grab, linked.grab_id)
    assert grab.download_id == "hash-special"
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

  # #274: a `"no_upgrade"` row bounds the UPGRADE sweep only. It says "this release does not beat
  # the files we already hold" — nothing about whether it is a good release for an episode holding
  # nothing, which is exactly the state these two are in. Hiding the season's best pack from the
  # wanted search for the janitor's whole retention window would be a real regression.
  test "a no_upgrade block does not hide the pack from the wanted-episode search" do
    {series, season} = series_tree()
    e1 = episode(season, 1)
    e2 = episode(season, 2)

    Repo.insert!(%BlockedRelease{
      release_title: "Show.S01.1080p.WEB-GRP",
      reason: "no_upgrade",
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
         }
       ]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn release, _opts -> {:ok, release.title} end)

    assert :ok = TvPoller.poll()

    assert Repo.get!(Episode, e1.id).grab_id
    assert Repo.get!(Episode, e2.id).grab_id

    # The pack still wins the cover, exactly as it would with no row at all.
    assert Repo.all(Grab) |> Enum.map(& &1.release_title) == ["Show.S01.1080p.WEB-GRP"]
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

  test "a failed upgrade download parks the grab but keeps the available episode and old files" do
    {series, season} = series_tree()
    old_file = "/tmp/cinder-test-tv-library/Show/old.mkv"
    old_part = "/tmp/cinder-test-tv-library/Show/old-part.mkv"

    episode =
      episode(season, 1, %{file_path: old_file, part_file_paths: [old_part]})

    {:ok, grab} =
      Catalog.create_grab("hash-upgrade-fail", :torrent, [episode.id], "Bad.Show.S01E01",
        allow_available: true
      )

    grab |> Ecto.Changeset.change(download_attempts: 9) |> Repo.update!()
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-upgrade-fail" ->
      {:ok, %{state: :error}}
    end)

    assert :ok = TvPoller.poll()
    refute Repo.get(Grab, grab.id)

    available = Repo.reload!(episode)
    assert available.file_path == old_file
    assert available.part_file_paths == [old_part]
    assert available.grab_id == nil
    assert Catalog.episode_state(available) == :available
    assert "Bad.Show.S01E01" in Catalog.blocked_release_titles_for_series(series.id)
  end

  test "the automatic sweep never creates an upgrade grab for an available episode" do
    {_series, season} = series_tree()
    episode = episode(season, 1, %{file_path: "/library/Show.S01E01.mkv"})
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    assert episode.id not in Enum.map(Catalog.wanted_episodes(), & &1.id)
    assert :ok = TvPoller.poll()
    assert Repo.reload!(episode).grab_id == nil
    assert Repo.all(Grab) == []
    assert Repo.all(Intent) == []
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

    stub(Cinder.Catalog.TMDBMock, :get_season, fn
      _, 1, "fr" ->
        {:ok, %{season_number: 1, episodes: []}}

      _, 1, "en" ->
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

  # #268 (Charmed S03): the sweep must band a season pack by the episodes it CONTAINS, not the
  # handful still wanted. This proves the poller supplies that count — the scorer's fallback is
  # inert without it, so the pack would be :out_of_band and the tail would park.
  test "grabs a season pack banded by the season's episode count when only the tail is wanted" do
    {series, season} = series_tree()
    Enum.each(1..18, &episode(season, &1, %{file_path: "/tv/Show - S01E#{pad2(&1)}.mkv"}))
    wanted = Enum.map(19..22, &episode(season, &1))

    # 4 GB/episode: the 4 wanted episodes budget 16 GB, but the 22-episode pack is 19.7 GB
    # (~0.9 GB/episode) — in band only once the pack's own episode count sizes it.
    Application.put_env(:cinder, :tv_max_size, 4_000_000_000)
    on_exit(fn -> Application.delete_env(:cinder, :tv_max_size) end)

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [%{title: "Show.S01.1080p.BluRay.x265-GRP", size: 19_700_000_000, download_url: "pack"}]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-pack"} end)

    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    assert :ok = TvPoller.poll()

    assert Catalog.count_episodes(series.id, 1) == 22
    grab_ids = Enum.map(wanted, &Repo.get!(Episode, &1.id).grab_id)
    assert [grab_id] = Enum.uniq(grab_ids)
    assert Repo.get!(Grab, grab_id).download_id == "hash-pack"
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
    {series, season} = series_tree()
    e1 = episode(season, 1)
    release_title = "Show.S01.Wrong.Audio.Pack"

    {:ok, grab} =
      Catalog.create_grab("hash-f", :torrent, [e1.id], release_title)

    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/dl/pack/Show.S01E99.mkv", 3_000_000_000}]}
    end)

    assert :ok = TvPoller.poll()
    assert_receive {:notify, {:grab_failed, %Grab{id: gid}, :no_files_matched}}
    assert gid == grab.id
    refute Repo.get(Grab, grab.id)
    assert Catalog.blocked_release_titles_for_series(series.id) == [release_title]
  end

  test "a parked grab emits [:cinder, :park] with kind: :episode and the park reason" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("hash-p", :torrent, [e1.id])
    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack2")
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, []} end)

    {result, events} =
      Cinder.TelemetryHelpers.capture([:cinder, :park], fn -> TvPoller.poll() end)

    assert result == :ok
    assert [{%{count: 1}, %{kind: :episode, reason: :no_files_matched}}] = events
  end

  describe "stall reaper" do
    alias Cinder.Download.StallReaper

    defp enable_reaper!(opts \\ []) do
      saved = Application.get_env(:cinder, StallReaper)

      Application.put_env(
        :cinder,
        StallReaper,
        Keyword.merge([enabled: true, stall_timeout: 0, no_seeders_timeout: 0], opts)
      )

      on_exit(fn ->
        if saved,
          do: Application.put_env(:cinder, StallReaper, saved),
          else: Application.delete_env(:cinder, StallReaper)
      end)
    end

    test "reaps a stalled 0-seeder grab: removes it (with data), blocklists :stalled, re-searches" do
      enable_reaper!()
      {series, season} = series_tree()
      e1 = episode(season, 3)

      {:ok, grab} =
        Catalog.create_grab("hash-tv-stall", :torrent, [e1.id], "Dead.Show.S01E03.1080p")

      test_pid = self()
      Cinder.TestNotifier.subscribe()

      stub(Cinder.Download.ClientMock, :status, fn "hash-tv-stall" ->
        {:ok, %{state: :downloading, progress: 0.0, speed: 0, seeders: 0}}
      end)

      stub(Cinder.Download.ClientMock, :remove, fn id, opts ->
        send(test_pid, {:removed, id, opts})
        :ok
      end)

      start_supervised!({TvPoller, interval: 60_000})
      assert :ok = TvPoller.poll()

      assert Repo.get(Grab, grab.id) == nil

      reaped = Repo.get!(Episode, e1.id)
      assert reaped.grab_id == nil
      assert reaped.search_attempts == 1
      assert Catalog.blocked_release_titles_for_series(series.id) == ["Dead.Show.S01E03.1080p"]

      assert_receive {:removed, "hash-tv-stall", opts}
      assert Keyword.get(opts, :delete_files) == true
      assert_receive {:notify, {:grab_failed, %Grab{id: gid}, :stalled}}
      assert gid == grab.id
    end

    test "reaps a wedged usenet grab (nil speed) once past the absolute cap" do
      # The torrent-only seed window can't touch a nil-speed usenet grab; the protocol-agnostic
      # absolute cap does. cap: 0 so the freshly-stalled grab is immediately past it.
      enable_reaper!(max_downloading_timeout: 0)
      {series, season} = series_tree()
      e1 = episode(season, 3)

      {:ok, grab} =
        Catalog.create_grab("hash-tv-wedged", :torrent, [e1.id], "Wedged.Show.S01E03.1080p")

      test_pid = self()

      stub(Cinder.Download.ClientMock, :status, fn "hash-tv-wedged" ->
        {:ok, %{state: :downloading, progress: 0.5, speed: nil}}
      end)

      stub(Cinder.Download.ClientMock, :remove, fn id, opts ->
        send(test_pid, {:removed, id, opts})
        :ok
      end)

      start_supervised!({TvPoller, interval: 60_000})
      assert :ok = TvPoller.poll()

      assert Repo.get(Grab, grab.id) == nil
      reaped = Repo.get!(Episode, e1.id)
      assert reaped.grab_id == nil
      assert Catalog.blocked_release_titles_for_series(series.id) == ["Wedged.Show.S01E03.1080p"]
      assert_receive {:removed, "hash-tv-wedged", _opts}
    end

    test "the absolute cap also reaps an upgrade grab without touching its live episode file" do
      enable_reaper!(
        stall_timeout: :timer.hours(2),
        no_seeders_timeout: :timer.hours(2),
        max_downloading_timeout: :timer.hours(24)
      )

      {_series, season} = series_tree()
      e1 = episode(season, 4, %{file_path: "/library/Show/Show.S01E04.mkv"})

      {:ok, grab} =
        Catalog.create_grab(
          "hash-tv-upgrade-stall",
          :torrent,
          [e1.id],
          "Wedged.Show.S01E04.Upgrade.1080p",
          allow_available: true
        )

      assert {:ok, tracked} =
               Catalog.update_grab_download_metrics(grab, %{
                 download_progress: 0.5,
                 download_speed: 1_024,
                 download_eta: 500
               })

      past = DateTime.add(Catalog.now(), -25, :hour)
      Repo.update_all(from(g in Grab, where: g.id == ^grab.id), set: [download_progress_at: past])
      tracked = Repo.get!(Grab, tracked.id)

      assert {:ok, jittered} =
               Catalog.update_grab_download_metrics(tracked, %{
                 download_progress: 0.5,
                 download_speed: 2_048,
                 download_eta: 400
               })

      assert jittered.download_progress_at == past

      stub(Cinder.Download.ClientMock, :status, fn "hash-tv-upgrade-stall" ->
        {:ok, %{state: :downloading, progress: 0.5, speed: 3_072, eta: 300, seeders: 5}}
      end)

      stub(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)

      start_supervised!({TvPoller, interval: 60_000})
      assert :ok = TvPoller.poll()

      assert Repo.get(Grab, grab.id) == nil

      assert %Episode{
               file_path: "/library/Show/Show.S01E04.mkv",
               grab_id: nil,
               search_attempts: 1
             } = Repo.get!(Episode, e1.id)
    end

    test "does not reap a grab while the reaper is disabled (the default)" do
      {_series, season} = series_tree()
      e1 = episode(season, 3)
      {:ok, grab} = Catalog.create_grab("hash-tv-off", :torrent, [e1.id], "R.S01E03")

      stub(Cinder.Download.ClientMock, :status, fn "hash-tv-off" ->
        {:ok, %{state: :downloading, progress: 0.0, speed: 0, seeders: 0}}
      end)

      start_supervised!({TvPoller, interval: 60_000})
      assert :ok = TvPoller.poll()

      assert %Grab{} = Repo.get(Grab, grab.id)
      assert Repo.all(BlockedRelease) == []
    end
  end

  describe "content policy" do
    setup do
      {series, season} = series_tree()
      e1 = episode(season, 4)
      {:ok, grab} = Catalog.create_grab("hash-tv-fake", :torrent, [e1.id], "Show.S01E04-FAKE")

      stub(Cinder.Download.ClientMock, :status, fn "hash-tv-fake" ->
        {:ok, %{state: :downloading, progress: 0.7, speed: 900_000, seeders: 12}}
      end)

      %{series: series, episode: e1, grab: grab}
    end

    test "a fake payload parks on the FIRST tick: removed, blocklisted, episodes re-search",
         ctx do
      test_pid = self()
      Cinder.TestNotifier.subscribe()

      expect(Cinder.Download.ClientMock, :files, fn "hash-tv-fake" ->
        {:ok, ["Show.S01E04/Show.S01E04.mkv.lnk"]}
      end)

      stub(Cinder.Download.ClientMock, :remove, fn id, opts ->
        send(test_pid, {:removed, id, opts})
        :ok
      end)

      start_supervised!({TvPoller, interval: 60_000})
      assert :ok = TvPoller.poll()

      # Parked without spending the attempt budget — nothing about the file list will change.
      refute Repo.get(Grab, ctx.grab.id)
      assert Repo.get!(Episode, ctx.episode.id).grab_id == nil
      assert Catalog.blocked_release_titles_for_series(ctx.series.id) == ["Show.S01E04-FAKE"]

      assert_receive {:removed, "hash-tv-fake", _opts}
      assert_receive {:notify, {:grab_failed, %Grab{}, :blocked_content}}
    end

    # As on the movie side: a fake is small enough to be :completed by the first tick, so the
    # :completed branch has to vet too or the payload reaches the importer.
    test "a fake caught only once COMPLETED is still rejected, never imported", ctx do
      test_pid = self()

      stub(Cinder.Download.ClientMock, :status, fn "hash-tv-fake" ->
        {:ok, %{state: :completed, content_path: "/dl/Show.S01E04"}}
      end)

      expect(Cinder.Download.ClientMock, :files, fn "hash-tv-fake" ->
        {:ok, ["Show.S01E04/Show.S01E04.mkv.lnk"]}
      end)

      stub(Cinder.Download.ClientMock, :remove, fn id, _opts ->
        send(test_pid, {:removed, id})
        :ok
      end)

      # No filesystem stubs: reaching the importer at all would raise UnexpectedCall.
      start_supervised!({TvPoller, interval: 60_000})
      assert :ok = TvPoller.poll()

      refute Repo.get(Grab, ctx.grab.id)
      assert Repo.get!(Episode, ctx.episode.id).file_path == nil
      assert Catalog.blocked_release_titles_for_series(ctx.series.id) == ["Show.S01E04-FAKE"]
      assert_receive {:removed, "hash-tv-fake"}
    end

    test "an ordinary release is tracked as usual", ctx do
      expect(Cinder.Download.ClientMock, :files, fn "hash-tv-fake" ->
        {:ok, ["Show.S01E04/Show.S01E04.mkv"]}
      end)

      start_supervised!({TvPoller, interval: 60_000})
      assert :ok = TvPoller.poll()

      assert %Grab{download_progress: 0.7} = Repo.get!(Grab, ctx.grab.id)
      assert Repo.all(BlockedRelease) == []
    end
  end
end
