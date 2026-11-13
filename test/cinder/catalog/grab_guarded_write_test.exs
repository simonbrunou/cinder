defmodule Cinder.Catalog.GrabGuardedWriteTest do
  # The grab writes on `Cinder.GuardedWrite` (#789): every grab verb announces its committed change
  # once, a claim that misses inside a frame rolls the frame back, and each verb keeps its own
  # refusal atom.
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Audit.AdminAudit
  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, Episode, Grab, GrabFile}
  alias Cinder.Repo

  setup :set_mox_global

  setup do
    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    %{series: series, season: season}
  end

  @residual %{
    relative_path: "extra.mkv",
    size: 10,
    device: 1,
    inode: 2,
    source: nil,
    scheme: nil,
    namespace: nil,
    canonical_value: nil
  }

  @issue %{
    "version" => 1,
    "reason" => "unresolved_file",
    "relative_paths" => ["Season 1/Show - 01.mkv"],
    "candidate_episode_ids" => []
  }

  describe "a committed grab change announces its series once" do
    test "a verification hold", %{series: series, season: season} do
      grab = downloaded_grab(season)
      announced_once(series, fn -> {:ok, _held} = Catalog.hold_grab_verification(grab) end)
    end

    # Every episode of a season pack leads to the same series.
    test "a verification hold on a season pack", %{series: series, season: season} do
      grab = downloaded_grab(season, 3)
      assert length(grab.episodes) == 3
      announced_once(series, fn -> {:ok, _held} = Catalog.hold_grab_verification(grab) end)
    end

    test "a season pack's creation", %{series: series, season: season} do
      episode_ids = [ep(season), ep(season)]

      announced_once(series, fn ->
        {:ok, _grab} =
          Catalog.create_grab("pack-#{System.unique_integer()}", :torrent, episode_ids)
      end)
    end

    test "a verification retry", %{series: series, season: season} do
      held = held_grab(season)
      announced_once(series, fn -> {:ok, _retried} = Catalog.retry_grab_verification(held) end)
    end

    test "a mapping retry", %{series: series, season: season} do
      held = mapping_grab(season)
      announced_once(series, fn -> {:ok, _retried} = Catalog.retry_grab_mapping(held) end)
    end

    test "an import anyway, which also writes its audit row", %{series: series, season: season} do
      held = held_grab(season)
      admin = Cinder.AccountsFixtures.admin_fixture()

      announced_once(series, fn ->
        {:ok, released} = Catalog.import_grab_anyway(held, admin)
        assert %Grab{mapping_status: :resolved, verification_waived: true} = released
      end)

      assert %Grab{verification_waived: true, download_attempts: 0} = Repo.get!(Grab, held.id)
    end

    test "a cancel", %{series: series, season: season} do
      grab = downloaded_grab(season)
      announced_once(series, fn -> {:ok, _deleted} = Catalog.cancel_grab(grab) end)
    end

    test "a mapping discard", %{series: series, season: season} do
      held = mapping_grab(season)
      announced_once(series, fn -> {:ok, _deleted} = Catalog.cancel_mapping_grab(held) end)
    end

    test "a stall reap", %{series: series, season: season} do
      {:ok, grab} = Catalog.create_grab("reap-#{System.unique_integer()}", :torrent, [ep(season)])
      announced_once(series, fn -> {:ok, _reaped} = Catalog.reap_stalled_grab(grab) end)
    end

    test "a policy rejection", %{series: series, season: season} do
      grab = policy_grab(season, "[Group] Show S01E01", %{"version" => 1})

      announced_once(series, fn ->
        {:ok, _deleted} = Catalog.reject_grab_release(grab, evidence())
      end)
    end

    # The grab survives with its imported episode still linked: the grab claim and the episode
    # write share the frame, and only the episode write announces.
    test "an import that leaves residual files open", %{series: series, season: season} do
      grab = downloaded_grab(season)
      [episode] = grab.episodes

      announced_once(series, fn ->
        {:ok, :open, _grab} =
          Catalog.commit_grab_imports(grab, [{episode.id, "/tv/Show/E01.mkv", nil}], [@residual])
      end)

      assert %Episode{file_path: "/tv/Show/E01.mkv", grab_id: grab_id} = Repo.reload!(episode)
      assert grab_id == grab.id
    end

    test "an import of residual files only", %{series: series, season: season} do
      grab = downloaded_grab(season)

      announced_once(series, fn ->
        {:ok, :open, _grab} = Catalog.commit_grab_imports(grab, [], [@residual])
      end)
    end

    test "a clean import that closes the grab", %{series: series, season: season} do
      grab = downloaded_grab(season)
      [episode] = grab.episodes

      announced_once(series, fn ->
        {:ok, :closed, _grab} =
          Catalog.commit_grab_imports(grab, [{episode.id, "/tv/Show/E01.mkv", nil}], [])
      end)
    end

    test "a close once every residual is decided", %{series: series, season: season} do
      grab = downloaded_grab(season)
      grab |> residual_file() |> Ecto.Changeset.change(decision: :fold) |> Repo.update!()
      announced_once(series, fn -> {:ok, :closed, _grab} = Catalog.close_grab(grab) end)
    end

    test "a fold decision on a residual file", %{series: series, season: season} do
      grab = downloaded_grab(season)
      file = residual_file(grab)
      [episode] = grab.episodes

      announced_once(series, fn ->
        {:ok, :decided, _file} = Catalog.decide_grab_file(file, episode, :fold, nil)
      end)
    end

    test "a discard decision on a residual file", %{series: series, season: season} do
      grab = downloaded_grab(season)
      file = residual_file(grab)
      announced_once(series, fn -> {:ok, :decided, _file} = Catalog.discard_grab_file(file) end)
    end
  end

  # The grab_files decision is written before the grab claim: the claim's miss must take it back.
  describe "a grab claim that misses inside a frame rolls the frame back" do
    test "a discard decision on a grab held since", %{series: series, season: season} do
      grab = downloaded_grab(season)
      file = residual_file(grab)
      set_grab(grab, mapping_status: :verification_blocked)
      series_id = series.id
      Catalog.subscribe_series()

      assert Catalog.discard_grab_file(file) == {:error, :stale_grab}
      assert %GrabFile{decision: nil} = Repo.reload!(file)
      refute_received {:series_updated, ^series_id}
    end

    test "a fold decision on a grab whose download moved", %{season: season} do
      grab = downloaded_grab(season)
      file = residual_file(grab)
      [episode] = grab.episodes
      set_grab(grab, mapping_status: :needs_mapping)

      assert Catalog.decide_grab_file(file, episode, :fold, nil) == {:error, :stale_grab}
      assert %GrabFile{decision: nil, episode_id: nil} = Repo.reload!(file)
    end
  end

  describe "an action offered for the caller's grab refuses a row that moved underneath" do
    test "verification retry", %{season: season} do
      held = held_grab(season)
      moved = set_grab(held, mapping_status: :resolved)

      assert Catalog.retry_grab_verification(held) == {:error, :verification_not_held}
      assert Repo.get!(Grab, held.id) == moved
    end

    test "mapping retry", %{season: season} do
      held = mapping_grab(season)
      moved = set_grab(held, mapping_status: :resolved)

      assert Catalog.retry_grab_mapping(held) == {:error, :mapping_not_held}
      assert Repo.get!(Grab, held.id) == moved
    end

    test "import anyway commits no audit row", %{season: season} do
      held = held_grab(season)
      moved = set_grab(held, mapping_status: :resolved)
      admin = Cinder.AccountsFixtures.admin_fixture()

      assert Catalog.import_grab_anyway(held, admin) == {:error, :verification_not_held}
      assert Repo.get!(Grab, held.id) == moved
      refute Repo.exists?(from a in AdminAudit, where: a.action == "import_grab_anyway")
    end

    test "mapping discard", %{season: season} do
      held = mapping_grab(season)
      moved = set_grab(held, mapping_status: :resolved)

      assert Catalog.cancel_mapping_grab(held) == {:error, :mapping_not_held}
      assert Repo.get!(Grab, held.id) == moved
    end

    test "an import or close of a grab whose download path changed", %{season: season} do
      grab = downloaded_grab(season)
      [episode] = grab.episodes
      moved = set_grab(grab, content_path: "/downloads/elsewhere")

      assert Catalog.commit_grab_imports(grab, [{episode.id, "/tv/E01.mkv", nil}], [@residual]) ==
               {:error, :stale_grab}

      assert Catalog.close_grab(grab) == {:error, :stale_grab}
      assert Repo.get!(Grab, grab.id) == moved
      assert %Episode{file_path: nil} = Repo.reload!(episode)
      refute Repo.exists?(GrabFile)
    end

    test "verification hold after another attempt was counted", %{season: season} do
      grab = downloaded_grab(season)
      moved = set_grab(grab, download_attempts: 1)

      assert Catalog.hold_grab_verification(grab) == {:error, :stale_grab}
      assert Repo.get!(Grab, grab.id) == moved
    end

    test "a cancel of a grab already gone succeeds, and a reap of one is stale", %{season: season} do
      grab = downloaded_grab(season)
      Repo.delete!(grab)

      assert Catalog.cancel_grab(grab) == {:ok, grab}
      assert Catalog.reap_stalled_grab(grab) == {:error, :stale_grab}
    end
  end

  # Before #789, a nil value in these guards raised Ecto's "comparing with nil is forbidden"; the
  # guarded write refuses it with the verb's own atom and writes nothing.
  describe "a guard on an unset value refuses" do
    test "an import or close of a grab still downloading", %{season: season} do
      {:ok, grab} = Catalog.create_grab("dl-#{System.unique_integer()}", :torrent, [ep(season)])
      grab = Repo.preload(grab, :episodes)
      [episode] = grab.episodes

      assert Catalog.commit_grab_imports(grab, [{episode.id, "/tv/E01.mkv", nil}], [@residual]) ==
               {:error, :stale_grab}

      assert Catalog.close_grab(grab) == {:error, :stale_grab}
      assert Catalog.hold_grab_verification(grab) == {:error, :stale_grab}
      assert Repo.get!(Grab, grab.id).mapping_status == :resolved
      assert %Episode{file_path: nil, grab_id: grab_id} = Repo.reload!(episode)
      assert grab_id == grab.id
      refute Repo.exists?(GrabFile)
    end

    test "a policy rejection of a grab with no policy snapshot or no release title", %{
      season: season
    } do
      for {title, snapshot} <- [{"[Group] Show S01E01", nil}, {nil, %{"version" => 1}}] do
        grab = policy_grab(season, title, snapshot)

        assert Catalog.reject_grab_release(grab, evidence()) == {:error, :stale_release}
        assert Repo.get(Grab, grab.id)
      end

      refute Repo.exists?(BlockedRelease)
    end
  end

  test "the grab transition changeset casts only the fields a guarded grab write names" do
    changeset =
      Grab.transition_changeset(%Grab{}, %{
        mapping_status: :needs_mapping,
        verification_waived: true,
        download_attempts: 2,
        content_path: "/downloads/x",
        download_progress: 0.5,
        mapping_issue: @issue
      })

    assert changeset.changes == %{
             mapping_status: :needs_mapping,
             verification_waived: true,
             download_attempts: 2
           }
  end

  defp announced_once(series, fun) do
    series_id = series.id
    Catalog.subscribe_series()
    fun.()
    assert_receive {:series_updated, ^series_id}
    refute_received {:series_updated, ^series_id}
  end

  defp ep(season),
    do: episode_fixture(season, episode_number: System.unique_integer([:positive])).id

  defp downloaded_grab(season, episodes \\ 1) do
    episode_ids = for _ <- 1..episodes, do: ep(season)
    {:ok, grab} = Catalog.create_grab("hash-#{System.unique_integer()}", :torrent, episode_ids)
    {:ok, _grab} = Catalog.mark_grab_downloaded(grab, "/downloads/#{grab.download_id}")
    Enum.find(Catalog.list_grabs_downloaded(), &(&1.id == grab.id))
  end

  defp held_grab(season) do
    {:ok, held} = season |> downloaded_grab() |> Catalog.hold_grab_verification()
    held
  end

  defp mapping_grab(season) do
    {:ok, held} =
      season
      |> downloaded_grab()
      |> Catalog.record_mapping_result({:needs_mapping, %{issue: @issue}})

    held
  end

  defp residual_file(grab) do
    Repo.insert!(%GrabFile{
      grab_id: grab.id,
      relative_path: "extra.mkv",
      size: 1,
      device: 1,
      inode: 2
    })
  end

  defp set_grab(grab, set) do
    Repo.update_all(from(g in Grab, where: g.id == ^grab.id), set: set)
    Repo.get!(Grab, grab.id)
  end

  defp policy_grab(season, release_title, snapshot) do
    episode_id = ep(season)

    grab =
      Repo.insert!(%Grab{
        download_id: "policy-#{System.unique_integer()}",
        download_protocol: :torrent,
        release_title: release_title,
        content_path: "/downloads/policy",
        mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => [episode_id]},
        release_policy_snapshot: snapshot,
        mapping_status: :resolved
      })

    Repo.update_all(from(e in Episode, where: e.id == ^episode_id), set: [grab_id: grab.id])
    Repo.preload(grab, :episodes)
  end

  defp evidence, do: %{source: "Show.S01E01.mkv", missing_audio: ["fr"]}
end
