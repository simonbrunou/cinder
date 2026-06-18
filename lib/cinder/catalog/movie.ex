defmodule Cinder.Catalog.Movie do
  @moduledoc """
  A watchlisted movie.

  Created `:requested`; later phases advance `status` through the download pipeline
  (`:searching → :downloading → :downloaded → :available`).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @statuses [:requested, :searching, :downloading, :downloaded, :available]

  schema "movies" do
    field :tmdb_id, :integer
    field :title, :string
    field :year, :integer
    field :poster_path, :string
    field :status, Ecto.Enum, values: @statuses, default: :requested

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(movie, attrs) do
    movie
    |> cast(attrs, [:tmdb_id, :title, :year, :poster_path])
    |> validate_required([:tmdb_id, :title])
    |> unique_constraint(:tmdb_id)
  end
end
