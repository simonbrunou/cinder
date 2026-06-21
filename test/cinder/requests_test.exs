defmodule Cinder.RequestsTest do
  use Cinder.DataCase, async: false
  alias Cinder.Catalog
  alias Cinder.Catalog.Movie
  alias Cinder.Requests
  import Cinder.AccountsFixtures

  @attrs %{
    target_type: "movie",
    target_id: 603,
    title: "The Matrix",
    year: 1999,
    poster_path: "/p.jpg"
  }

  test "a non-admin request is pending and creates NO movie (the gate)" do
    user = user_fixture()
    assert {:ok, req} = Requests.create_request(user, @attrs)
    assert req.status == :pending
    assert Repo.aggregate(Movie, :count) == 0
    assert Catalog.list_by_status(:requested) == []
  end

  test "an admin request auto-approves and creates the movie" do
    admin = admin_fixture()
    assert {:ok, req} = Requests.create_request(admin, @attrs)
    assert req.status == :approved
    assert req.approved_by_id == admin.id
    assert [%Movie{status: :requested, tmdb_id: 603}] = Catalog.list_by_status(:requested)
  end

  test "approve_request creates the movie and marks approved" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    assert {:ok, approved} = Requests.approve_request(req, admin)
    assert approved.status == :approved
    assert approved.approved_by_id == admin.id
    assert [%Movie{status: :requested}] = Catalog.list_by_status(:requested)
  end

  test "approving an already-available movie does not reset it" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 603, title: "The Matrix"})
    {:ok, _} = Catalog.transition(movie, %{status: :available})
    {:ok, _} = Requests.approve_request(req, admin)
    assert [%Movie{status: :available}] = Catalog.list_by_status(:available)
    assert Catalog.list_by_status(:requested) == []
  end

  test "deny_request sets denied + reason" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    assert {:ok, denied} = Requests.deny_request(req, admin, "not for the household")
    assert denied.status == :denied
    assert denied.denial_reason == "not for the household"
  end

  test "approve/deny only act on pending requests" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    {:ok, approved} = Requests.approve_request(req, admin)
    assert {:error, :not_pending} = Requests.deny_request(approved, admin, "x")
  end

  test "no duplicate pending request for the same target" do
    user = user_fixture()
    {:ok, _} = Requests.create_request(user, @attrs)
    assert {:error, _} = Requests.create_request(user, @attrs)
  end

  test "a user can re-request the same target after it was denied" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    {:ok, _} = Requests.deny_request(req, admin, "not this time")
    # The partial unique index only blocks duplicates WHERE status='pending',
    # so a denied row must not prevent a fresh pending request.
    assert {:ok, %{status: :pending}} = Requests.create_request(user, @attrs)
  end

  test "auto_approve_all on → a non-admin add creates the movie" do
    Cinder.Settings.put("auto_approve_all", "true")
    user = user_fixture()
    assert {:ok, %{status: :approved}} = Requests.create_request(user, @attrs)
    assert [%Movie{status: :requested}] = Catalog.list_by_status(:requested)
  end
end
