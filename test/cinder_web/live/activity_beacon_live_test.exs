defmodule CinderWeb.ActivityBeaconLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.CatalogFixtures

  alias Cinder.Accounts
  alias Cinder.Catalog
  alias Cinder.Catalog.{Grab, GrabFile}
  alias Cinder.Repo

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

  # The nav badge and the pill each carry "N need attention" as their accessible name; with
  # nothing to attend to, neither renders one.
  defp assert_attention(conn, admin, n) do
    {:ok, nav, _html} = live(conn, ~p"/calendar")
    {:ok, pill, _html} = mount_beacon(admin)

    if n == 0 do
      refute has_element?(nav, ~s(a[href="/activity"] .badge))
      refute has_element?(pill, ~s(a[aria-label*="need attention"]))
    else
      assert has_element?(nav, ~s(a[href="/activity"] .badge[aria-label="#{n} need attention"]))
      assert has_element?(pill, ~s(a[aria-label="Pipeline: #{n} need attention"]))
    end
  end

  defp seed({:parked, status}), do: movie_fixture(status: status)

  defp seed({:verification_hold, origin}) do
    from = if origin == :download, do: :downloaded, else: :upgrading
    movie = movie_fixture(status: from, download_id: "v", release_title: "Rel")

    {:ok, _held} =
      seed_movie_state(movie, %{
        status: :import_failed,
        import_attempts: 1,
        verification_hold_origin: origin
      })
  end

  defp seed({:grab_hold, mapping_status}) do
    Repo.insert!(%Grab{
      download_id: "held",
      download_protocol: :torrent,
      mapping_status: mapping_status
    })
  end

  # Unreachable in production (grab_files are inventoried only after `content_path` is set), but
  # /activity still offers the residual-file actions for it.
  defp seed(:residual_grab_without_content) do
    grab = Repo.insert!(%Grab{download_id: "res", download_protocol: :usenet})

    Repo.insert!(%GrabFile{
      grab_id: grab.id,
      relative_path: "x.mkv",
      size: 1,
      device: 1,
      inode: 1
    })
  end

  defp seed(:in_flight_movie), do: movie_fixture(status: :downloading, download_id: "d")

  defp seed(:anime_held_movie),
    do: {:ok, _} = Catalog.set_anime_hold(movie_fixture(), "subtitle_language_required")

  defp seed(:anime_held_series),
    do: {:ok, _} = Catalog.set_anime_hold(series_fixture(), "original_language_required")

  # No sweep visits a cancelled series again, so cancelling lifts its hold.
  defp seed(:anime_held_cancelled_series) do
    {:ok, held} = Catalog.set_anime_hold(series_fixture(), "original_language_required")
    {:ok, _} = Catalog.cancel_series(held, Cinder.AccountsFixtures.admin_fixture())
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

  # #772: only the operator clears an anime hold, so it toasts and counts like any other item that
  # needs attention.
  test "toasts and counts attention when a movie enters an anime hold", %{user: admin} do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 6, title: "Akira"})
    {:ok, view, _html} = mount_beacon(admin)

    {:ok, _held} = Catalog.set_anime_hold(movie, "subtitle_language_required")

    assert has_element?(view, "#activity-beacon-toasts .alert", "“Akira” needs attention.")
    assert has_element?(view, ~s(a[aria-label="Pipeline: 1 need attention"]))
  end

  test "toasts once and counts attention when a series enters an anime hold", %{user: admin} do
    series = series_fixture(%{title: "Re:Zero"})
    {:ok, view, _html} = mount_beacon(admin)

    {:ok, held} = Catalog.set_anime_hold(series, "original_language_required")

    assert has_element?(view, "#activity-beacon-toasts .alert", "“Re:Zero” needs attention.")
    assert has_element?(view, ~s(a[aria-label="Pipeline: 1 need attention"]))

    # A new reason keeps it in attention: no second toast. Lifting the hold drops the count.
    {:ok, held} = Catalog.set_anime_hold(held, "subtitle_language_required")

    assert view
           |> element("#activity-beacon-toasts")
           |> render()
           |> String.split("Re:Zero")
           |> length() == 2

    {:ok, _cleared} = Catalog.set_anime_hold(held, nil)
    refute has_element?(view, ~s(a[aria-label*="need attention"]))
  end

  # #732: the pill and the Activity nav badge read "N need attention" off one rule, the nav's
  # `Catalog.Attention.attention_count/0` (an item counts when /activity offers an action or names
  # a fix for it). Each item is seeded alone, so an over-count on one side can't cancel an
  # under-count on the other.
  describe "the pill agrees with the Activity nav badge" do
    for {item, expected} <- [
          {{:parked, :no_match}, 1},
          {{:parked, :search_failed}, 1},
          {{:parked, :import_failed}, 1},
          {{:verification_hold, :download}, 1},
          {{:verification_hold, :upgrade}, 1},
          {{:grab_hold, :needs_mapping}, 1},
          {{:grab_hold, :verification_blocked}, 1},
          {:residual_grab_without_content, 1},
          {:in_flight_movie, 0},
          {:anime_held_movie, 1},
          {:anime_held_series, 1},
          {:anime_held_cancelled_series, 0}
        ] do
      test "#{inspect(item)} counts #{expected}", %{conn: conn, user: admin} do
        seed(unquote(Macro.escape(item)))

        assert Catalog.Attention.attention_count() == unquote(expected)
        assert_attention(conn, admin, unquote(expected))
      end
    end
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
