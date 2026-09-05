defmodule CinderWeb.ActivityBeaconLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Accounts
  alias Cinder.Catalog

  setup :register_and_log_in_admin

  # The beacon is rendered standalone (via root.html.heex in the real app), outside every
  # router live_session, so mount it in isolation but with the same session shape UserAuth's
  # on_mount hooks read: a real "user_token" for a current, active admin. A fresh, unlogged-in
  # conn is required — `live_isolated/3` MERGES its `session:` opt on top of whatever the given
  # conn's own Plug session already carries, so reusing a conn that `register_and_log_in_admin`
  # already logged in would let the ambient admin token leak through any `session:` override.
  defp mount_beacon(user, extra_session \\ %{}) do
    token = Accounts.generate_user_session_token(user)

    live_isolated(Phoenix.ConnTest.build_conn(), CinderWeb.ActivityBeaconLive,
      session: Map.put(extra_session, "user_token", token)
    )
  end

  test "counts an in-flight movie as active", %{user: admin} do
    {:ok, _movie} = Catalog.add_movie(%{tmdb_id: 1, title: "Dune"})

    {:ok, _view, html} = mount_beacon(admin)

    assert html =~ "1 active"
  end

  test "hides the pill when nothing is in flight", %{user: admin} do
    {:ok, _view, html} = mount_beacon(admin)

    refute html =~ "active"
    refute html =~ "need attention"
  end

  test "toasts and drops the active count when a movie goes available", %{user: admin} do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 2, title: "Arrival"})

    {:ok, view, _html} = mount_beacon(admin)
    assert render(view) =~ "1 active"

    Catalog.broadcast({:movie_updated, %{movie | status: :available}})

    html = render(view)
    assert html =~ "is now available"
    refute html =~ "1 active"
  end

  test "toasts and counts attention when a movie parks", %{user: admin} do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 3, title: "Solaris"})

    {:ok, view, _html} = mount_beacon(admin)

    Catalog.broadcast({:movie_updated, %{movie | status: :no_match}})

    html = render(view)
    assert html =~ "needs attention"
    assert html =~ "1 need attention"
  end

  test "does not re-toast on a repeat broadcast of the same status", %{user: admin} do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 4, title: "Contact"})
    {:ok, view, _html} = mount_beacon(admin)

    available = %{movie | status: :available}
    Catalog.broadcast({:movie_updated, available})
    assert render(view) =~ "is now available"

    # A metadata re-broadcast on an already-available movie must not spawn a second toast.
    Catalog.broadcast({:movie_updated, available})
    html = render(view)
    assert length(String.split(html, "is now available")) == 2
  end

  test "FR session: the available toast uses the localized title", %{user: admin} do
    {:ok, movie} =
      Catalog.add_movie(%{
        tmdb_id: 5,
        title: "Arrival",
        localizations: %{"fr" => %{"title" => "Premier Contact"}}
      })

    {:ok, view, _html} = mount_beacon(admin, %{"locale" => "fr"})

    Catalog.broadcast({:movie_updated, %{movie | status: :available}})

    html = render(view)
    assert html =~ "Premier Contact"
    refute html =~ "Arrival"
  end

  test "an unauthenticated session cannot mount the beacon" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live_isolated(Phoenix.ConnTest.build_conn(), CinderWeb.ActivityBeaconLive,
               session: %{}
             )
  end

  test "a non-admin session cannot mount the beacon" do
    member = Cinder.AccountsFixtures.user_fixture()
    token = Accounts.generate_user_session_token(member)

    assert {:error, {:redirect, %{to: "/"}}} =
             live_isolated(Phoenix.ConnTest.build_conn(), CinderWeb.ActivityBeaconLive,
               session: %{"user_token" => token}
             )
  end

  test "replaying a beacon token after the admin session is revoked cannot mount", %{
    user: admin
  } do
    token = Accounts.generate_user_session_token(admin)
    Accounts.delete_user_session_token(token)

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live_isolated(Phoenix.ConnTest.build_conn(), CinderWeb.ActivityBeaconLive,
               session: %{"user_token" => token}
             )
  end

  test "replaying a beacon token after the admin is demoted cannot mount", %{user: admin} do
    token = Accounts.generate_user_session_token(admin)

    # Simulate a still-valid session token surviving a role change (defense in depth for the
    # on_mount :require_admin re-check, independent of update_user_role/3's own token wipe).
    admin |> Ecto.Changeset.change(role: :user) |> Cinder.Repo.update!()

    assert {:error, {:redirect, %{to: "/"}}} =
             live_isolated(Phoenix.ConnTest.build_conn(), CinderWeb.ActivityBeaconLive,
               session: %{"user_token" => token}
             )
  end
end
