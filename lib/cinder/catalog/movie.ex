defmodule Cinder.Catalog.Movie do
  @moduledoc """
  A movie.

  Created `:requested`; the download pipeline advances `status`
  (`:searching → :downloading → :downloaded → :available`), parks it at
  `:no_match` when no release survives the scorer, or `:import_failed` when a
  completed download has no usable file to import.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog.TitleAlias

  @statuses [
    :requested,
    :searching,
    :downloading,
    :downloaded,
    :available,
    :upgrading,
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
    field :release_title, :string
    field :download_progress, :float
    field :download_speed, :integer
    field :download_eta, :integer
    field :file_path, :string
    field :import_attempts, :integer, default: 0
    field :search_attempts, :integer, default: 0
    field :original_language, :string
    field :preferred_language, :string, default: "original"
    field :imported_resolution, :string
    field :imported_size, :integer
    field :imported_language, :string
    field :imported_source, :string
    field :imported_audio_languages, {:array, :string}
    field :imported_embedded_subtitles, {:array, :string}
    field :imported_sidecar_subtitles, {:array, :string}
    field :overview, :string
    field :runtime, :integer
    field :genres, {:array, :string}
    field :vote_average, :float
    field :release_date, :date
    field :media_profile, Ecto.Enum, values: [:auto, :standard, :anime], default: :auto
    has_many :title_aliases, TitleAlias

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for the operator-owned media handling profile."
  def profile_changeset(movie, attrs), do: cast(movie, attrs, [:media_profile])

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
      :preferred_language,
      :media_profile
    ])
    |> validate_required([:tmdb_id, :title])
    |> validate_inclusion(:preferred_language, Language.preferences())
    |> unique_constraint(:tmdb_id)
  end

  @doc "Changeset for the TMDB metadata refresh (`Catalog.enrich_movie/1`). Descriptive, not pipeline state — separate from transition_changeset/2, so it never touches status/download fields."
  def metadata_changeset(movie, attrs) do
    cast(movie, attrs, [:overview, :runtime, :genres, :vote_average, :release_date])
  end

  @doc "Changeset for the in-app language edit (escape hatch). Not pipeline state — separate from transition_changeset/2."
  def language_changeset(movie, attrs) do
    movie
    |> cast(attrs, [:preferred_language])
    |> validate_inclusion(:preferred_language, Language.preferences())
  end

  @doc "Changeset for pipeline state transitions (status + optional download_id/download_protocol/imdb_id/file_path/attempt counters)."
  def transition_changeset(movie, attrs) do
    movie
    |> cast(attrs, [
      :status,
      :download_id,
      :download_protocol,
      :release_title,
      :download_progress,
      :download_speed,
      :download_eta,
      :imdb_id,
      :file_path,
      :import_attempts,
      :search_attempts,
      :imported_resolution,
      :imported_size,
      :imported_language,
      :imported_source,
      :imported_audio_languages,
      :imported_embedded_subtitles,
      :imported_sidecar_subtitles
    ])
    |> reset_download_metrics(movie.status)
    |> validate_required([:status])
  end

  defp reset_download_metrics(changeset, previous_status) do
    status = get_field(changeset, :status)

    if status not in [:downloading, :upgrading] or status != previous_status do
      changeset
      |> force_change(:download_progress, nil)
      |> force_change(:download_speed, nil)
      |> force_change(:download_eta, nil)
    else
      changeset
    end
  end

  @doc "Changeset for the import-time media-info capture / backfill. Descriptive, not pipeline state — separate from transition_changeset/2, so it never touches status/file/download fields."
  def media_info_changeset(movie, attrs) do
    cast(movie, attrs, [
      :imported_audio_languages,
      :imported_embedded_subtitles,
      :imported_sidecar_subtitles
    ])
  end
end
