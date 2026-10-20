defmodule Cinder.AuditTest do
  use Cinder.DataCase, async: true

  import Cinder.AccountsFixtures
  import ExUnit.CaptureLog

  alias Cinder.Audit
  alias Cinder.Audit.AdminAudit
  alias Cinder.Catalog

  describe "log/4" do
    test "writes an audit row from an actor, action, entity struct, and detail map" do
      admin = admin_fixture()
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 1, title: "M"})

      assert {:ok, %AdminAudit{} = row} =
               Audit.log(admin, :delete_movie, movie, %{title: "M"})

      assert row.actor_id == admin.id
      assert row.action == "delete_movie"
      assert row.entity_type == "Movie"
      assert row.entity_id == movie.id
      assert row.detail == %{title: "M"}
      assert %DateTime{} = row.inserted_at
    end

    test "accepts a {type, id} tuple entity" do
      admin = admin_fixture()
      assert {:ok, row} = Audit.log(admin, :delete_user, {"User", 99}, %{email: "x@y.z"})
      assert row.entity_type == "User"
      assert row.entity_id == 99
    end

    test "accepts a nil actor (system action) without crashing" do
      assert {:ok, row} = Audit.log(nil, :purge, {"Grab", 5}, %{})
      assert row.actor_id == nil
    end

    test "rolls back with the caller's transaction (no orphan audit row)" do
      admin = admin_fixture()

      result =
        Repo.transaction(fn ->
          {:ok, _} = Audit.log(admin, :delete_movie, {"Movie", 1}, %{})
          Repo.rollback(:boom)
        end)

      assert result == {:error, :boom}
      assert Repo.aggregate(AdminAudit, :count) == 0
    end
  end

  describe "log_or_rollback/4" do
    test "returns the audit entry on success" do
      admin = admin_fixture()
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 2, title: "N"})

      assert {:ok, %AdminAudit{} = row} =
               Repo.transaction(fn ->
                 Audit.log_or_rollback(admin, :delete_movie, movie, %{title: "N"})
               end)

      assert row.action == "delete_movie"
      assert row.entity_type == "Movie"
      assert row.entity_id == movie.id
      assert Repo.aggregate(AdminAudit, :count) == 1
    end

    test "rolls back the enclosing transaction when the audit write fails" do
      admin = admin_fixture()

      # A blank action fails validate_required([:action]) → log/4 returns {:error, _},
      # so log_or_rollback/4 rolls the enclosing transaction back with the changeset.
      result =
        Repo.transaction(fn ->
          Audit.log_or_rollback(admin, "", admin, %{})
        end)

      assert {:error, %Ecto.Changeset{}} = result
      assert Repo.aggregate(AdminAudit, :count) == 0
    end
  end

  describe "log_or_warn/4" do
    test "writes the audit row of an action that already happened" do
      admin = admin_fixture()

      assert :ok = Audit.log_or_warn(admin, :delete_movie, {"Movie", 3}, %{title: "O"})

      assert [%AdminAudit{action: "delete_movie", entity_id: 3}] = Repo.all(AdminAudit)
    end

    test "logs a refused audit row and still returns :ok" do
      admin = admin_fixture()

      log =
        capture_log(fn ->
          assert :ok = Audit.log_or_warn(admin, "", {"Movie", 4}, %{title: "P"})
        end)

      assert log =~ "audit row failed for Movie 4"
      assert log =~ ~s(title: "P")
      assert Repo.aggregate(AdminAudit, :count) == 0
    end
  end
end
