unless Code.ensure_loaded?(Cinder.Repo.Migrations.PreventDuplicateActiveRequests) do
  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20260826062000_prevent_duplicate_active_requests.exs",
      __DIR__
    )
  )
end

defmodule Cinder.Repo.Migrations.PreventDuplicateActiveRequestsTest do
  use ExUnit.Case, async: false

  alias Cinder.Repo.Migrations.PreventDuplicateActiveRequests
  alias Ecto.Adapters.SQL

  @version 20_260_826_062_000

  defmodule Repo do
    use Ecto.Repo, otp_app: :cinder, adapter: Ecto.Adapters.SQLite3
  end

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "cinder-active-request-migration-#{System.unique_integer([:positive])}.db"
      )

    start_supervised!(
      {Repo,
       database: database, pool_size: 1, telemetry_prefix: [:cinder, :request_migration_test]}
    )

    on_exit(fn -> File.rm(database) end)

    query!("""
    CREATE TABLE requests (
      id INTEGER PRIMARY KEY,
      user_id INTEGER NOT NULL,
      target_type TEXT NOT NULL,
      target_id INTEGER NOT NULL,
      season_number INTEGER,
      media_kind TEXT,
      status TEXT NOT NULL
    )
    """)

    query!("""
    CREATE UNIQUE INDEX requests_pending_unique
    ON requests (
      user_id,
      target_type,
      target_id,
      COALESCE(season_number, -1),
      COALESCE(media_kind, '')
    )
    WHERE status = 'pending'
    """)

    :ok
  end

  test "up blocks duplicate active rows and down restores the pending-only predicate" do
    insert_request(1, "pending")
    insert_request(2, "denied")

    :ok = Ecto.Migrator.up(Repo, @version, PreventDuplicateActiveRequests, log: false)

    assert index_sql() =~ "status IN ('pending', 'approved')"

    assert_raise Exqlite.Error, ~r/UNIQUE constraint failed/, fn ->
      insert_request(3, "approved")
    end

    query!("DELETE FROM requests WHERE status = 'pending'")
    insert_request(3, "approved")

    assert_raise Exqlite.Error, ~r/UNIQUE constraint failed/, fn ->
      insert_request(4, "approved")
    end

    :ok = Ecto.Migrator.down(Repo, @version, PreventDuplicateActiveRequests, log: false)

    assert index_sql() =~ "status = 'pending'"
    insert_request(4, "approved")
  end

  test "up preserves rows and the old index when active duplicates already exist" do
    insert_request(1, "pending")
    insert_request(2, "approved")

    assert_raise RuntimeError, ~r/cannot enforce active request uniqueness/, fn ->
      Ecto.Migrator.up(Repo, @version, PreventDuplicateActiveRequests, log: false)
    end

    assert %{rows: [[2]]} = query!("SELECT COUNT(*) FROM requests")
    assert index_sql() =~ "status = 'pending'"
  end

  defp insert_request(id, status) do
    query!("""
    INSERT INTO requests (id, user_id, target_type, target_id, status)
    VALUES (#{id}, 7, 'movie', 603, '#{status}')
    """)
  end

  defp index_sql do
    query!("SELECT sql FROM sqlite_master WHERE name = 'requests_pending_unique'").rows
    |> List.first()
    |> List.first()
  end

  defp query!(sql, params \\ []), do: SQL.query!(Repo, sql, params)
end
