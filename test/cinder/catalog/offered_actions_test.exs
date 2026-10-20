defmodule Cinder.Catalog.OfferedActionsTest do
  use Cinder.DataCase, async: true

  import Cinder.CatalogFixtures
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{Attention, Grab, GrabFile, Movie, MovieLifecycle}
  alias Cinder.Repo

  setup :verify_on_exit!

  @movie_states [
    :requested,
    :searching,
    :anime_held_requested,
    :anime_held_searching,
    :downloading,
    :downloaded,
    :upgrading,
    :no_match,
    :search_failed,
    :import_failed,
    :download_verification_hold,
    :upgrade_verification_hold,
    :available,
    :cancelled
  ]

  @grab_states [:downloading, :downloaded, :needs_mapping, :verification_blocked, :residual_files]

  # A series classifies only on its anime hold: none, one per hold reason, or one its cancel lifted.
  @series_states [nil, "original_language_required", "subtitle_language_required", :cancelled]

  # Real rows for each classified state, carrying the fields the operator functions need (a
  # download to fence, a release to blocklist, a live file to keep).
  defp seed_movie(:requested), do: movie_fixture()
  defp seed_movie(:searching), do: movie_fixture(status: :searching)
  defp seed_movie(:anime_held_requested), do: anime_hold(movie_fixture())
  defp seed_movie(:anime_held_searching), do: anime_hold(movie_fixture(status: :searching))

  defp seed_movie(:downloading),
    do: movie_fixture(status: :downloading, download_id: "dl", download_protocol: :torrent)

  defp seed_movie(:downloaded),
    do:
      movie_fixture(
        status: :downloaded,
        download_id: "dl",
        download_protocol: :torrent,
        content_path: "/downloads/m",
        release_title: "Movie.2020.1080p"
      )

  defp seed_movie(:upgrading),
    do:
      movie_fixture(
        status: :upgrading,
        file_path: "/lib/Movie (2020)/Movie (2020).mkv",
        download_id: "up",
        download_protocol: :torrent,
        release_title: "Movie.2020.2160p"
      )

  defp seed_movie(parked) when parked in [:no_match, :search_failed, :import_failed],
    do: movie_fixture(status: parked)

  defp seed_movie(:download_verification_hold),
    do: verification_hold(seed_movie(:downloaded), :download)

  defp seed_movie(:upgrade_verification_hold),
    do: verification_hold(seed_movie(:upgrading), :upgrade)

  defp seed_movie(:available),
    do: movie_fixture(status: :available, file_path: "/lib/Movie (2020)/Movie (2020).mkv")

  defp seed_movie(:cancelled), do: movie_fixture(status: :cancelled)

  defp anime_hold(movie),
    do:
      Repo.update!(
        Movie.anime_hold_changeset(movie, %{anime_hold_reason: "subtitle_language_required"})
      )

  defp verification_hold(movie, origin) do
    {:ok, held} =
      seed_movie_state(movie, %{
        status: :import_failed,
        import_attempts: 1,
        verification_hold_origin: origin
      })

    held
  end

  defp seed_grab(state) do
    series = series_fixture(%{monitor_strategy: :all})
    episode = episode_fixture(season_fixture(series))
    {:ok, grab} = Catalog.create_grab("hash-#{state}", :torrent, [episode.id], "Show.S01.1080p")
    seed_grab_state(grab, state)
    Enum.find(Catalog.list_grabs(), &(&1.id == grab.id))
  end

  defp seed_grab_state(_grab, :downloading), do: :ok

  defp seed_grab_state(grab, :downloaded),
    do: Repo.update!(Ecto.Changeset.change(grab, content_path: "/downloads/show"))

  defp seed_grab_state(grab, :needs_mapping),
    do:
      Repo.update!(
        Ecto.Changeset.change(grab,
          content_path: "/downloads/show",
          mapping_status: :needs_mapping,
          mapping_issue: %{"version" => 1, "reason" => "unresolved_file"}
        )
      )

  defp seed_grab_state(grab, :verification_blocked),
    do:
      Repo.update!(
        Ecto.Changeset.change(grab,
          content_path: "/downloads/show",
          mapping_status: :verification_blocked
        )
      )

  defp seed_grab_state(grab, :residual_files) do
    seed_grab_state(grab, :downloaded)

    Repo.insert!(%GrabFile{
      grab_id: grab.id,
      relative_path: "extra.mkv",
      size: 10,
      device: 1,
      inode: 2
    })
  end

  @release %Cinder.Acquisition.Release{
    title: "Pick",
    protocol: :torrent,
    download_url: "magnet:?x"
  }

  # Each operator action, run as the operator would, and the refusal it returns when the item
  # does not offer it.
  defp run(:movie, :retry, movie, _admin), do: MovieLifecycle.retry(movie)
  defp run(:movie, :cancel, movie, admin), do: MovieLifecycle.cancel(movie, admin)
  defp run(:movie, :cancel_upgrade, movie, admin), do: MovieLifecycle.abort_upgrade(movie, admin)
  defp run(:movie, :manual_search, movie, _admin), do: Catalog.manual_grab_movie(movie, @release)
  defp run(:grab, :retry_mapping, grab, _admin), do: Catalog.retry_grab_mapping(grab)
  defp run(:grab, :retry_verification, grab, _admin), do: Catalog.retry_grab_verification(grab)
  defp run(:grab, :import_anyway, grab, admin), do: Catalog.import_grab_anyway(grab, admin)
  defp run(:grab, :discard, grab, _admin), do: Catalog.cancel_mapping_grab(grab)
  defp run(:grab, :cancel, grab, _admin), do: Catalog.cancel_grab(grab)

  @refusals %{
    movie: %{
      retry: :not_retryable,
      cancel: :not_cancellable,
      cancel_upgrade: :not_upgrading,
      manual_search: :not_grabbable
    },
    grab: %{
      retry_mapping: :mapping_not_held,
      retry_verification: :verification_not_held,
      import_anyway: :verification_not_held,
      discard: :mapping_not_held,
      cancel: :not_cancellable
    }
  }

  # The cross-product: every classified state against every operator action of its kind. An
  # offered action succeeds; one the item does not offer is refused with its action's own atom and
  # writes nothing.
  describe "every offered action succeeds and every other action is refused" do
    setup do
      stub(Cinder.Download.ClientMock, :add, fn _url, _opts -> {:ok, "dl-new"} end)
      stub(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)
      %{admin: Cinder.AccountsFixtures.admin_fixture()}
    end

    for kind <- [:movie, :grab],
        state <- if(kind == :movie, do: @movie_states, else: @grab_states),
        action <- Map.keys(@refusals[kind]) do
      test "#{kind} #{state} × #{action}", %{admin: admin} do
        kind = unquote(kind)
        action = unquote(action)
        item = seed(kind, unquote(state))

        if Attention.offers?(item, action) do
          assert {:ok, _} = run(kind, action, item, admin)
        else
          assert run(kind, action, item, admin) == {:error, @refusals[kind][action]}
          assert reread(item) == item
        end
      end
    end
  end

  # The struct the caller rendered is the expectation: an action offered for it refuses a row that
  # has since moved to a state where the classification would not offer it.
  describe "an offered action refuses a row that changed underneath" do
    test "retry on a stale parked movie leaves a fresh verification hold alone" do
      stale = seed_movie(:import_failed)

      {:ok, held} =
        seed_movie_state(stale, %{
          download_id: "dl",
          download_protocol: :torrent,
          release_title: "Movie.2020.1080p",
          verification_hold_origin: :download
        })

      assert MovieLifecycle.retry(stale) == {:error, :stale_status}
      assert Repo.get!(Movie, stale.id) == held
    end

    test "a manual grab on a stale parked movie leaves a fresh verification hold alone" do
      stale = seed_movie(:import_failed)

      {:ok, held} =
        seed_movie_state(stale, %{
          download_id: "dl",
          download_protocol: :torrent,
          release_title: "Movie.2020.1080p",
          verification_hold_origin: :download
        })

      # No client expectation: submitting for the hold at all fails the test.
      stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)

      assert {:error, :stale_target} = Catalog.manual_grab_movie(stale, @release)
      assert Repo.get!(Movie, stale.id) == held
    end

    test "cancel on a stale grab refuses one now held for mapping" do
      stale = seed_grab(:verification_blocked)

      Repo.update_all(from(g in Grab, where: g.id == ^stale.id),
        set: [mapping_status: :needs_mapping]
      )

      assert Catalog.cancel_grab(stale) == {:error, :not_cancellable}
      assert Repo.get!(Grab, stale.id).mapping_status == :needs_mapping
    end
  end

  defp seed(:movie, state), do: seed_movie(state)
  defp seed(:grab, state), do: seed_grab(state)

  defp seed_series(:cancelled) do
    {:ok, held} = Catalog.set_anime_hold(series_fixture(), "subtitle_language_required")
    {:ok, cancelled} = Catalog.cancel_series(held, Cinder.AccountsFixtures.admin_fixture())
    cancelled
  end

  defp seed_series(reason) do
    {:ok, series} = Catalog.set_anime_hold(series_fixture(), reason)
    series
  end

  defp reread(%Movie{id: id}), do: Repo.get!(Movie, id)
  defp reread(%Grab{id: id}), do: Enum.find(Catalog.list_grabs(), &(&1.id == id))

  describe "counts/0" do
    # Each grab seeds its own unheld series, so the series tally counts five more idle rows.
    test "tallies one row per classified state by phase" do
      for state <- @movie_states, do: seed_movie(state)
      for state <- @grab_states, do: seed_grab(state)
      for reason <- @series_states, do: seed_series(reason)

      assert Attention.counts() == %{
               movie: %{active: 5, attention: 7, waiting: 0, idle: 2},
               grab: %{active: 2, attention: 3, waiting: 0, idle: 0},
               series: %{active: 0, attention: 2, waiting: 0, idle: 7}
             }

      assert Attention.attention_count() == 12
    end

    test "agrees with classifying every listed movie, grab and series" do
      for state <- @movie_states, do: seed_movie(state)
      for state <- @grab_states, do: seed_grab(state)
      for reason <- @series_states, do: seed_series(reason)

      tally = fn items ->
        Enum.reduce(items, %{active: 0, attention: 0, waiting: 0, idle: 0}, fn item, acc ->
          Map.update!(acc, Attention.classify(item).phase, &(&1 + 1))
        end)
      end

      assert Attention.counts() == %{
               movie: tally.(Catalog.list_movies()),
               grab: tally.(Catalog.list_grabs()),
               series: tally.(Catalog.list_series())
             }
    end

    test "is all zeroes with nothing in the catalog" do
      zero = %{active: 0, attention: 0, waiting: 0, idle: 0}
      assert Attention.counts() == %{movie: zero, grab: zero, series: zero}
      assert Attention.attention_count() == 0
    end
  end
end
