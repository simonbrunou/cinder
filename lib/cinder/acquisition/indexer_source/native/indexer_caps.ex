defmodule Cinder.Acquisition.IndexerSource.Native.IndexerCaps do
  @moduledoc """
  The caps table (#1652): one row per Newznab or Torznab configured indexer, holding its parsed
  `t=caps` answer (`Cinder.Acquisition.Indexer.Newznab.Caps`). It is runtime state of
  `Cinder.Acquisition.IndexerSource.Native`, written only here; `Cinder.Indexers` never writes it,
  and deleting the configured indexer deletes its row (`ON DELETE CASCADE`).

  A row is used for 7 days from its `fetched_at`, as Prowlarr keeps caps, and only while its
  `config_version` equals the configured indexer's (`Cinder.Indexers` raises that counter on a
  base URL, API path, settings, FlareSolverr or secret change). `read/2` refetches before
  answering when the row is 7 days old or more, under another version or missing. A failed
  fetch answers its error and changes no row: after a failed `read/2` refetch the old row stays
  unusable, so the next read fetches again, and after a failed `refetch/2` a row still usable
  answers the next read. A fetch that succeeds for an indexer deleted meanwhile answers its caps
  and stores no row.

  The clock is the `clock` of `config :cinder, Cinder.Acquisition.IndexerSource.Native`, a 0-arity
  function returning a `DateTime`, `DateTime.utc_now/0` by default.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Repo

  @type caps :: map()
  @type fetch :: (-> {:ok, caps()} | {:error, term()})

  @max_age_us 7 * 24 * 60 * 60 * 1_000_000

  @primary_key {:configured_indexer_id, :id, autogenerate: false}
  schema "native_indexer_caps" do
    field :config_version, :integer
    field :caps, :map
    field :fetched_at, :utc_datetime_usec
  end

  @doc """
  The caps of `indexer`: its row's when the row is usable (see the moduledoc), else what `fetch`
  answers, stored on success while the indexer still exists.
  """
  @spec read(ConfiguredIndexer.t(), fetch()) :: {:ok, caps()} | {:error, term()}
  def read(%ConfiguredIndexer{id: id} = indexer, fetch) do
    case Repo.get(__MODULE__, id) do
      %__MODULE__{} = row ->
        if usable?(row, indexer), do: {:ok, row.caps}, else: refetch(indexer, fetch)

      nil ->
        refetch(indexer, fetch)
    end
  end

  @doc """
  Fetches the caps of `indexer` with `fetch` whatever its row holds, and stores them on success
  under the indexer's `config_version` while the indexer still exists. A failed fetch answers its
  error and changes no row.
  """
  @spec refetch(ConfiguredIndexer.t(), fetch()) :: {:ok, caps()} | {:error, term()}
  def refetch(%ConfiguredIndexer{} = indexer, fetch) do
    with {:ok, caps} <- fetch.() do
      store(indexer, caps)
      {:ok, caps}
    end
  end

  defp usable?(row, indexer) do
    row.config_version == indexer.config_version and
      DateTime.diff(now(), row.fetched_at, :microsecond) < @max_age_us
  end

  # A configured indexer deleted while its caps were fetched has no row to point at: the insert
  # fails on the foreign key, and the caps fetched still answer this read. ecto_sqlite3 reports
  # that failure with no constraint name, which no `Ecto.Changeset.foreign_key_constraint/3`
  # matches, so it raises and is rescued here.
  defp store(indexer, caps) do
    %__MODULE__{configured_indexer_id: indexer.id}
    |> change(config_version: indexer.config_version, caps: caps, fetched_at: now())
    |> Repo.insert(
      on_conflict: {:replace, [:config_version, :caps, :fetched_at]},
      conflict_target: :configured_indexer_id
    )
  rescue
    error in Ecto.ConstraintError ->
      if error.type == :foreign_key, do: :indexer_gone, else: reraise(error, __STACKTRACE__)
  end

  # `fetched_at` stores microseconds, which a clock answering whole seconds lacks.
  defp now do
    clock = :cinder |> Application.get_env(Native, []) |> Keyword.get(:clock, &DateTime.utc_now/0)
    %DateTime{microsecond: {microseconds, _precision}} = now = clock.()
    %{now | microsecond: {microseconds, 6}}
  end
end
