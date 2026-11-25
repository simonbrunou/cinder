unless Code.ensure_loaded?(Cinder.Repo.Migrations.AddIndexerSourceToBlockedReleases) do
  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20261125190543_add_indexer_source_to_blocked_releases.exs",
      __DIR__
    )
  )
end

defmodule Cinder.Repo.Migrations.AddIndexerSourceToBlockedReleasesTest do
  use ExUnit.Case, async: false

  alias Cinder.MigrationRepoHelpers
  alias Cinder.Repo.Migrations.AddIndexerSourceToBlockedReleases
  alias Ecto.Adapters.SQL

  defmodule Repo do
    use Ecto.Repo, otp_app: :cinder, adapter: Ecto.Adapters.SQLite3
  end

  @version 20_261_125_190_543

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

    query!("CREATE TABLE blocked_releases (id INTEGER PRIMARY KEY, indexer_id INTEGER)")
    :ok
  end

  # Every row with an indexer id was written under Prowlarr, the one source before #1645.
  test "a row with an indexer id reads the Prowlarr source and a row with none reads no source" do
    for id <- [3, nil, 7],
        do: query!("INSERT INTO blocked_releases (indexer_id) VALUES (?)", [id])

    :ok = Ecto.Migrator.up(Repo, @version, AddIndexerSourceToBlockedReleases, log: false)

    assert query!("SELECT indexer_id, indexer_source FROM blocked_releases ORDER BY id").rows ==
             [[3, "prowlarr"], [nil, nil], [7, "prowlarr"]]
  end

  test "down drops the column" do
    :ok = Ecto.Migrator.up(Repo, @version, AddIndexerSourceToBlockedReleases, log: false)
    :ok = Ecto.Migrator.down(Repo, @version, AddIndexerSourceToBlockedReleases, log: false)

    columns = query!("SELECT name FROM pragma_table_info('blocked_releases')").rows
    assert columns == [["id"], ["indexer_id"]]
  end

  defp query!(sql, params \\ []), do: SQL.query!(Repo, sql, params)
end
