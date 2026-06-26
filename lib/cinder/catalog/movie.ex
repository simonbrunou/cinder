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
    :search_failed,
    :import_failed,
    :cancelled
  ]

  schema "movies" do
    field :tmdb_id, :integer
    field :imdb_id, :string
    field :title, :string
    field :year, :integer
    field :poster_path, :string
    field :status, Ecto.Enum, values: @statuses, default: :requested
    field :download_id, :string
    field :download_protocol, Ecto.Enum, values: [:torrent, :usenet]
    field :file_path, :string
    field :import_attempts, :integer, default: 0
    field :search_attempts, :integer, default: 0
    field :original_language, :string
    field :preferred_language, :string, default: "original"
    field :imported_resolution, :string
    field :imported_size, :integer
    field :imported_language, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(movie, attrs) do
    movie
    |> cast(attrs, [
      :tmdb_id,
      :imdb_id,
      :title,
      :year,
      :poster_path,
      :original_language,
      :preferred_language
    ])
    |> validate_required([:tmdb_id, :title])
    |> validate_inclusion(:preferred_language, ["original", "french", "any"])
    |> unique_constraint(:tmdb_id)
  end

  @doc "Changeset for the in-app language edit (escape hatch). Not pipeline state — separate from transition_changeset/2."
  def language_changeset(movie, attrs) do
    movie
    |> cast(attrs, [:preferred_language])
    |> validate_inclusion(:preferred_language, ["original", "french", "any"])
  end

  @doc "Changeset for pipeline state transitions (status + optional download_id/download_protocol/imdb_id/file_path/attempt counters)."
  def transition_changeset(movie, attrs) do
    movie
    |> cast(attrs, [
      :status,
      :download_id,
      :download_protocol,
      :imdb_id,
      :file_path,
      :import_attempts,
      :search_attempts,
      :imported_resolution,
      :imported_size,
      :imported_language
    ])
    |> validate_required([:status])
  end
end
