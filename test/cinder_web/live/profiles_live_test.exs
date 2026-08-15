defmodule CinderWeb.ProfilesLiveTest do
  use CinderWeb.ConnCase, async: false

  import Cinder.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Cinder.Catalog

  setup :register_and_log_in_admin

  test "an admin creates, edits, and deletes a named profile with labelled fields", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/profiles")

    assert has_element?(lv, "#profile-form label", "Name")
    assert has_element?(lv, "#profile-form label", "Media kind")
    assert has_element?(lv, "#profile-form label", "Handling")
    assert has_element?(lv, "#profile-form label", "Library path")

    lv
    |> form("#profile-form", %{
      "profile" => %{
        "name" => "Kids",
        "kind" => "movies",
        "handling" => "standard",
        "library_path" => ""
      }
    })
    |> render_submit()

    profile = Enum.find(Catalog.list_profiles(:movies), &(&1.name == "Kids"))
    assert profile
    assert has_element?(lv, "#profile-#{profile.id}", "Kids")

    lv |> element("#profile-#{profile.id} button", "Edit") |> render_click()

    lv
    |> form("#profile-form", %{
      "profile" => %{
        "name" => "Family",
        "kind" => "movies",
        "handling" => "standard",
        "library_path" => ""
      }
    })
    |> render_submit()

    assert Catalog.get_profile(profile.id).name == "Family"

    lv |> element("#profile-#{profile.id} button", "Delete") |> render_click()
    assert has_element?(lv, "#confirm-delete-profile-#{profile.id}")

    lv
    |> element("#confirm-delete-profile-#{profile.id} button", "Delete profile")
    |> render_click()

    refute Catalog.get_profile(profile.id)
  end

  test "validation errors render inline and malformed events do not crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/profiles")

    html =
      lv
      |> form("#profile-form", %{
        "profile" => %{
          "name" => "",
          "kind" => "movies",
          "handling" => "standard",
          "library_path" => ""
        }
      })
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    render_hook(lv, "edit", %{"id" => "not-an-id"})
    render_hook(lv, "unknown", %{})
    assert render(lv) =~ "Media profiles"
  end

  test "a non-admin cannot reach profile administration", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/profiles")
  end
end
