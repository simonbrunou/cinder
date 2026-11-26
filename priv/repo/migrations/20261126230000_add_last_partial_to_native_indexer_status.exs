defmodule Cinder.Repo.Migrations.AddLastPartialToNativeIndexerStatus do
  use Ecto.Migration

  # The last partial search answer of a Cardigann indexer (#1671): a regex limit or the
  # filter-chain cap failed one query and started no backoff. A closed tag and a time, never a
  # URL, header or body.
  def change do
    alter table(:native_indexer_status) do
      add :last_partial, :string
      add :last_partial_at, :utc_datetime
    end
  end
end
