unless Code.ensure_loaded?(Cinder.Repo.Migrations.RenameDownloadFailureReasons) do
  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20261020120000_rename_download_failure_reasons.exs",
      __DIR__
    )
  )
end

defmodule Cinder.Repo.Migrations.RenameDownloadFailureReasonsTest do
  use ExUnit.Case, async: false

  alias Cinder.Repo.Migrations.RenameDownloadFailureReasons
  alias Ecto.Adapters.SQL

  defmodule Repo do
    use Ecto.Repo, otp_app: :cinder, adapter: Ecto.Adapters.SQLite3
  end

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "cinder-failure-reasons-migration-#{System.unique_integer([:positive])}.db"
      )

    start_supervised!(
      {Repo,
       database: database,
       pool_size: 1,
       telemetry_prefix: [:cinder, :failure_reasons_migration_test]}
    )

    on_exit(fn -> File.rm(database) end)

    query!("CREATE TABLE blocked_releases (id INTEGER PRIMARY KEY, reason TEXT)")
    query!("CREATE TABLE book_blocked_releases (id INTEGER PRIMARY KEY, reason TEXT NOT NULL)")
    query!("CREATE TABLE book_targets (id INTEGER PRIMARY KEY, hold_reason TEXT)")
    :ok
  end

  test "renames the retired vanished-job names on movie and TV blocklist rows" do
    seed("blocked_releases", "reason", ~w(torrent_not_found stalled no_content_path no_upgrade))
    insert("blocked_releases", "reason", nil)

    migrate()

    assert column("blocked_releases", "reason") ==
             ["download_not_found", "stalled", "no_content_path", "no_upgrade", nil]
  end

  # A book hold reason is free text: an atom's name, `code: detail`, or a client's bare detail.
  # Only an exact retired name changes; a detail that happens to contain one does not.
  for {table, column} <- [{"book_targets", "hold_reason"}, {"book_blocked_releases", "reason"}] do
    @table table
    @column column

    test "renames the retired book names in #{table}.#{column}" do
      seed(@table, @column, [
        "torrent_not_found",
        "download_missing",
        "missing_content_path",
        "download_failed",
        "download_error: torrent_not_found",
        "blocked_content: setup.exe",
        "stalled",
        "no_content_path"
      ])

      migrate()

      assert column(@table, @column) == [
               "download_not_found",
               "download_not_found",
               "no_content_path",
               "download_failed",
               "download_error: torrent_not_found",
               "blocked_content: setup.exe",
               "stalled",
               "no_content_path"
             ]
    end
  end

  defp migrate,
    do:
      :ok =
        Ecto.Migrator.up(Repo, 20_261_020_120_000, RenameDownloadFailureReasons, log: false)

  defp seed(table, column, values), do: Enum.each(values, &insert(table, column, &1))

  defp insert(table, column, value),
    do: query!("INSERT INTO #{table} (#{column}) VALUES (?)", [value])

  defp column(table, column),
    do: query!("SELECT #{column} FROM #{table} ORDER BY id").rows |> Enum.map(&hd/1)

  defp query!(sql, params \\ []), do: SQL.query!(Repo, sql, params)
end
