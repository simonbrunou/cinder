unless Code.ensure_loaded?(Cinder.Repo.Migrations.StoreIndexerSourceForUpgrades) do
  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20261126010000_store_indexer_source_for_upgrades.exs",
      __DIR__
    )
  )
end

defmodule Cinder.Repo.Migrations.StoreIndexerSourceForUpgradesTest do
  # The release that adds the `indexer_source` setting keeps an install that already uses
  # Prowlarr on Prowlarr (#1651): it stores `indexer_source = "prowlarr"` when `setup_complete`
  # or a `prowlarr_*` row is stored and no `indexer_source` row exists, and changes no other row.
  use ExUnit.Case, async: false

  alias Cinder.MigrationRepoHelpers
  alias Cinder.Repo.Migrations.StoreIndexerSourceForUpgrades
  alias Ecto.Adapters.SQL

  defmodule Repo do
    use Ecto.Repo, otp_app: :cinder, adapter: Ecto.Adapters.SQLite3
  end

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "cinder-indexer-source-migration-#{System.unique_integer([:positive])}.db"
      )

    MigrationRepoHelpers.start_repo!(Repo,
      database: database,
      telemetry_prefix: [:cinder, :indexer_source_migration_test]
    )

    on_exit(fn -> File.rm(database) end)

    query!("""
    CREATE TABLE settings (
      id INTEGER PRIMARY KEY,
      key TEXT NOT NULL UNIQUE,
      value TEXT,
      is_secret INTEGER NOT NULL DEFAULT 0,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    :ok
  end

  for {name, rows} <- [
        {"setup_complete stored", [{"setup_complete", "true", 0}]},
        {"only prowlarr_api_key stored", [{"prowlarr_api_key", "c2VjcmV0", 1}]},
        {"only prowlarr_url stored", [{"prowlarr_url", "http://prowlarr:9696", 0}]}
      ] do
    @rows rows

    test "#{name} adds indexer_source = prowlarr and changes no other row" do
      seed(@rows ++ [{"tmdb_token", "dG9rZW4=", 1}])
      before = all_rows()

      migrate()

      assert all_rows() -- before == [{"indexer_source", "prowlarr", 0}]
      assert before -- all_rows() == []
    end
  end

  test "an empty database gets no row" do
    migrate()

    assert all_rows() == []
  end

  test "an install that stores neither setup_complete nor a prowlarr row gets no row" do
    # `_` in a LIKE pattern matches any one character, so a key that differs from `prowlarr_`
    # only there must not count.
    seed([{"tmdb_token", "dG9rZW4=", 1}, {"prowlarrXurl", "x", 0}, {"jellyfin_url", "x", 0}])
    before = all_rows()

    migrate()

    assert all_rows() == before
  end

  test "an indexer_source row already stored is left as it is" do
    seed([{"setup_complete", "true", 0}, {"indexer_source", "native", 0}])
    before = all_rows()

    migrate()

    assert all_rows() == before
  end

  defp migrate,
    do:
      :ok =
        Ecto.Migrator.up(Repo, 20_261_126_010_000, StoreIndexerSourceForUpgrades, log: false)

  defp seed(rows) do
    for {key, value, secret} <- rows do
      query!(
        "INSERT INTO settings (key, value, is_secret, inserted_at, updated_at) " <>
          "VALUES (?, ?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        [key, value, secret]
      )
    end
  end

  defp all_rows,
    do:
      query!("SELECT key, value, is_secret FROM settings ORDER BY key").rows
      |> Enum.map(&List.to_tuple/1)

  defp query!(sql, params \\ []), do: SQL.query!(Repo, sql, params)
end
