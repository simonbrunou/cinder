defmodule Cinder.Repo.Migrations.StoreIndexerSourceForUpgrades do
  use Ecto.Migration

  # #1651: the release that adds the `indexer_source` setting keeps an install that already uses
  # Prowlarr on Prowlarr. An install that finished setup or stores any `prowlarr_*` row gets
  # `indexer_source = "prowlarr"`, unless it already stores an `indexer_source` row. It adds that
  # one row and changes no other. `\_` keeps the LIKE's `_` a literal underscore.
  def up do
    execute("""
    INSERT INTO settings (key, value, is_secret, inserted_at, updated_at)
    SELECT 'indexer_source', 'prowlarr', 0,
           strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = 'indexer_source')
      AND EXISTS (
        SELECT 1 FROM settings
        WHERE key = 'setup_complete' OR key LIKE 'prowlarr\\_%' ESCAPE '\\'
      )
    """)
  end

  # The row may since hold a choice the admin made, so rolling back leaves it in place.
  def down, do: :ok
end
