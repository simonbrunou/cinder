defmodule Cinder.Download.IntentTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Acquisition.{Anime, Release}
  alias Cinder.Catalog
  alias Cinder.Catalog.{Grab, Movie}
  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Download.IntentEpisode
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  setup :set_mox_global
  setup :verify_on_exit!

  # Anime preferences are global-only (no per-title override) — a test needing a non-default
  # policy overrides the global settings env for its duration and restores it on exit.
  defp set_anime_defaults!(overrides) do
    saved = Application.fetch_env!(:cinder, :anime_preferences)
    Application.put_env(:cinder, :anime_preferences, Keyword.merge(saved, overrides))
    on_exit(fn -> Application.put_env(:cinder, :anime_preferences, saved) end)
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

  test "policy reservation validates the exact bounded v1 document and keeps it immutable" do
    title = "[SubsPlease] Show [1080p]"
    snapshot = release_policy_snapshot(title)

    attrs = %{
      operation_key: Ecto.UUID.generate(),
      kind: :movie,
      target_id: 42,
      episode_ids: [],
      protocol: :torrent,
      release: %{"title" => title},
      status: :reserved,
      release_policy_snapshot: snapshot
    }

    assert Intent.reservation_changeset(%Intent{}, attrs).valid?

    invalid = [
      Map.put(snapshot, "version", 2),
      Map.put(snapshot, "required_audio_languages", "ja"),
      Map.put(snapshot, "required_embedded_subtitle_languages", "fr"),
      Map.put(snapshot, "required_audio_languages", [""]),
      Map.put(snapshot, "required_audio_languages", [42]),
      Map.put(snapshot, "required_audio_languages", ["JA"]),
      Map.put(snapshot, "required_audio_languages", ["ja", "ja"]),
      Map.put(snapshot, "release_group", " SubsPlease "),
      Map.put(snapshot, "release_group", 42),
      Map.put(snapshot, "release_title", "Another.Release"),
      Map.put(snapshot, "provenance", %{"source" => "settings"})
    ]

    for malformed <- invalid do
      refute Intent.reservation_changeset(
               %Intent{},
               %{attrs | release_policy_snapshot: malformed}
             ).valid?
    end

    assert {:ok, intent} = %Intent{} |> Intent.reservation_changeset(attrs) |> Repo.insert()

    ignored = Intent.changeset(intent, %{release_policy_snapshot: nil})
    refute get_change(ignored, :release_policy_snapshot)
    assert {:ok, unchanged} = Repo.update(ignored)
    assert unchanged.release_policy_snapshot == snapshot

    immutable =
      Intent.reservation_changeset(unchanged, %{release_policy_snapshot: snapshot})

    assert "is immutable" in errors_on(immutable).release_policy_snapshot
  end

  test "reservation requires explicit policy evidence equal to the selected release marker" do
    snapshot = release_policy_snapshot("Marked.Anime")

    release = %Release{
      title: "Marked.Anime",
      download_url: "magnet:?marked-anime",
      protocol: :torrent,
      release_policy_snapshot: snapshot
    }

    attrs = %{
      kind: :movie,
      target_id: 42,
      episode_ids: [],
      protocol: :torrent,
      release: release
    }

    assert {:error, :invalid_release_evidence} = Download.reserve_intent(attrs)

    assert {:error, :invalid_release_evidence} =
             Download.reserve_intent(
               Map.put(attrs, :release_policy_snapshot, %{snapshot | "release_group" => "other"})
             )

    assert {:ok, intent} =
             Download.reserve_intent(Map.put(attrs, :release_policy_snapshot, snapshot))

    assert intent.release_policy_snapshot == snapshot
  end

  test "manual Anime movie and episode grabs freeze policy before reservation" do
    set_anime_defaults!(audio_mode: :dual, embedded_subtitle_mode: :require)
    set_anime_subtitle_languages!("fr")

    movie =
      movie_fixture(%{
        status: :no_match,
        media_profile: :anime,
        original_language: "ja",
        preferred_language: "french"
      })

    movie_release =
      %Release{
        title: "[SubsPlease] Manual.Movie [1080p]",
        download_url: "magnet:?manual-anime-movie",
        protocol: :torrent,
        group: "SubsPlease"
      }

    expect(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      {:ok, "hash-manual-anime-movie"}
    end)

    assert {:ok, %Movie{} = downloading} = Download.grab_movie(movie, movie_release)

    assert downloading.release_policy_snapshot == %{
             "version" => 1,
             "required_audio_languages" => ["ja", "fr"],
             "required_embedded_subtitle_languages" => ["fr"],
             "release_group" => "subsplease",
             "release_title" => movie_release.title
           }

    fixture = anime_reservation_fixture()
    refute fixture.release.release_policy_snapshot

    expect(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      {:ok, "hash-manual-anime-episodes"}
    end)

    assert {:ok, %Grab{} = grab} =
             Download.grab_episodes(fixture.release, [fixture.first.id, fixture.second.id])

    assert grab.release_policy_snapshot["version"] == 1
    assert grab.release_policy_snapshot["release_title"] == fixture.release.title
  end

  test "episode boundary rejects missing or mixed-series IDs before client I/O" do
    first_series = series_fixture(%{media_profile: :anime})
    second_series = series_fixture(%{media_profile: :anime})
    first = episode_fixture(season_fixture(first_series))
    second = episode_fixture(season_fixture(second_series))
    release = release("Mixed.Show")

    assert {:error, :episode_series_mismatch} =
             Download.grab_episodes(release, [first.id, second.id])

    assert {:error, :episode_series_mismatch} =
             Download.grab_episodes(release, [first.id, -1])

    assert Repo.aggregate(Intent, :count) == 0
    assert Repo.aggregate(Grab, :count) == 0
  end

  test "direct incomplete episodic intent is rejected before restart reconciliation client I/O" do
    series = series_fixture(%{monitor_strategy: :all})
    episode = episode_fixture(season_fixture(series))

    assert_invalid_episode_intent_rejected([episode.id, -1], [episode])
  end

  test "direct mixed-series intent is rejected before restart reconciliation client I/O" do
    first = episode_fixture(season_fixture(series_fixture(%{monitor_strategy: :all})))
    second = episode_fixture(season_fixture(series_fixture(%{monitor_strategy: :all})))

    assert_invalid_episode_intent_rejected([first.id, second.id], [first, second])
  end

  test "direct incomplete episodic intent is rejected before submit client I/O" do
    series = series_fixture(%{monitor_strategy: :all})
    episode = episode_fixture(season_fixture(series))

    assert_invalid_episode_intent_rejected(
      [episode.id, -1],
      [episode],
      &Download.submit_intent/1
    )
  end

  test "direct mixed-series intent is rejected before submit client I/O" do
    first = episode_fixture(season_fixture(series_fixture(%{monitor_strategy: :all})))
    second = episode_fixture(season_fixture(series_fixture(%{monitor_strategy: :all})))

    assert_invalid_episode_intent_rejected(
      [first.id, second.id],
      [first, second],
      &Download.submit_intent/1
    )
  end

  test "Standard movie and TV reservations and owners keep policy nil" do
    movie = movie_fixture(%{status: :no_match, media_profile: :standard})

    expect(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      {:ok, "hash-standard-movie-policy"}
    end)

    assert {:ok, %Movie{release_policy_snapshot: nil}} =
             Download.grab_movie(movie, release("Standard.Movie"))

    series = series_fixture(%{monitor_strategy: :all, media_profile: :standard})
    episode = episode_fixture(season_fixture(series))

    expect(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      {:ok, "hash-standard-tv-policy"}
    end)

    assert {:ok, %Grab{release_policy_snapshot: nil}} =
             Download.grab_episodes(release("Standard.Show.S01E01"), [episode.id])

    assert {:ok, %Intent{release_policy_snapshot: nil}} =
             Download.reserve_intent(%{
               kind: :movie,
               target_id: 123_456,
               episode_ids: [],
               protocol: :torrent,
               release: release("Standard.Intent")
             })

    retryable = movie_fixture(%{status: :no_match})

    assert {:ok, retryable} =
             Catalog.transition(retryable, %{
               status: :no_match,
               release_policy_snapshot: release_policy_snapshot("Stale.Release")
             })

    assert {:ok, %Movie{release_policy_snapshot: nil}} = Catalog.retry_movie(retryable)
  end

  test "episodic reservation persists an immutable snapshot after Catalog evidence changes" do
    fixture = anime_reservation_fixture()

    assert {:ok, intent} = reserve_anime_intent(fixture)
    assert Repo.reload(intent).mapping_snapshot == fixture.snapshot

    assert Enum.map(Repo.all(IntentEpisode), & &1.episode_id) |> Enum.sort() ==
             Enum.sort([fixture.first.id, fixture.second.id])

    Repo.delete!(fixture.coordinate)
    assert Repo.reload(intent).mapping_snapshot == fixture.snapshot

    ignored = Intent.changeset(intent, %{mapping_snapshot: %{"version" => 999}})
    refute get_change(ignored, :mapping_snapshot)
    assert {:ok, unchanged} = Repo.update(ignored)
    assert unchanged.mapping_snapshot == fixture.snapshot

    immutable = Intent.reservation_changeset(unchanged, %{mapping_snapshot: fixture.snapshot})
    assert "is immutable" in errors_on(immutable).mapping_snapshot
  end

  test "reservation rejects mismatched markers and malformed snapshots explicitly" do
    fixture = anime_reservation_fixture()

    assert {:error, :invalid_mapping_snapshot} =
             Download.reserve_intent(%{
               kind: :season_pack,
               target_id: fixture.first.id,
               episode_ids: [fixture.first.id, fixture.second.id],
               protocol: :torrent,
               release: %{fixture.release | mapping_snapshot: nil},
               mapping_snapshot: fixture.snapshot
             })

    assert {:error, :invalid_mapping_snapshot} =
             Download.reserve_intent(%{
               kind: :season_pack,
               target_id: fixture.first.id,
               episode_ids: [fixture.first.id, fixture.second.id],
               protocol: :torrent,
               release: fixture.release,
               mapping_snapshot: nil
             })

    for {label, invalid} <- invalid_snapshots(fixture.snapshot) do
      marked = %{fixture.release | mapping_snapshot: invalid}

      assert {:error, :invalid_mapping_snapshot} =
               Download.reserve_intent(%{
                 kind: :season_pack,
                 target_id: fixture.first.id,
                 episode_ids: [fixture.first.id, fixture.second.id],
                 protocol: :torrent,
                 release: marked,
                 mapping_snapshot: invalid
               }),
             label
    end

    movie = movie_fixture()

    assert {:error, :invalid_mapping_snapshot} =
             Download.reserve_intent(%{
               kind: :movie,
               target_id: movie.id,
               episode_ids: [],
               protocol: :torrent,
               release: fixture.release,
               mapping_snapshot: fixture.snapshot
             })

    assert Repo.aggregate(Intent, :count) == 0
    assert Repo.aggregate(IntentEpisode, :count) == 0
  end

  test "reservation rejects invalid version-two parser contexts" do
    fixture = anime_reservation_fixture()

    snapshot =
      fixture.snapshot
      |> Map.put("version", 2)
      |> Map.put("parser_context", %{
        "title" => "Frieren",
        "aliases" => [],
        "year" => 2023
      })

    for invalid_context <- [
          nil,
          %{},
          %{"title" => "", "aliases" => [], "year" => 2023},
          %{"title" => "Frieren", "aliases" => [42], "year" => 2023},
          %{"title" => "Frieren", "aliases" => List.duplicate("alias", 8), "year" => 2023},
          %{"title" => "Frieren", "aliases" => [], "year" => "2023"}
        ] do
      attrs =
        valid_anime_intent_attrs(fixture, put_in(snapshot["parser_context"], invalid_context))

      refute Intent.reservation_changeset(%Intent{}, attrs).valid?
    end
  end

  test "grab_episodes submits a snapshot release and creates one exact-all grab" do
    fixture = anime_reservation_fixture()

    expect(Cinder.Download.ClientMock, :add, fn release, _opts ->
      assert release.title == fixture.release.title
      {:ok, "hash-anime-exact-all"}
    end)

    assert {:ok, %Grab{} = grab} =
             Download.grab_episodes(fixture.release, [fixture.first.id, fixture.second.id])

    assert grab.mapping_snapshot == fixture.snapshot

    assert grab
           |> Repo.preload(:episodes)
           |> Map.fetch!(:episodes)
           |> Enum.map(& &1.id)
           |> Enum.sort() ==
             Enum.sort([fixture.first.id, fixture.second.id])

    assert Repo.aggregate(Intent, :count) == 0
    assert Repo.aggregate(IntentEpisode, :count) == 0
  end

  test "snapshot ownership conflict leaves the remote download fenced for cleanup" do
    fixture = anime_reservation_fixture()
    assert {:ok, intent} = reserve_anime_intent(fixture)

    submitted =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-anime-conflict"})
      |> Repo.update!()

    assert {:ok, other} =
             Catalog.create_grab("hash-other-owner", :torrent, [fixture.second.id])

    expect(Cinder.Download.ClientMock, :remove, fn "hash-anime-conflict", delete_files: true ->
      {:error, :timeout}
    end)

    assert {:error, :no_episodes_linked} = Download.reconcile_intent(submitted)

    assert %Intent{status: :cleanup_pending, remote_id: "hash-anime-conflict"} =
             Repo.get!(Intent, submitted.id)

    assert Repo.reload(fixture.first).grab_id == nil
    assert Repo.reload(fixture.second).grab_id == other.id
    refute Repo.get_by(Grab, download_id: "hash-anime-conflict")
  end

  test "episode reservation copies policy atomically through intent to grab" do
    fixture = anime_reservation_fixture()
    policy = release_policy_snapshot(fixture.release.title)
    release = %{fixture.release | release_policy_snapshot: policy}

    assert {:ok, intent} =
             Download.reserve_intent(%{
               kind: :season_pack,
               target_id: fixture.first.id,
               episode_ids: [fixture.first.id, fixture.second.id],
               protocol: :torrent,
               release: release,
               mapping_snapshot: fixture.snapshot,
               release_policy_snapshot: policy
             })

    assert intent.release_policy_snapshot == policy

    submitted =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-policy-atomic-grab"})
      |> Repo.update!()

    assert {:ok, %Grab{} = grab} = Download.reconcile_intent(submitted)
    assert grab.mapping_snapshot == fixture.snapshot
    assert grab.release_policy_snapshot == policy
    refute Repo.get(Intent, intent.id)
  end

  test "movie attach stores policy with remote ownership and stale status stores neither" do
    snapshot = release_policy_snapshot("[SubsPlease] Movie [1080p]")

    release = %Release{
      title: snapshot["release_title"],
      download_url: "magnet:?policy-atomic-movie",
      protocol: :torrent,
      release_policy_snapshot: snapshot
    }

    movie = movie_fixture()

    assert {:ok, intent} =
             reserve_marked_movie_intent(movie, release, snapshot, "hash-policy-atomic-movie")

    assert {:ok, %Movie{} = downloading} = Download.reconcile_intent(intent)
    assert downloading.download_id == "hash-policy-atomic-movie"
    assert downloading.release_policy_snapshot == snapshot

    cancelled = movie_fixture()

    assert {:ok, stale} =
             reserve_marked_movie_intent(cancelled, release, snapshot, "hash-policy-stale-movie")

    assert {:ok, _cancelled} = Catalog.transition(cancelled, %{status: :cancelled})

    expect(Cinder.Download.ClientMock, :remove, fn "hash-policy-stale-movie", _opts -> :ok end)

    assert {:error, :stale_target} = Download.reconcile_intent(stale)
    refute Repo.get!(Movie, cancelled.id).release_policy_snapshot
    refute Repo.get(Intent, stale.id)
  end

  test "reserve_intent/1 generates a unique key and stores only resubmission fields" do
    release = %Release{
      title: "Movie.1080p.WEB-GRP",
      size: 8_000_000_000,
      download_url: "magnet:?xt=urn:btih:abc",
      protocol: :torrent,
      codec: "x264"
    }

    assert {:ok, intent} =
             Download.reserve_intent(%{
               kind: :movie,
               target_id: 42,
               episode_ids: [],
               protocol: :torrent,
               release: release
             })

    assert {:ok, _uuid} = Ecto.UUID.cast(intent.operation_key)
    assert intent.status == :reserved
    assert intent.remote_id == nil

    assert intent.release["title"] == "Movie.1080p.WEB-GRP"
    refute inspect(intent.release) =~ "magnet:?xt=urn:btih:abc"

    assert {:ok, ciphertext} = Base.decode64(intent.release["download_url_ciphertext"])
    assert {:ok, "magnet:?xt=urn:btih:abc"} = Cinder.Vault.decrypt(ciphertext)
  end

  test "operation keys are unique" do
    attrs = %{
      operation_key: Ecto.UUID.generate(),
      kind: :movie,
      target_id: 42,
      episode_ids: [],
      protocol: :torrent,
      release: %{"title" => "R", "download_url" => "magnet:?x"}
    }

    assert {:ok, _} = %Intent{} |> Intent.changeset(attrs) |> Repo.insert()

    assert {:error, changeset} =
             %Intent{} |> Intent.changeset(%{attrs | target_id: 43}) |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).operation_key
  end

  test "source-origin provenance survives durable reservation and submission" do
    movie = movie_fixture(%{status: :searching})

    release = %Release{
      title: "Movie.1080p.WEB-GRP",
      download_url: "http://prowlarr:9696/download/1",
      download_url_origin: "http://prowlarr:9696",
      protocol: :torrent
    }

    assert {:ok, intent} = reserve_movie_intent(movie.id, release)
    assert intent.release["download_url_origin"] == "http://prowlarr:9696"

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)

    expect(Cinder.Download.ClientMock, :add, fn submitted, _opts ->
      assert submitted.download_url_origin == "http://prowlarr:9696"
      {:ok, "hash-provenance"}
    end)

    assert {:ok, %{download_id: "hash-provenance"}} = Download.reconcile_intent(intent)
  end

  test "concurrent reservations allow only one intent for the same movie" do
    movie = movie_fixture(%{status: :searching})
    release = release("Movie.A")

    results = concurrently(fn -> reserve_movie_intent(movie.id, release) end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :download_intent_busy})) == 1
    assert Repo.aggregate(Intent, :count) == 1
  end

  test "concurrent reservations reject overlapping TV episode assignments" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    e1 = episode_fixture(season, %{episode_number: 1})
    e2 = episode_fixture(season, %{episode_number: 2})
    e3 = episode_fixture(season, %{episode_number: 3})

    results =
      concurrently(
        fn -> reserve_episode_intent([e1.id, e2.id], release("Pack.A")) end,
        fn -> reserve_episode_intent([e2.id, e3.id], release("Pack.B")) end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :download_intent_busy})) == 1
    assert Repo.aggregate(IntentEpisode, :count) == 2
  end

  test "submit_intent serializes lookup through remote-id persistence" do
    movie = movie_fixture(%{status: :searching})
    {:ok, intent} = reserve_movie_intent(movie.id)
    parent = self()

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key ->
      send(parent, {:lookup, self()})
      receive do: (:continue -> :not_found)
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-single"} end)

    first = Task.async(fn -> Download.submit_intent(intent) end)
    assert_receive {:lookup, first_pid}
    second = Task.async(fn -> Download.submit_intent(intent) end)

    second_lookup =
      receive do
        {:lookup, pid} -> pid
      after
        150 -> nil
      end

    send(first_pid, :continue)
    if second_lookup, do: send(second_lookup, :continue)
    Task.await(first)
    Task.await(second)

    assert second_lookup == nil
  end

  test "permanent pre-submission errors release the intent and TV reservations" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    {:ok, intent} = reserve_episode_intent([episode.id], release("Bad"))

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> :not_found end)

    expect(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      {:error, :unsupported_download_url}
    end)

    assert {:error, :unsupported_download_url} = Download.reconcile_intent(intent)
    refute Repo.get(Intent, intent.id)
    assert Repo.all(IntentEpisode) == []

    assert {:ok, _replacement} = reserve_episode_intent([episode.id], release("Replacement"))
  end

  test "invalid encrypted payload releases a pre-submission intent" do
    movie = movie_fixture(%{status: :searching})
    {:ok, intent} = reserve_movie_intent(movie.id)
    intent = intent |> Intent.changeset(%{release: %{"title" => "broken"}}) |> Repo.update!()

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> :not_found end)

    assert {:error, :invalid_intent_release} = Download.reconcile_intent(intent)
    refute Repo.get(Intent, intent.id)
  end

  test "transient submission errors retain the key with bounded retry metadata" do
    movie = movie_fixture(%{status: :searching})
    {:ok, intent} = reserve_movie_intent(movie.id)
    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Download.reconcile_intent(intent)
    saved = Repo.get!(Intent, intent.id)
    assert saved.attempt_count == 1
    assert DateTime.after?(saved.next_attempt_at, DateTime.utc_now())
    assert saved.last_error == ":timeout"

    assert {:error, :intent_backoff} = Download.reconcile_intent(saved)
    assert Repo.get!(Intent, intent.id).attempt_count == 1

    due =
      saved
      |> Intent.changeset(%{attempt_count: 100, next_attempt_at: nil})
      |> Repo.update!()

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ ->
      {:error, {:http_error, "https://user:secret@example.test"}}
    end)

    before_retry = DateTime.utc_now(:second)

    assert {:error, {:http_error, _secret}} = Download.reconcile_intent(due)
    capped = Repo.get!(Intent, intent.id)
    assert capped.attempt_count == 101
    assert DateTime.diff(capped.next_attempt_at, before_retry, :second) in 299..300
    assert capped.last_error == ":http_error"
    refute capped.last_error =~ "secret"
  end

  test "a committed movie retry generation is charged once across crash replay" do
    movie = movie_fixture(%{status: :searching})
    {:ok, movie} = Catalog.transition(movie, %{status: :searching, search_attempts: 3})
    {:ok, intent} = reserve_movie_intent(movie.id)

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> {:error, :timeout} end)

    # A caller may die as soon as reconcile_intent/1 returns. The intent generation and
    # movie budget therefore have to be committed before control returns to that caller.
    assert {:error, :timeout} = Download.reconcile_intent(intent)
    assert Repo.get!(Intent, intent.id).attempt_count == 1
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).search_attempts == 4

    # Replaying recovery while that persisted generation is in backoff cannot charge it again.
    assert :ok = Download.reconcile_pending_intents([:movie])
    assert Repo.get!(Intent, intent.id).attempt_count == 1
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).search_attempts == 4
  end

  test "concurrent reconciliation charges one movie attempt for one intent generation" do
    movie = movie_fixture(%{status: :searching})
    {:ok, movie} = Catalog.transition(movie, %{status: :searching, search_attempts: 3})
    {:ok, intent} = reserve_movie_intent(movie.id)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _ ->
      Agent.update(calls, &(&1 + 1))
      {:error, :timeout}
    end)

    assert [first, second] = concurrently(fn -> Download.reconcile_intent(intent) end)

    assert Enum.sort([first, second]) ==
             Enum.sort([{:error, :timeout}, {:error, :intent_backoff}])

    assert Agent.get(calls, & &1) == 1
    assert Repo.get!(Intent, intent.id).attempt_count == 1
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).search_attempts == 4
  end

  test "the exhausting movie retry generation atomically becomes its cleanup carrier" do
    Cinder.TestNotifier.subscribe()
    Catalog.subscribe()

    movie = movie_fixture(%{status: :searching})
    {:ok, movie} = Catalog.transition(movie, %{status: :searching, search_attempts: 9})
    {:ok, intent} = reserve_movie_intent(movie.id)

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Download.reconcile_intent(intent)

    assert %{status: :search_failed, search_attempts: 9} =
             Repo.get!(Cinder.Catalog.Movie, movie.id)

    cleanup = Repo.get!(Intent, intent.id)
    assert cleanup.status == :cleanup_pending
    assert cleanup.operation_key == intent.operation_key

    assert_receive {:movie_updated, %{id: movie_id, status: :search_failed}}
    assert_receive {:notify, {:movie_failed, %{id: ^movie_id, status: :search_failed}, :timeout}}
    assert movie_id == movie.id
  end

  test "an exhausting retry publishes once before fatal cleanup and retains its fence" do
    Cinder.TestNotifier.subscribe()

    movie = movie_fixture(%{status: :searching})
    {:ok, movie} = Catalog.transition(movie, %{status: :searching, search_attempts: 9})
    {:ok, intent} = reserve_movie_intent(movie.id)
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    Catalog.subscribe()

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _ ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:error, :timeout}
        _ -> Process.exit(self(), :kill)
      end
    end)

    {pid, ref} = spawn_monitor(fn -> Download.reconcile_intent(intent) end)

    assert_receive {:movie_updated, %{id: movie_id, status: :search_failed}}
    assert_receive {:notify, {:movie_failed, %{id: ^movie_id, status: :search_failed}, :timeout}}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    refute_receive {:movie_updated, %{id: ^movie_id}}
    refute_receive {:notify, {:movie_failed, %{id: ^movie_id}, _reason}}

    assert movie_id == movie.id
    assert Repo.get!(Intent, intent.id).status == :cleanup_pending
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).status == :search_failed
  end

  test "cleanup lookup failure retains the only operation key" do
    movie = movie_fixture(%{status: :searching})
    {:ok, intent} = reserve_movie_intent(movie.id)
    cleanup = mark_cleanup(intent)
    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Download.reconcile_intent(cleanup)
    saved = Repo.get!(Intent, intent.id)
    assert saved.status == :cleanup_pending
    assert saved.attempt_count == 1
    assert saved.operation_key == intent.operation_key
  end

  test "cleanup remove failure retains a retryable cleanup record" do
    movie = movie_fixture(%{status: :searching})
    intent = submitted_movie_intent(movie.id, "hash-remove-failed")
    cleanup = mark_cleanup(intent)
    expect(Cinder.Download.ClientMock, :remove, fn _id, _opts -> {:error, :timeout} end)

    assert {:error, :timeout} = Download.reconcile_intent(cleanup)
    saved = Repo.get!(Intent, intent.id)
    assert saved.status == :cleanup_pending
    assert saved.remote_id == "hash-remove-failed"
    assert saved.attempt_count == 1
  end

  test "cleanup deletes the record after direct remove succeeds" do
    movie = movie_fixture(%{status: :searching})
    intent = submitted_movie_intent(movie.id, "hash-remove-ok")
    cleanup = mark_cleanup(intent)
    expect(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)

    assert {:ok, :removed} = Download.reconcile_intent(cleanup)
    refute Repo.get(Intent, intent.id)
  end

  test "cleanup converges after process death during remote removal" do
    movie = movie_fixture(%{status: :searching})
    intent = submitted_movie_intent(movie.id, "hash-cleanup-crash")
    cleanup = mark_cleanup(intent)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> Process.exit(self(), :kill)
        _ -> :ok
      end
    end)

    {pid, ref} = spawn_monitor(fn -> Download.reconcile_intent(cleanup) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert Repo.get!(Intent, intent.id).status == :cleanup_pending

    assert :ok = Download.reconcile_pending_intents([:movie])
    refute Repo.get(Intent, intent.id)
    assert Agent.get(calls, & &1) == 2
  end

  test "cancellation racing a submission fences it before add or attachment" do
    movie = movie_fixture(%{status: :searching})
    actor = Cinder.AccountsFixtures.admin_fixture()
    {:ok, intent} = reserve_movie_intent(movie.id)
    parent = self()

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _ ->
      send(parent, {:lookup_blocked, self()})
      receive do: (:continue -> :not_found)
    end)

    submit = Task.async(fn -> Download.reconcile_intent(intent) end)
    assert_receive {:lookup_blocked, lookup_pid}
    cancel = Task.async(fn -> Catalog.cancel_movie(movie, actor) end)
    Process.sleep(25)
    send(lookup_pid, :continue)

    assert {:error, :stale_target} = Task.await(submit)
    assert {:ok, %Cinder.Catalog.Movie{status: :cancelled}} = Task.await(cancel)
  end

  test "movie cancellation commits before cleanup and a cleanup crash keeps its fence" do
    movie = movie_fixture(%{status: :searching})
    actor = Cinder.AccountsFixtures.admin_fixture()
    intent = submitted_movie_intent(movie.id, "hash-cancel-after-commit")
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    parent = self()

    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts ->
      send(parent, {:remove_observed_movie, Repo.get!(Cinder.Catalog.Movie, movie.id).status})

      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> Process.exit(self(), :kill)
        _ -> :ok
      end
    end)

    {pid, ref} = spawn_monitor(fn -> Catalog.cancel_movie(movie, actor) end)
    assert_receive {:remove_observed_movie, :cancelled}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert Repo.get!(Intent, intent.id).status == :cleanup_pending

    assert :ok = Download.reconcile_pending_intents([:movie])
    refute Repo.get(Intent, intent.id)
  end

  test "cancel_grab is idempotent when the poller deletes the re-read grab first" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    {:ok, grab} = Catalog.create_grab("hash-already-finished", :torrent, [episode.id])

    # Simulate the poller winning after the LiveView re-read but before cancel_grab's transaction.
    assert {:ok, _deleted} = Repo.delete(grab)
    refute Repo.get(Grab, grab.id)
    assert Repo.get!(Cinder.Catalog.Episode, episode.id).grab_id == nil

    assert {:ok, %Grab{id: id}} = Catalog.cancel_grab(grab)
    assert id == grab.id
    assert Repo.aggregate(Intent, :count) == 0
    assert Repo.aggregate(IntentEpisode, :count) == 0
  end

  test "series cancellation commits unmonitoring before cleanup and preserves a crashed fence" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    actor = Cinder.AccountsFixtures.admin_fixture()
    {:ok, intent} = reserve_episode_intent([episode.id], release("Show.Cancel"))

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-tv-fence"})
      |> Repo.update!()

    {:ok, calls} = Agent.start_link(fn -> 0 end)
    parent = self()

    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts ->
      send(
        parent,
        {:remove_observed_episode, Repo.get!(Cinder.Catalog.Episode, episode.id).monitored}
      )

      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> Process.exit(self(), :kill)
        _ -> :ok
      end
    end)

    {pid, ref} = spawn_monitor(fn -> Catalog.cancel_series(series, actor) end)
    assert_receive {:remove_observed_episode, false}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert Repo.get!(Intent, intent.id).status == :cleanup_pending

    assert :ok = Download.reconcile_pending_intents([:episode, :season_pack])
    refute Repo.get(Intent, intent.id)
  end

  test "movie and series deletion commit before pending-intent cleanup" do
    movie = movie_fixture(%{status: :searching})
    movie_intent = submitted_movie_intent(movie.id, "hash-delete-fence")

    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    {:ok, tv_intent} = reserve_episode_intent([episode.id], release("Show.Delete"))

    tv_intent =
      tv_intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-tv-delete"})
      |> Repo.update!()

    parent = self()

    stub(Cinder.Download.ClientMock, :remove, fn id, _opts ->
      send(
        parent,
        {:delete_cleanup_state, id, Repo.get(Cinder.Catalog.Movie, movie.id),
         Repo.get(Cinder.Catalog.Series, series.id)}
      )

      :ok
    end)

    assert {:ok, _} = Catalog.delete_movie(movie, nil)
    assert_receive {:delete_cleanup_state, "hash-delete-fence", nil, %Cinder.Catalog.Series{}}
    refute Repo.get(Intent, movie_intent.id)

    assert {:ok, _} = Catalog.delete_series(series, nil)
    assert_receive {:delete_cleanup_state, "hash-tv-delete", nil, nil}
    refute Repo.get(Intent, tv_intent.id)
  end

  test "a live movie submission cannot add or attach after cancellation commits" do
    movie = movie_fixture(%{status: :searching})
    actor = Cinder.AccountsFixtures.admin_fixture()
    {:ok, intent} = reserve_movie_intent(movie.id)
    {:ok, lookups} = Agent.start_link(fn -> 0 end)
    {:ok, adds} = Agent.start_link(fn -> 0 end)
    parent = self()

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _ ->
      case Agent.get_and_update(lookups, &{&1, &1 + 1}) do
        0 ->
          send(parent, {:submission_lookup_blocked, self()})
          receive do: (:continue -> :not_found)

        _ ->
          :not_found
      end
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      Agent.update(adds, &(&1 + 1))
      {:ok, "must-not-be-added"}
    end)

    submit = Task.async(fn -> Download.reconcile_intent(intent) end)
    assert_receive {:submission_lookup_blocked, lookup_pid}
    cancel = Task.async(fn -> Catalog.cancel_movie(movie, actor) end)

    assert eventually(fn -> Repo.get!(Cinder.Catalog.Movie, movie.id).status == :cancelled end)
    send(lookup_pid, :continue)

    assert {:ok, %Cinder.Catalog.Movie{status: :cancelled}} = Task.await(cancel)
    assert {:error, _reason} = Task.await(submit)
    assert Agent.get(adds, & &1) == 0
    refute Repo.get(Intent, intent.id)
  end

  test "an accepted movie submission racing cancellation is removed without attachment" do
    movie = movie_fixture(%{status: :searching})
    actor = Cinder.AccountsFixtures.admin_fixture()
    {:ok, intent} = reserve_movie_intent(movie.id)
    parent = self()

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> :not_found end)

    expect(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      send(parent, {:movie_remote_accepted, self()})
      receive do: (:return_remote -> {:ok, "hash-racing-cancel"})
    end)

    expect(Cinder.Download.ClientMock, :remove, fn "hash-racing-cancel", _opts -> :ok end)

    submit = Task.async(fn -> Download.reconcile_intent(intent) end)
    assert_receive {:movie_remote_accepted, add_pid}
    cancel = Task.async(fn -> Catalog.cancel_movie(movie, actor) end)
    assert eventually(fn -> Repo.get!(Cinder.Catalog.Movie, movie.id).status == :cancelled end)
    send(add_pid, :return_remote)

    assert {:ok, :removed} = Task.await(submit)
    assert {:ok, %Cinder.Catalog.Movie{status: :cancelled}} = Task.await(cancel)
    refute Repo.get(Intent, intent.id)
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).download_id == nil
  end

  test "an accepted TV submission racing series cancellation is removed without a grab" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    actor = Cinder.AccountsFixtures.admin_fixture()
    {:ok, intent} = reserve_episode_intent([episode.id], release("Show.Race"))
    parent = self()

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> :not_found end)

    expect(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      send(parent, {:tv_remote_accepted, self()})
      receive do: (:return_remote -> {:ok, "hash-tv-racing-cancel"})
    end)

    expect(Cinder.Download.ClientMock, :remove, fn "hash-tv-racing-cancel", _opts -> :ok end)

    submit = Task.async(fn -> Download.reconcile_intent(intent) end)
    assert_receive {:tv_remote_accepted, add_pid}
    cancel = Task.async(fn -> Catalog.cancel_series(series, actor) end)
    assert eventually(fn -> Repo.get!(Cinder.Catalog.Episode, episode.id).monitored == false end)
    send(add_pid, :return_remote)

    assert {:ok, :removed} = Task.await(submit)
    assert {:ok, _series} = Task.await(cancel)
    refute Repo.get(Intent, intent.id)
    assert Repo.all(Grab) == []
    assert Repo.get!(Cinder.Catalog.Episode, episode.id).grab_id == nil
  end

  test "manual movie release returns busy instead of submitting an older intent" do
    movie = movie_fixture(%{status: :no_match})
    {:ok, _intent} = reserve_movie_intent(movie.id, release("Old.Movie"))

    assert {:error, :download_intent_busy} = Download.grab_movie(movie, release("Chosen.Movie"))
  end

  test "manual TV release returns busy instead of submitting an older overlapping intent" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    {:ok, _intent} = reserve_episode_intent([episode.id], release("Old.Show"))

    assert {:error, :download_intent_busy} =
             Download.grab_episodes(release("Chosen.Show"), [episode.id])
  end

  test "a definite add rejection releases movie and TV targets for another search" do
    movie = movie_fixture(%{status: :no_match})
    {:ok, movie_intent} = reserve_movie_intent(movie.id, release("Rejected.Movie"))

    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    {:ok, tv_intent} = reserve_episode_intent([episode.id], release("Rejected.Show"))

    expect(Cinder.Download.ClientMock, :find_by_operation_key, 2, fn _ -> :not_found end)
    expect(Cinder.Download.ClientMock, :add, 2, fn _release, _opts -> {:error, :add_rejected} end)

    assert {:error, :add_rejected} = Download.reconcile_intent(movie_intent)
    assert {:error, :add_rejected} = Download.reconcile_intent(tv_intent)
    refute Repo.get(Intent, movie_intent.id)
    refute Repo.get(Intent, tv_intent.id)

    assert {:ok, _next_movie_search} = reserve_movie_intent(movie.id, release("Next.Movie"))
    assert {:ok, _next_tv_search} = reserve_episode_intent([episode.id], release("Next.Show"))
  end

  test "a reserved intent survives process death and later submits once" do
    movie = movie_fixture(%{status: :searching})
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, intent} = reserve_movie_intent(movie.id)
        send(parent, {:reserved, intent.id})
        Process.exit(self(), :kill)
      end)

    assert_receive {:reserved, intent_id}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    intent = Repo.get!(Intent, intent_id)

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> :not_found end)
    expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-reserved"} end)

    assert {:ok, _movie} = Download.reconcile_intent(intent)
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).download_id == "hash-reserved"
  end

  test "process death after lookup re-runs lookup before one add" do
    movie = movie_fixture(%{status: :searching})
    {:ok, intent} = reserve_movie_intent(movie.id)
    {:ok, lookups} = Agent.start_link(fn -> 0 end)
    {:ok, adds} = Agent.start_link(fn -> 0 end)

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _ ->
      case Agent.get_and_update(lookups, &{&1, &1 + 1}) do
        0 -> Process.exit(self(), :kill)
        _ -> :not_found
      end
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      Agent.update(adds, &(&1 + 1))
      {:ok, "hash-after-lookup"}
    end)

    {pid, ref} = spawn_monitor(fn -> Download.reconcile_intent(intent) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, _movie} = Download.reconcile_intent(intent)
    assert Agent.get(lookups, & &1) == 2
    assert Agent.get(adds, & &1) == 1
  end

  test "process death after movie ownership commit converges without add or orphan cleanup" do
    movie = movie_fixture(%{status: :searching})
    intent = submitted_movie_intent(movie.id, "hash-owned")
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, downloading} =
          Catalog.transition(movie, %{
            status: :downloading,
            download_id: "hash-owned",
            download_protocol: :torrent
          })

        send(parent, {:movie_owner_committed, downloading.id})
        Process.exit(self(), :kill)
      end)

    assert_receive {:movie_owner_committed, movie_id}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, reconciled} = Download.reconcile_intent(intent)
    assert reconciled.id == movie_id
    assert reconciled.download_id == "hash-owned"
    refute Repo.get(Intent, intent.id)
  end

  test "process death after remote-id persistence resumes from submitted without adding again" do
    movie = movie_fixture(%{status: :searching})
    {:ok, intent} = reserve_movie_intent(movie.id)
    parent = self()

    expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _ -> :not_found end)
    expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-submitted"} end)

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, submitted} = Download.submit_intent(intent)
        send(parent, {:remote_stored, submitted.id})
        Process.exit(self(), :kill)
      end)

    assert_receive {:remote_stored, intent_id}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    submitted = Repo.get!(Intent, intent_id)
    assert submitted.status == :submitted

    assert {:ok, _movie} = Download.reconcile_intent(submitted)
    assert Repo.get!(Cinder.Catalog.Movie, movie.id).download_id == "hash-submitted"
  end

  test "process death after grab ownership commit removes only the intent on recovery" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    {:ok, intent} = reserve_episode_intent([episode.id], release("Owned.Show"))

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-grab-owned"})
      |> Repo.update!()

    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, grab} = Catalog.create_grab("hash-grab-owned", :torrent, [episode.id], "Owned.Show")
        send(parent, {:grab_committed, grab.id})
        Process.exit(self(), :kill)
      end)

    assert_receive {:grab_committed, grab_id}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, %Grab{id: ^grab_id}} = Download.reconcile_intent(intent)
    refute Repo.get(Intent, intent.id)
    assert Repo.get!(Grab, grab_id).download_id == "hash-grab-owned"
  end

  test "cancelling a movie removes its submitted remote job and intent" do
    movie = movie_fixture(%{status: :searching})
    actor = Cinder.AccountsFixtures.admin_fixture()

    assert {:ok, movie} =
             Catalog.transition(movie, %{
               status: :searching,
               release_policy_snapshot: release_policy_snapshot("Cancelled.Release")
             })

    assert {:ok, intent} = reserve_movie_intent(movie.id)

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-cancel"})
      |> Repo.update!()

    expect(Cinder.Download.ClientMock, :remove, fn "hash-cancel", _opts -> :ok end)

    assert {:ok, %Movie{release_policy_snapshot: nil}} = Catalog.cancel_movie(movie, actor)
    refute Repo.get(Intent, intent.id)
  end

  test "cancelling a series removes its submitted remote job and intent" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    actor = Cinder.AccountsFixtures.admin_fixture()

    release = %Release{title: "Show.S01E01", download_url: "magnet:?x", protocol: :torrent}

    assert {:ok, intent} =
             Download.reserve_intent(%{
               kind: :episode,
               target_id: episode.id,
               episode_ids: [episode.id],
               protocol: :torrent,
               release: release
             })

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-tv-cancel"})
      |> Repo.update!()

    expect(Cinder.Download.ClientMock, :remove, fn "hash-tv-cancel", _opts -> :ok end)

    assert {:ok, _series} = Catalog.cancel_series(series, actor)
    refute Repo.get(Intent, intent.id)
  end

  test "reconciliation cannot link an episode that became unmonitored" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season)
    release = %Release{title: "Show.S01E01", download_url: "magnet:?x", protocol: :torrent}

    assert {:ok, intent} =
             Download.reserve_intent(%{
               kind: :episode,
               target_id: episode.id,
               episode_ids: [episode.id],
               protocol: :torrent,
               release: release
             })

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-unmonitored"})
      |> Repo.update!()

    Repo.update_all(Cinder.Catalog.Episode, set: [monitored: false])
    expect(Cinder.Download.ClientMock, :remove, fn "hash-unmonitored", _opts -> :ok end)

    assert {:error, :no_episodes_linked} = Download.reconcile_intent(intent)
    assert Repo.all(Grab) == []
    refute Repo.get(Intent, intent.id)
  end

  defp reserve_movie_intent(movie_id, chosen \\ release("Movie")) do
    Download.reserve_intent(%{
      kind: :movie,
      target_id: movie_id,
      episode_ids: [],
      protocol: :torrent,
      release: chosen
    })
  end

  defp anime_reservation_fixture do
    # original_language/preferred_language satisfy a dub/dual-mode global default (some callers
    # override the global Anime audio mode for the duration of their test).
    series =
      series_fixture(%{
        monitor_strategy: :all,
        media_profile: :anime,
        original_language: "ja",
        preferred_language: "french"
      })

    season = season_fixture(series)
    first = episode_fixture(season, episode_number: 1)
    second = episode_fixture(season, episode_number: 2)

    coordinate =
      episode_coordinate_fixture(
        series,
        %{
          source: "manual",
          scheme: "absolute",
          namespace: "manual",
          canonical_value: "1-2",
          precedence: :manual
        },
        [first.id, second.id]
      )

    context = Catalog.anime_series_acquisition_context(series)

    candidate = %Release{
      title: "[Group] Show S01E01-S01E02 [1080p]",
      size: 4_000_000_000,
      download_url: "magnet:?xt=urn:btih:anime-snapshot",
      protocol: :torrent,
      resolution: "1080p"
    }

    assert {:ok, %{assignments: [assignment]}} =
             Anime.select_episodes([candidate], context, [first.id, second.id], [])

    %{
      series: series,
      first: first,
      second: second,
      coordinate: coordinate,
      release: assignment.release,
      snapshot: assignment.mapping_snapshot
    }
  end

  defp reserve_anime_intent(fixture) do
    Download.reserve_intent(%{
      kind: :season_pack,
      target_id: fixture.first.id,
      episode_ids: [fixture.first.id, fixture.second.id],
      protocol: :torrent,
      release: fixture.release,
      mapping_snapshot: fixture.snapshot
    })
  end

  defp reserve_marked_movie_intent(movie, release, snapshot, remote_id) do
    with {:ok, intent} <-
           Download.reserve_intent(%{
             kind: :movie,
             target_id: movie.id,
             episode_ids: [],
             protocol: release.protocol,
             release: release,
             release_policy_snapshot: snapshot
           }) do
      {:ok,
       intent
       |> Intent.changeset(%{status: :submitted, remote_id: remote_id})
       |> Repo.update!()}
    end
  end

  defp assert_invalid_episode_intent_rejected(
         episode_ids,
         episodes,
         action \\ &Download.reconcile_intent/1
       ) do
    chosen = release("Direct.Invalid.Episodes")

    assert {:ok, intent} =
             Download.reserve_intent(%{
               kind: :season_pack,
               target_id: hd(episode_ids),
               episode_ids: episode_ids,
               protocol: chosen.protocol,
               release: chosen
             })

    calls = start_supervised!({Agent, fn -> 0 end})

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _operation_key ->
      Agent.update(calls, &(&1 + 1))
      :not_found
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      Agent.update(calls, &(&1 + 1))
      {:ok, "hash-invalid-episodic-intent"}
    end)

    assert {:error, :episode_series_mismatch} = action.(Repo.reload!(intent))

    assert Agent.get(calls, & &1) == 0
    refute Repo.get(Intent, intent.id)
    assert Repo.aggregate(Grab, :count) == 0
    Enum.each(episodes, &refute(Repo.reload!(&1).grab_id))
  end

  defp release_policy_snapshot(title) do
    %{
      "version" => 1,
      "required_audio_languages" => ["ja", "fr"],
      "required_embedded_subtitle_languages" => ["fr"],
      "release_group" => "subsplease",
      "release_title" => title
    }
  end

  defp valid_anime_intent_attrs(fixture, mapping_snapshot) do
    %{
      operation_key: Ecto.UUID.generate(),
      kind: :season_pack,
      target_id: fixture.first.id,
      episode_ids: [fixture.first.id, fixture.second.id],
      protocol: :torrent,
      release: %{"title" => fixture.release.title},
      status: :reserved,
      mapping_snapshot: mapping_snapshot
    }
  end

  defp invalid_snapshots(snapshot) do
    first_value = get_in(snapshot, ["selected_resolution", "values", Access.at(0)])
    second_value = get_in(snapshot, ["selected_resolution", "values", Access.at(1)])
    first_identity = hd(first_value["mapping_identities"])

    [
      {"reserved ID mismatch",
       put_in(snapshot, ["reserved_episode_ids"], [hd(snapshot["reserved_episode_ids"])])},
      {"non-integer reserved ID", put_in(snapshot, ["reserved_episode_ids"], ["bad"])},
      {"non-map selected value", put_in(snapshot, ["selected_resolution", "values"], ["bad"])},
      {"empty mapping identity references",
       update_selected_value(snapshot, 0, &Map.put(&1, "mapping_identities", []))},
      {"missing mapping identity reference",
       update_selected_value(snapshot, 0, fn value ->
         Map.put(value, "mapping_identities", [%{first_identity | "source" => "missing"}])
       end)},
      {"duplicate mapping identity references",
       update_selected_value(snapshot, 0, fn value ->
         Map.put(value, "mapping_identities", [first_identity, first_identity])
       end)},
      {"mapping without reserved intersection",
       update_in(snapshot, ["mappings"], fn mappings ->
         mappings ++
           [
             %{
               "identity" => %{
                 "source" => "bad",
                 "scheme" => "absolute",
                 "namespace" => "bad",
                 "canonical_value" => "99"
               },
               "precedence" => "manual",
               "episode_ids" => [999],
               "evidence" => %{}
             }
           ]
       end)},
      {"missing closure coverage", put_in(snapshot, ["mappings"], [hd(snapshot["mappings"])])},
      {"selected scheme mismatch",
       update_selected_value(snapshot, 0, &Map.put(&1, "scheme", "absolute"))},
      {"selected ordered ID mismatch",
       update_selected_value(
         snapshot,
         0,
         &Map.put(&1, "episode_ids", second_value["episode_ids"])
       )},
      {"omitted parsed coordinate value",
       put_in(snapshot, ["selected_resolution", "values"], [first_value])},
      {"duplicated selected coordinate value",
       put_in(
         snapshot,
         ["selected_resolution", "values"],
         [first_value, first_value, second_value]
       )},
      {"selected coordinate absent from release",
       update_selected_value(snapshot, 0, &Map.put(&1, "canonical_value", "S09E09"))},
      {"selected episode concatenation mismatch",
       put_in(
         snapshot,
         ["selected_resolution", "episode_ids"],
         Enum.reverse(snapshot["selected_resolution"]["episode_ids"])
       )}
    ]
  end

  defp update_selected_value(snapshot, index, fun) do
    update_in(snapshot, ["selected_resolution", "values"], fn values ->
      List.update_at(values, index, fun)
    end)
  end

  defp reserve_episode_intent(episode_ids, chosen) do
    Download.reserve_intent(%{
      kind: if(length(episode_ids) == 1, do: :episode, else: :season_pack),
      target_id: hd(episode_ids),
      episode_ids: episode_ids,
      protocol: :torrent,
      release: chosen
    })
  end

  defp submitted_movie_intent(movie_id, remote_id) do
    {:ok, intent} = reserve_movie_intent(movie_id)

    intent
    |> Intent.changeset(%{status: :submitted, remote_id: remote_id})
    |> Repo.update!()
  end

  defp mark_cleanup(intent) do
    intent
    |> Intent.changeset(%{
      status: :cleanup_pending,
      attempt_count: 0,
      next_attempt_at: nil,
      last_error: nil
    })
    |> Repo.update!()
  end

  defp release(title),
    do: %Release{title: title, download_url: "magnet:?xt=urn:btih:#{title}", protocol: :torrent}

  defp concurrently(first, second \\ nil) do
    parent = self()
    second = second || first

    tasks =
      for fun <- [first, second] do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> fun.())
        end)
      end

    pids =
      for _ <- 1..2,
          do:
            (
              assert_receive {:ready, pid}
              pid
            )

    Enum.each(pids, &send(&1, :go))
    Enum.map(tasks, &Task.await/1)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end
