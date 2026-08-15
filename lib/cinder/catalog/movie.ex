defmodule Cinder.Catalog.Movie do
  @moduledoc """
  A movie.

  Created `:requested`; the download pipeline advances `status`
  (`:searching → :downloading → :downloaded → :available`), parks it at
  `:no_match` when no release survives the scorer, or `:import_failed` when a
  completed download has no usable file to import.

  `content_path` is the client-delivered download source, written at `:downloaded` and cleared
  back to `nil` once imported; `file_path` is the library file, nil until import writes it. See
  `download_source/1` for the read-side resolution (with a deploy-compat fallback).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog.{Profile, TitleAlias}

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

  @creation_fields [
    :tmdb_id,
    :imdb_id,
    :title,
    :year,
    :poster_path,
    :original_language,
    :preferred_language,
    :media_profile,
    :profile_id,
    :overview,
    :localizations,
    :runtime,
    :genres,
    :vote_average,
    :release_date
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
    field :release_policy_snapshot, :map
    field :verification_hold_origin, Ecto.Enum, values: [:download, :upgrade]
    field :download_progress, :float
    field :download_speed, :integer
    field :download_eta, :integer
    field :download_progress_at, :utc_datetime
    field :file_path, :string
    field :part_file_paths, {:array, :string}, default: []
    field :content_path, :string
    field :import_attempts, :integer, default: 0
    field :search_attempts, :integer, default: 0
    field :original_language, :string
    field :preferred_language, :string, default: "original"
    field :imported_resolution, :string
    field :imported_size, :integer
    field :imported_language, :string
    field :imported_source, :string
    field :imported_audio_languages, {:array, :string}
    field :imported_default_audio_language, :string
    field :imported_embedded_subtitles, {:array, :string}
    field :imported_sidecar_subtitles, {:array, :string}
    field :overview, :string
    field :localizations, :map, default: %{}
    field :runtime, :integer
    field :genres, {:array, :string}
    field :vote_average, :float
    field :release_date, :date
    field :media_profile, Ecto.Enum, values: [:auto, :standard, :anime], default: :auto
    belongs_to :profile, Profile
    field :anime_hold_reason, :string
    field :failure_reason, :string
    field :media_server_item_id, :string
    # Rotation clock for Cinder.Catalog.UpgradeHunter; nil = never checked (sorts first).
    field :upgrade_checked_at, :utc_datetime
    has_many :title_aliases, TitleAlias

    timestamps(type: :utc_datetime)
  end

  @doc """
  The movie's current download source — the client-delivered path for the grab that's in flight
  or just completed. Reads `content_path`, falling back to `file_path` only when `content_path`
  is unset: a movie already `:downloaded` when the `content_path` column shipped has its
  pre-import path sitting in the old field with nothing yet written to the new one. Every writer
  (fresh grab and upgrade alike) now sets `content_path` directly, so the fallback is genuinely
  deploy-compat only — it must NOT be removed while any row written before the `content_path`
  column existed can still be sitting mid-pipeline at restart.
  """
  @spec download_source(%__MODULE__{}) :: String.t() | nil
  def download_source(%__MODULE__{content_path: path}) when path not in [nil, ""], do: path
  def download_source(%__MODULE__{file_path: path}), do: path

  @doc "Changeset for the operator-owned media handling profile."
  def profile_changeset(movie, attrs) do
    movie
    |> cast(attrs, [:media_profile])
    |> check_constraint(:profile_id, name: :movies_profile_integrity)
  end

  @doc "Changeset for the sweep-owned search-time Anime preferences hold marker (see `Catalog.set_anime_hold/2`). Not pipeline status — separate from transition_changeset/2."
  def anime_hold_changeset(movie, attrs), do: cast(movie, attrs, [:anime_hold_reason])

  @doc "Changeset for the media-server inventory reconciler's opaque item id."
  def media_server_changeset(movie, item_id) do
    movie
    |> change(media_server_item_id: item_id)
    |> validate_length(:media_server_item_id, max: 512)
  end

  @doc false
  def creation_fields, do: @creation_fields

  @doc false
  def changeset(movie, attrs) do
    movie
    |> cast(attrs, @creation_fields)
    |> validate_required([:tmdb_id, :title])
    |> validate_inclusion(:preferred_language, Language.preferences())
    |> check_constraint(:profile_id, name: :movies_profile_integrity)
    |> unique_constraint(:tmdb_id)
  end

  @doc "Changeset for the TMDB metadata refresh (`Catalog.enrich_movie/1`). Descriptive, not pipeline state — separate from transition_changeset/2, so it never touches status/download fields."
  def metadata_changeset(movie, attrs) do
    cast(movie, attrs, [
      :overview,
      :localizations,
      :runtime,
      :genres,
      :vote_average,
      :release_date
    ])
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
      :release_policy_snapshot,
      :verification_hold_origin,
      :download_progress,
      :download_speed,
      :download_eta,
      :imdb_id,
      :file_path,
      :part_file_paths,
      :content_path,
      :import_attempts,
      :search_attempts,
      :imported_resolution,
      :imported_size,
      :imported_language,
      :imported_source,
      :imported_audio_languages,
      :imported_default_audio_language,
      :imported_embedded_subtitles,
      :imported_sidecar_subtitles,
      :failure_reason
    ])
    |> reset_download_metrics(movie.status)
    |> advance_download_progress_at(movie)
    |> clear_failure_reason()
    |> validate_required([:status])
    |> validate_number(:import_attempts, greater_than_or_equal_to: 0)
    |> validate_number(:search_attempts, greater_than_or_equal_to: 0)
  end

  @doc "All library files belonging to a movie stack, primary first."
  def file_paths(%__MODULE__{file_path: primary, part_file_paths: parts}) do
    [primary | parts || []]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
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

  @download_active_statuses [:downloading, :upgrading]

  defp advance_download_progress_at(changeset, movie) do
    status = get_field(changeset, :status)
    progress = get_field(changeset, :download_progress)

    if status in @download_active_statuses != movie.status in @download_active_statuses or
         progress_advanced?(movie.download_progress, progress) do
      force_change(changeset, :download_progress_at, DateTime.utc_now(:second))
    else
      changeset
    end
  end

  defp progress_advanced?(previous, current) when is_number(current),
    do: current > (previous || 0)

  defp progress_advanced?(_previous, _current), do: false

  # `failure_reason` only means anything for an :import_failed park (the poller writes the client's
  # detail there); every transition OUT of that state (a retry to :requested, a successful
  # :available) force-clears it, so no path can leave a stale reason on a live row.
  defp clear_failure_reason(changeset) do
    if get_field(changeset, :status) == :import_failed,
      do: changeset,
      else: force_change(changeset, :failure_reason, nil)
  end

  @doc "Changeset for the import-time media-info capture / backfill. Descriptive, not pipeline state — separate from transition_changeset/2, so it never touches status/file/download fields."
  def media_info_changeset(movie, attrs) do
    cast(movie, attrs, [
      :imported_audio_languages,
      :imported_default_audio_language,
      :imported_embedded_subtitles,
      :imported_sidecar_subtitles
    ])
  end
end
