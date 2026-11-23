defmodule Cinder.Download.ClientPauseTest do
  @moduledoc """
  A paused download client (#1598), through `Cinder.Download.Watch` and each kind's real metrics
  writer: a movie, a TV grab and a book grab each keep their pause on the row, and the time spent
  paused does not count toward the stall reaper's 24 h cap.

  `async: false` because the reaper is switched on through application env.
  """
  use Cinder.DataCase, async: false

  @moduletag :capture_log

  import Cinder.CatalogFixtures
  import Cinder.ConfigCase
  import Mox

  alias Cinder.Books
  alias Cinder.Books.BookGrab
  alias Cinder.Catalog
  alias Cinder.Catalog.{Grab, Movie, MovieLifecycle}
  alias Cinder.Download.{Poller, StallReaper, Watch}

  @client Cinder.Download.SabnzbdClientMock
  @kinds [:movie, :grab, :book]

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    put_config(StallReaper, enabled: true)
    stub(@client, :files, fn _id -> {:ok, []} end)
    :ok
  end

  defp row(:movie) do
    movie_fixture(%{
      status: :downloading,
      download_id: "job-movie",
      download_protocol: :usenet,
      release_title: "Paused.Movie.2026.1080p"
    })
  end

  defp row(:grab) do
    episode = series_fixture() |> season_fixture() |> episode_fixture()
    {:ok, grab} = Catalog.create_grab("job-grab", :usenet, [episode.id])
    grab
  end

  defp row(:book) do
    id = System.unique_integer([:positive])

    {:ok, profile} =
      Catalog.create_profile(%{name: "Ebooks #{id}", kind: :ebook, handling: :standard})

    {:ok, work} =
      Books.upsert_work(%{
        title: "Paused Book #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: "OL#{id}W"}
      })

    {:ok, target} = Books.monitor_target(work, :ebook, profile)
    {:ok, grab} = Books.Grabs.create(target.id, "job-book", :usenet, "Paused.Book.#{id}")
    grab
  end

  defp writer(%Movie{}), do: &MovieLifecycle.track/2
  defp writer(%Grab{}), do: &Catalog.update_grab_download_metrics/2
  defp writer(%BookGrab{}), do: &Books.Grabs.track/2

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(:second), -hours, :hour)

  # Puts a row in a known clock state with a raw write, then reads it back as a poller would.
  defp seed(%schema{id: id} = row, attrs) do
    {1, _} = Repo.update_all(from(r in schema, where: r.id == ^id), set: Map.to_list(attrs))
    Repo.reload!(row)
  end

  defp tick(row, report) do
    expect(@client, :status, fn id ->
      assert id == row.download_id
      report
    end)

    Watch.check(row, writer(row))
  end

  defp paused, do: {:ok, %{state: :downloading, progress: 0.0, speed: nil, client_paused: true}}
  defp running, do: {:ok, %{state: :downloading, progress: 0.0, speed: nil, eta: nil}}

  defp assert_about(actual, expected) do
    assert abs(DateTime.diff(actual, expected)) <= 5,
           "expected #{actual} within 5 s of #{expected}"
  end

  for kind <- @kinds do
    @kind kind

    describe "#{kind}" do
      test "the first paused tick marks the row, and later ones write nothing" do
        row = @kind |> row() |> seed(%{updated_at: hours_ago(1), download_progress: 0.0})

        assert tick(row, paused()) == :downloading
        marked = Repo.reload!(row)
        assert_about(marked.download_paused_at, DateTime.utc_now())

        frozen = seed(marked, %{updated_at: hours_ago(2)})
        assert tick(frozen, paused()) == :downloading
        assert Repo.reload!(frozen).updated_at == frozen.updated_at
        assert Repo.reload!(frozen).download_paused_at == marked.download_paused_at
      end

      test "a 42 h pause after 23 h of running leaves one hour on the cap" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            download_progress_at: hours_ago(65),
            download_paused_at: hours_ago(42)
          })

        assert tick(row, paused()) == :downloading
        assert tick(Repo.reload!(row), running()) == :downloading

        resumed = Repo.reload!(row)
        assert resumed.download_paused_at == nil
        assert_about(resumed.download_progress_at, hours_ago(23))
      end

      test "25 h of running split across a pause still stalls" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            download_progress_at: hours_ago(67),
            download_paused_at: hours_ago(42)
          })

        assert tick(row, running()) == :stalled
      end

      test "a first sighting past the cap survives the resume" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            download_progress_at: DateTime.add(hours_ago(24), -300, :second)
          })

        assert tick(row, paused()) == :downloading
        assert Repo.reload!(row).download_paused_at == Repo.reload!(row).download_progress_at

        assert tick(Repo.reload!(row), running()) == :downloading
        assert_about(Repo.reload!(row).download_progress_at, DateTime.utc_now())
      end

      test "a clock that just crossed the cap gets no new window from a pause" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            download_progress_at: DateTime.add(hours_ago(24), -5, :second)
          })

        assert tick(row, paused()) == :downloading
        assert tick(Repo.reload!(row), running()) == :stalled
      end

      test "an unreachable tick keeps the pause, and the later resume still credits it" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.0,
            download_eta: 60,
            download_progress_at: hours_ago(30),
            download_paused_at: hours_ago(28)
          })

        assert {:unreachable, :econnrefused} = tick(row, {:error, :econnrefused})
        kept = Repo.reload!(row)
        assert kept.download_paused_at == row.download_paused_at
        assert kept.download_eta == nil

        assert tick(kept, running()) == :downloading
        assert_about(Repo.reload!(row).download_progress_at, hours_ago(2))
      end

      test "progress on the resume tick sets the clock to now" do
        row =
          @kind
          |> row()
          |> seed(%{
            download_progress: 0.1,
            download_progress_at: hours_ago(30),
            download_paused_at: hours_ago(28)
          })

        report = {:ok, %{state: :downloading, progress: 0.2, speed: nil}}
        assert tick(row, report) == :downloading

        resumed = Repo.reload!(row)
        assert resumed.download_paused_at == nil
        assert_about(resumed.download_progress_at, DateTime.utc_now())
      end
    end
  end

  describe "the end of a pause" do
    test "a movie's move to import clears it" do
      movie = :movie |> row() |> seed(%{download_paused_at: hours_ago(1)})

      assert {:ok, %Movie{status: :downloaded, download_paused_at: nil}} =
               MovieLifecycle.mark_downloaded(movie, "/downloads/M")

      assert Repo.reload!(movie).download_paused_at == nil
    end

    test "a TV grab's completion clears it, from a copy that never saw the pause" do
      grab = row(:grab)
      seed(grab, %{download_paused_at: hours_ago(1)})

      assert {:ok, _} = Catalog.mark_grab_downloaded(grab, "/downloads/pack")
      assert Repo.reload!(grab).download_paused_at == nil
    end

    test "a book grab's completion clears it" do
      grab = :book |> row() |> seed(%{download_paused_at: hours_ago(1)})

      assert {:ok, %BookGrab{download_paused_at: nil}} =
               Books.Grabs.mark_downloaded(grab, "/downloads/book")
    end

    test "a metrics write and a counted strike during the pause keep it" do
      at = hours_ago(1)

      movie =
        :movie
        |> row()
        |> seed(%{download_paused_at: at, download_speed: 100, import_attempts: 0})

      assert {:ok, tracked} = MovieLifecycle.track(movie, %{download_speed: nil})
      assert tracked.download_paused_at == at

      assert {:ok, struck} =
               MovieLifecycle.record_failure(tracked, {:failed, :download_not_found})

      assert struck.status == :downloading
      assert Repo.reload!(movie).download_paused_at == at
    end

    test "a stale track after the movie's download changed writes nothing" do
      movie = :movie |> row() |> seed(%{download_paused_at: hours_ago(30)})
      clock = hours_ago(1)
      current = seed(movie, %{download_id: "job-new", download_progress_at: clock})

      assert {:error, :stale_status} = MovieLifecycle.track(movie, %{client_paused: false})

      assert Repo.reload!(current).download_progress_at == clock
      assert Repo.reload!(current).download_paused_at == current.download_paused_at
    end
  end

  describe "the movie poller" do
    test "removes and blocklists nothing while the client is paused past the cap" do
      movie =
        :movie
        |> row()
        |> seed(%{download_progress: 0.0, download_progress_at: hours_ago(30)})

      test_pid = self()
      stub(@client, :status, fn "job-movie" -> paused() end)

      stub(@client, :remove, fn id, _opts ->
        send(test_pid, {:removed, id})
        :ok
      end)

      start_supervised!({Poller, interval: 60_000})
      assert :ok = Poller.poll()

      refute_received {:removed, _id}
      polled = Repo.reload!(movie)
      assert polled.status == :downloading
      assert Catalog.blocked_release_titles(polled) == []
    end
  end
end
