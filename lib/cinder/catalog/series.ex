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
      :monitor_strategy
    ])
    |> validate_required([:tmdb_id, :title])
    |> cast_assoc(:seasons, with: &Season.nested_changeset/2)
    |> unique_constraint(:tmdb_id)
  end
end
