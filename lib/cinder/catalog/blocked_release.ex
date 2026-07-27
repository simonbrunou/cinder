defmodule Cinder.Catalog.BlockedRelease do
  @moduledoc """
  A release that failed for a deterministic or download-exhausted reason, recorded
  per-item (`movie_id` for movies, `series_id` for TV) so release selection can skip
  it and stop the re-grab/re-download loop. Identity is the `release_title` string — the stable
  per-indexer release name — stored **verbatim**; it is `Cinder.Acquisition.Scorer` that downcases
  both sides when matching, so this table keeps the original case. Don't normalize on write:
  `Cinder.Download.Poller.requeue_failed/2` bounds its re-queue loop by checking that a row it just
  wrote is readable back under the movie's exact `release_title`. A blocked release can't be re-grabbed while
  blocked, but distinct release names accrue over a title's life, so `Cinder.Accounts.Janitor`
  ages rows out after its `@blocked_release_retention_days` window (default 180d).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Catalog.{Movie, Series}

  schema "blocked_releases" do
    field :release_title, :string
    field :reason, :string
    belongs_to :movie, Movie
    belongs_to :series, Series

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(blocked_release, attrs) do
    blocked_release
    |> cast(attrs, [:release_title, :reason, :movie_id, :series_id])
    |> validate_required([:release_title])
  end
end
