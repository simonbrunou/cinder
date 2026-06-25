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

  alias Cinder.Catalog.Season

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
    has_many :seasons, Season

    timestamps(type: :utc_datetime)
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
      :preferred_language
    ])
    |> validate_required([:tmdb_id, :title])
    |> validate_inclusion(:preferred_language, ["original", "french", "any"])
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
    cast(series, attrs, [:tvdb_id, :title, :year, :poster_path, :original_language])
  end

  @doc "Changeset for the in-app series language edit. Excluded from refresh/admin changesets so it survives a TMDB resync."
  def language_changeset(series, attrs) do
    series
    |> cast(attrs, [:preferred_language])
    |> validate_inclusion(:preferred_language, ["original", "french", "any"])
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
