defmodule Cinder.Catalog.Season do
  @moduledoc "A season of a `Cinder.Catalog.Series` and its episodes."
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Catalog.{Episode, Series}

  schema "seasons" do
    field :season_number, :integer
    field :monitored, :boolean, default: true
    belongs_to :series, Series
    has_many :episodes, Episode

    timestamps(type: :utc_datetime)
  end

  @doc """
  Nested changeset used by `Series.create_changeset/1`. Does not require `series_id` —
  `cast_assoc` fills the FK after the parent inserts.
  """
  def nested_changeset(season, attrs) do
    season
    |> cast(attrs, [:season_number, :monitored])
    |> validate_required([:season_number])
    |> cast_assoc(:episodes, with: &Episode.nested_changeset/2)
  end

  @doc """
  Changeset for inserting a season discovered by the M6 TMDB refresh (`Catalog.refresh_series/1`),
  outside the `cast_assoc` create path. Registers the `(series_id, season_number)` unique + series
  FK constraints so an unexpected duplicate returns `{:error, changeset}` rather than raising.
  """
  def refresh_changeset(season, attrs) do
    season
    |> cast(attrs, [:series_id, :season_number, :monitored])
    |> validate_required([:series_id, :season_number])
    |> unique_constraint([:series_id, :season_number])
    |> foreign_key_constraint(:series_id)
  end
end
