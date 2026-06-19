defmodule Cinder.Catalog.Movie do
  @moduledoc """
  A watchlisted movie.

  Created `:requested`; the download pipeline advances `status`
  (`:searching → :downloading → :downloaded → :available`), parks it at
  `:no_match` when no release survives the scorer, or `:import_failed` when a
  completed download has no usable file to import.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @statuses [
    :requested,
    :searching,
    :downloading,
    :downloaded,
    :available,
    :no_match,
    :import_failed
  ]

  schema "movies" do
    field :tmdb_id, :integer
    field :imdb_id, :string
    field :title, :string
    field :year, :integer
    field :poster_path, :string
    field :status, Ecto.Enum, values: @statuses, default: :requested
    field :download_id, :string
    field :file_path, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(movie, attrs) do
    movie
    |> cast(attrs, [:tmdb_id, :imdb_id, :title, :year, :poster_path])
    |> validate_required([:tmdb_id, :title])
    |> unique_constraint(:tmdb_id)
  end

  @doc "Changeset for pipeline state transitions (status + optional download_id/imdb_id)."
  def transition_changeset(movie, attrs) do
    movie
    |> cast(attrs, [:status, :download_id, :imdb_id, :file_path])
    |> validate_required([:status])
  end
end
