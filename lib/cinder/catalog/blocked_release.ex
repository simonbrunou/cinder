defmodule Cinder.Catalog.BlockedRelease do
  @moduledoc """
  A release that failed for a deterministic or download-exhausted reason, recorded
  per-item (`movie_id` for movies, `series_id` for TV) so release selection can skip
  it and stop the re-grab/re-download loop. Identity is the downcased `release_title`
  string — the stable per-indexer release name. A blocked release can't be re-grabbed while
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
