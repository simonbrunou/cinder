defmodule CinderWeb.DatabaseSnapshotControllerTest do
  use CinderWeb.ConnCase, async: false

  import Cinder.AccountsFixtures

  alias Cinder.Disk
  alias Cinder.Repo
  alias Exqlite.Sqlite3

  describe "GET /settings/database-backup" do
    test "requires authentication", %{conn: conn} do
      conn = get(conn, ~p"/settings/database-backup")

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "rejects a non-admin", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/settings/database-backup")

      assert redirected_to(conn) == ~p"/"
    end

    @tag :unboxed
    test "downloads a self-contained snapshot and removes the server-side temporary file", %{
      conn: conn
    } do
      admin = admin_fixture()

      try do
        snapshot_files = snapshot_files()
        conn = conn |> log_in_user(admin) |> get(~p"/settings/database-backup")

        assert get_resp_header(conn, "content-type") == ["application/vnd.sqlite3"]
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert [disposition] = get_resp_header(conn, "content-disposition")
        assert disposition =~ "attachment"
        assert disposition =~ "cinder-backup-"
        assert conn.resp_body =~ <<"SQLite format 3", 0>>
        assert snapshot_files() == snapshot_files

        assert_snapshot(conn.resp_body, admin)
      after
        Repo.delete!(admin)
      end
    end
  end

  defp assert_snapshot(body, admin) do
    path =
      Path.join(
        System.tmp_dir!(),
        "cinder-snapshot-response-#{System.unique_integer([:positive])}.sqlite3"
      )

    try do
      File.write!(path, body, [:exclusive])
      {:ok, database} = Sqlite3.open(path)

      try do
        assert query(database, "PRAGMA integrity_check") == [["ok"]]

        assert query(database, "SELECT email FROM users WHERE id = ?", [admin.id]) == [
                 [admin.email]
               ]
      after
        Sqlite3.close(database)
      end
    after
      File.rm(path)
    end
  end

  defp snapshot_files do
    Path.wildcard(Path.join(Disk.db_root(), ".cinder-snapshot-*.sqlite3"))
  end

  defp query(database, sql, params \\ []) do
    {:ok, statement} = Sqlite3.prepare(database, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      {:ok, rows} = Sqlite3.fetch_all(database, statement)
      rows
    after
      Sqlite3.release(database, statement)
    end
  end
end
