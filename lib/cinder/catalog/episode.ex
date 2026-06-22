defmodule Cinder.Catalog.Episode do
  @moduledoc """
  An episode of a `Cinder.Catalog.Season`.

  M4 carries identity + monitoring only (`tmdb_episode_id` is the stable key M6
  reconciliation matches on across TMDB renumbering). The download/import pipeline
  fields arrive in M5 with the TV poller — and eligibility for grabbing is then
  `monitored AND missing-file AND aired`, never a bare status sweep.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Catalog.Season

  schema "episodes" do
    field :tmdb_episode_id, :integer
    field :episode_number, :integer
    field :title, :string
    field :air_date, :date
    field :monitored, :boolean, default: true
    belongs_to :season, Season

    timestamps(type: :utc_datetime)
  end

  @doc """
  Nested changeset used by `Season.nested_changeset/2`. Does not require `season_id` —
  `cast_assoc` fills the FK after the parent inserts.
  """
  def nested_changeset(episode, attrs) do
    episode
    |> cast(attrs, [:tmdb_episode_id, :episode_number, :title, :air_date, :monitored])
    |> validate_required([:episode_number])
  end
end
