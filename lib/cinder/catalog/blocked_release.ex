defmodule Cinder.Catalog.BlockedRelease do
  @moduledoc """
  A release that failed for a deterministic or download-exhausted reason, recorded
  per-item (`movie_id` for movies, `series_id` for TV) so release selection can skip
  it and stop the re-grab/re-download loop. Identity is the `release_title` string — the stable
  per-indexer release name — stored **verbatim**; it is `Cinder.Acquisition.Scorer` that downcases
  both sides when matching, so this table keeps the original case. `indexer_id` is not part of
  that identity: it narrows which search results a row matches (#1515). Only a series row written
  for a refused TV submission (`Cinder.Download`) holds one, taken from the download intent, and
  only when that intent stored the refused search result's indexer id; an intent reserved before
  #1515 stored none. Such a row matches its title only in a result from that indexer or from no
  known indexer. A row with a nil `indexer_id` matches its title in every indexer's results.
  Don't normalize the title on write:
  `Cinder.Catalog.MovieLifecycle.record_failure/2` bounds its re-queue loop by checking that a row it just
  wrote is readable back under the movie's exact `release_title`. A blocked release can't be re-grabbed while
  blocked, but distinct release names accrue over a title's life, so `Cinder.Accounts.Janitor`
  ages rows out after its `@blocked_release_retention_days` window (default 180d).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Catalog.{Movie, Series}

  @type t :: %__MODULE__{}

  schema "blocked_releases" do
    field :release_title, :string
    field :reason, :string
    field :indexer_id, :integer
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
