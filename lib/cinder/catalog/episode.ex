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

  alias Cinder.Catalog.{EpisodeCoordinateMembership, Grab, Season}

  schema "episodes" do
    field :tmdb_episode_id, :integer
    field :episode_number, :integer
    field :title, :string
    field :air_date, :date
    field :monitored, :boolean, default: true
    field :file_path, :string
    field :search_attempts, :integer, default: 0
    field :imported_resolution, :string
    field :imported_size, :integer
    field :imported_language, :string
    field :imported_source, :string
    field :imported_audio_languages, {:array, :string}
    field :imported_embedded_subtitles, {:array, :string}
    field :imported_sidecar_subtitles, {:array, :string}

    field :classification, Ecto.Enum,
      values: [:regular, :story_special, :recap, :extra],
      default: :regular

    field :classification_source, :string, default: "legacy"
    field :classification_label, :string
    belongs_to :season, Season
    belongs_to :grab, Grab

    has_many :coordinate_memberships, EpisodeCoordinateMembership, preload_order: [asc: :position]

    has_many :episode_coordinates, through: [:coordinate_memberships, :episode_coordinate]

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for provider-owned episode classification metadata."
  def provider_classification_changeset(episode, attrs) do
    episode
    |> cast(attrs, [:classification, :classification_source, :classification_label])
    |> validate_required([:classification, :classification_source])
  end

  @doc """
  Nested changeset used by `Season.nested_changeset/2`. Does not require `season_id` —
  `cast_assoc` fills the FK after the parent inserts.
  """
  def nested_changeset(episode, attrs) do
    episode
    |> cast(attrs, [
      :tmdb_episode_id,
      :episode_number,
      :title,
      :air_date,
      :monitored,
      :classification,
      :classification_source,
      :classification_label
    ])
    |> validate_required([:episode_number])
  end

  @doc """
  Changeset for pipeline state writes (no status enum — episode state is derived from
  `file_path`/`grab_id`). Routed through `Cinder.Catalog.transition_episode/2`. `monitored`
  is deliberately excluded: it is not pipeline state and keeps its own writer. The post-download
  retry budget lives on the grab (`grab.download_attempts`), not the episode.
  """
  def transition_changeset(episode, attrs) do
    cast(episode, attrs, [
      :file_path,
      :grab_id,
      :search_attempts,
      :imported_resolution,
      :imported_size,
      :imported_language,
      :imported_source,
      :imported_audio_languages,
      :imported_embedded_subtitles,
      :imported_sidecar_subtitles
    ])
  end

  @doc "Changeset for the import-time media-info capture / backfill. Descriptive, not pipeline state — separate from transition_changeset/2, so it never touches status/file/download fields."
  def media_info_changeset(episode, attrs) do
    cast(episode, attrs, [
      :imported_audio_languages,
      :imported_embedded_subtitles,
      :imported_sidecar_subtitles
    ])
  end

  @doc """
  Changeset for the M6 TMDB refresh (`Catalog.refresh_series/1`): identity + placement only.
  `monitored` is castable (set on a brand-new episode) but the refresh caller omits it when
  *updating* an existing row, so a user's monitor toggle is preserved. The `(season_id,
  episode_number)` unique + season FK constraints are registered so a renumber collision returns
  `{:error, changeset}` (and Ecto wraps the write in a savepoint) instead of raising inside the
  reconcile transaction.
  """
  def refresh_changeset(episode, attrs) do
    episode
    |> cast(attrs, [
      :season_id,
      :tmdb_episode_id,
      :episode_number,
      :title,
      :air_date,
      :monitored,
      :classification,
      :classification_source,
      :classification_label
    ])
    |> validate_required([:season_id, :episode_number])
    |> unique_constraint([:season_id, :episode_number])
    |> foreign_key_constraint(:season_id)
  end

  @doc ~S(The "S01E02"-style code for a season/episode number pair.)
  def code(season_number, episode_number), do: "S#{pad(season_number)}E#{pad(episode_number)}"

  @doc ~S(Inverse of `code/2`: the season number from an "SxxEyy"-style code, or nil if it doesn't parse.)
  def season_from_code(value) do
    case Regex.run(~r/^S(\d+)E\d+$/, value) do
      [_, season] -> String.to_integer(season)
      _ -> nil
    end
  end

  @doc "Two-digit minimum zero-padding, never truncated (numbers can exceed 99 on long-running shows)."
  def pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
