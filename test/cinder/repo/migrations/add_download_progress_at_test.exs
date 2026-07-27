unless Code.ensure_loaded?(Cinder.Repo.Migrations.AddDownloadProgressAt) do
  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20260727005136_add_download_progress_at.exs",
      __DIR__
    )
  )
end

defmodule Cinder.Repo.Migrations.AddDownloadProgressAtTest do
  use ExUnit.Case, async: false

  alias Cinder.Repo.Migrations.AddDownloadProgressAt
  alias Ecto.Adapters.SQL

  defmodule Repo do
    use Ecto.Repo, otp_app: :cinder, adapter: Ecto.Adapters.SQLite3
  end

  test "seeds existing movie and grab clocks from updated_at" do
    database =
      Path.join(
        System.tmp_dir!(),
        "cinder-progress-clock-migration-#{System.unique_integer([:positive])}.db"
      )

    start_supervised!(
      {Repo,
       database: database,
       pool_size: 1,
       telemetry_prefix: [:cinder, :progress_clock_migration_test]}
    )

    on_exit(fn -> File.rm(database) end)

    create_pre_migration_table("movies")
    create_pre_migration_table("grabs")

    timestamp = "2026-07-26T12:34:56"

    for table <- ["movies", "grabs"] do
      query!("INSERT INTO #{table} (updated_at) VALUES (?)", [timestamp])
    end

    :ok = Ecto.Migrator.up(Repo, 20_260_727_005_136, AddDownloadProgressAt, log: false)

    for table <- ["movies", "grabs"] do
      assert %{rows: [[^timestamp, ^timestamp]]} =
               query!("SELECT download_progress_at, updated_at FROM #{table}")
    end
  end

  defp create_pre_migration_table(table) do
    query!("CREATE TABLE #{table} (id INTEGER PRIMARY KEY, updated_at TEXT NOT NULL)")
  end

  defp query!(sql, params \\ []), do: SQL.query!(Repo, sql, params)
end
