defmodule Cinder.Download.IntentTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Acquisition.Release
  alias Cinder.Catalog
  alias Cinder.Catalog.Grab
  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  setup :set_mox_global
  setup :verify_on_exit!

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
    assert {:error, changeset} = %Intent{} |> Intent.changeset(attrs) |> Repo.insert()
    assert "has already been taken" in errors_on(changeset).operation_key
  end

  test "cancelling a movie removes its submitted remote job and intent" do
    movie = movie_fixture(%{status: :searching})
    actor = Cinder.AccountsFixtures.admin_fixture()

    assert {:ok, intent} = reserve_movie_intent(movie.id)

    intent =
      intent
      |> Intent.changeset(%{status: :submitted, remote_id: "hash-cancel"})
      |> Repo.update!()

    expect(Cinder.Download.ClientMock, :remove, fn "hash-cancel", _opts -> :ok end)

    assert {:ok, _movie} = Catalog.cancel_movie(movie, actor)
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

  defp reserve_movie_intent(movie_id) do
    release = %Release{title: "Movie", download_url: "magnet:?x", protocol: :torrent}

    Download.reserve_intent(%{
      kind: :movie,
      target_id: movie_id,
      episode_ids: [],
      protocol: :torrent,
      release: release
    })
  end
end
