defmodule Cinder.Catalog.Series do
  @moduledoc """
  A monitored TV series and its season/episode tree.

  `monitor_strategy` decides which episodes are flagged `monitored` when the series
  is added (`:all` everything, `:future` only un-aired/undated — the default, so a
  new show doesn't flood the client, `:none` nothing). Series/seasons/episodes carry
  monitoring only in M4; the download/import pipeline fields arrive in M5 with the TV
  poller.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Acquisition.{AnimePreferences, Language}
  alias Cinder.Catalog.{EpisodeCoordinate, Season, TitleAlias}

  @monitor_strategies [:all, :future, :none]

  schema "series" do
    field :tmdb_id, :integer
    field :tvdb_id, :integer
    field :title, :string
    field :year, :integer
    field :poster_path, :string
    field :monitored, :boolean, default: true
    field :monitor_strategy, Ecto.Enum, values: @monitor_strategies, default: :future
    field :original_language, :string
    field :preferred_language, :string, default: "original"
    field :audio_mode, Ecto.Enum, values: [:original, :dub, :dual, :any]
    field :subtitle_languages, {:array, :string}
    field :embedded_subtitle_mode, Ecto.Enum, values: [:allow, :prefer, :require]
    field :preferred_release_groups, {:array, :string}
    field :blocked_release_groups, {:array, :string}
    field :group_fallback_delay, :integer
    field :overview, :string
    field :genres, {:array, :string}
    field :vote_average, :float
    field :first_air_date, :date
    field :media_profile, Ecto.Enum, values: [:auto, :standard, :anime], default: :auto
    has_many :seasons, Season
    has_many :title_aliases, TitleAlias
    has_many :episode_coordinates, EpisodeCoordinate

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for the operator-owned media handling profile."
  def profile_changeset(series, attrs), do: cast(series, attrs, [:media_profile])

  @anime_preference_fields [
    :audio_mode,
    :subtitle_languages,
    :embedded_subtitle_mode,
    :preferred_release_groups,
    :blocked_release_groups,
    :group_fallback_delay
  ]

  def anime_preferences_changeset(series, attrs) do
    series
    |> cast(attrs, @anime_preference_fields)
    |> validate_number(:group_fallback_delay, greater_than_or_equal_to: 0)
    |> update_change(:subtitle_languages, &AnimePreferences.normalize_optional_languages/1)
    |> update_change(
      :preferred_release_groups,
      &AnimePreferences.normalize_optional_groups/1
    )
    |> update_change(:blocked_release_groups, &AnimePreferences.normalize_optional_groups/1)
  end

  @doc "The valid `monitor_strategy` values."
  def monitor_strategies, do: @monitor_strategies

  @doc """
  Changeset for inserting a series together with its full season/episode tree (one
  `Repo.insert` = one transaction). The unique index on `tmdb_id` is left un-named
  (column-derived) so a duplicate surfaces as `{:error, changeset}`, not a raise.
  """
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :tmdb_id,
      :tvdb_id,
      :title,
      :year,
      :poster_path,
      :monitored,
      :monitor_strategy,
      :original_language,
      :preferred_language,
      :overview,
      :genres,
      :vote_average,
      :first_air_date,
      :media_profile
    ])
    |> validate_required([:tmdb_id, :title])
    |> validate_inclusion(:preferred_language, Language.preferences())
    |> cast_assoc(:seasons, with: &Season.nested_changeset/2)
    |> unique_constraint(:tmdb_id)
  end

  @doc """
  Changeset for the M6 TMDB refresh (`Catalog.refresh_series/1`): backfills the
  TMDB-sourced descriptive fields (`tvdb_id` is the acquisition disambiguation key, often
  nil at add time). `tmdb_id` (identity), `monitored`, and `monitor_strategy`
  (user-controlled) are deliberately NOT castable so a refresh preserves them.
  """
  def refresh_changeset(series, attrs) do
    cast(series, attrs, [
      :tvdb_id,
      :title,
      :year,
      :poster_path,
      :original_language,
      :overview,
      :genres,
      :vote_average,
      :first_air_date
    ])
  end

  @doc "Changeset for the TMDB metadata refresh (`Catalog.enrich_series/1`). Descriptive only; excludes identity/monitoring so a refresh can't disturb the tree."
  def metadata_changeset(series, attrs) do
    cast(series, attrs, [:overview, :genres, :vote_average, :first_air_date])
  end

  @doc "Changeset for the in-app series language edit. Excluded from refresh/admin changesets so it survives a TMDB resync."
  def language_changeset(series, attrs) do
    series
    |> cast(attrs, [:preferred_language])
    |> validate_inclusion(:preferred_language, Language.preferences())
  end

  @doc """
  Changeset for the admin metadata edit (`Catalog.update_series/2`). Casts only the
  descriptive fields — `monitor_strategy` and `monitored` are deliberately NOT castable so
  an admin title/year edit never cascades a strategy change onto existing seasons/episodes
  (the request flow sets `monitor_strategy: :none` while flipping per-season `monitored: true`;
  casting strategy here would clobber that — `refresh_changeset/2` excludes it for the same reason).
  """
  def admin_changeset(series, attrs) do
    series
    |> cast(attrs, [:tvdb_id, :title, :year, :poster_path])
    |> validate_required([:title])
  end
end
