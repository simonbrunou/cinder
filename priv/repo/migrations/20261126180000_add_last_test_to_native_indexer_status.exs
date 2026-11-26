defmodule Cinder.Repo.Migrations.AddLastTestToNativeIndexerStatus do
  use Ecto.Migration

  # The last per-indexer Test's outcome and time beside the backoff state (#1657): a closed tag,
  # an integer code (an HTTP status or a Newznab error code) and a time, never a URL, header or
  # body. A search's write leaves them as they are.
  def change do
    alter table(:native_indexer_status) do
      add :last_test, :string
      add :last_test_code, :integer
      add :last_test_at, :utc_datetime
    end
  end
end
