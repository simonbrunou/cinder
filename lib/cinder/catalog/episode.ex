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

  alias Cinder.Catalog.{Grab, Season}

  schema "episodes" do
    field :tmdb_episode_id, :integer
    field :episode_number, :integer
    field :title, :string
    field :air_date, :date
    field :monitored, :boolean, default: true
    field :file_path, :string
    field :search_attempts, :integer, default: 0
    field :import_attempts, :integer, default: 0
    belongs_to :season, Season
    belongs_to :grab, Grab

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

  @doc """
  Changeset for pipeline state writes (no status enum — episode state is derived from
  `file_path`/`grab_id`). Routed through `Cinder.Catalog.transition_episode/2`. `monitored`
  is deliberately excluded: it is not pipeline state and keeps its own writer.
  """
  def transition_changeset(episode, attrs) do
    cast(episode, attrs, [:file_path, :grab_id, :search_attempts, :import_attempts])
  end
end
