defmodule CinderWeb.EntityDiscoveryLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie
  alias Cinder.Requests

  # The LiveView runs in its own process, so the mock must be global (async: false).
  setup :set_mox_global

  setup do
    # A successful "add" enriches the movie via get_movie (imdb_id, alt titles) before insert.
    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         imdb_id: nil,
         title: "Inception",
         year: 2010,
         poster_path: "/p.jpg",
         original_language: "en"
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn _ -> {:ok, []} end)

    :ok
  end

  @movie_credit %{
    tmdb_id: 27_205,
    title: "Inception",
    year: 2010,
    poster_path: "/p.jpg",
    original_language: "en",
    type: :movie
  }
  @tv_credit %{
    tmdb_id: 1399,
    title: "Game of Thrones",
    year: 2011,
    poster_path: "/got.jpg",
    original_language: "en",
    type: :tv
  }

  defp stub_person(overrides) do
    person =
      Map.merge(
        %{
          tmdb_id: 500,
          name: "Christopher Nolan",
          profile_path: "/cn.jpg",
          department: "Directing",
          credits: [@movie_credit, @tv_credit],
          total_credits: 2
        },
        overrides
      )

    stub(Cinder.Catalog.TMDBMock, :get_person, fn 500, _locale -> {:ok, person} end)
  end

  defp stub_collection(overrides) do
    collection =
      Map.merge(
        %{
          tmdb_id: 10,
          title: "Inception Collection",
          poster_path: "/ic.jpg",
          parts: [@movie_credit]
        },
        overrides
      )

    stub(Cinder.Catalog.TMDBMock, :get_collection, fn 10, _locale -> {:ok, collection} end)
  end

  describe "person page" do
    test "renders the header (name + department) and the credits grid", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
      stub_person(%{})

      {:ok, _lv, html} = live(conn, ~p"/person/tmdb/500")

      assert html =~ "Christopher Nolan"
      assert html =~ "Director"
      assert html =~ "Inception"
      assert html =~ "Game of Thrones"
    end

    test "a movie credit can be added straight from the page", %{conn: conn} do
      user = Cinder.AccountsFixtures.user_fixture()
      conn = log_in_user(conn, user)
      stub_person(%{})

      {:ok, lv, _html} = live(conn, ~p"/person/tmdb/500")
      lv |> form("#add-form-27205") |> render_submit()
      render_async(lv)

      assert [%{target_type: "movie", target_id: 27_205, status: :pending}] =
               Requests.list_for_user(user)
    end

    test "an admin add creates a :requested movie and flips the card off Add", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.admin_fixture())
      stub_person(%{})

      {:ok, lv, _html} = live(conn, ~p"/person/tmdb/500")
      lv |> form("#add-form-27205") |> render_submit()
      render_async(lv)

      assert [%Movie{tmdb_id: 27_205, status: :requested}] = Catalog.list_movies()
      refute has_element?(lv, "#add-form-27205")
    end

    test "a TV credit links to the season picker instead of an Add form", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
      stub_person(%{})

      {:ok, lv, _html} = live(conn, ~p"/person/tmdb/500")

      assert has_element?(lv, ~s(#credits a[href="/series/tmdb/1399"]))
    end

    test "an existing pending request shows a Pending badge instead of Add", %{conn: conn} do
      user = Cinder.AccountsFixtures.user_fixture()

      {:ok, _} =
        Requests.create_request(user, %{
          target_type: "movie",
          target_id: 27_205,
          title: "Inception",
          year: 2010,
          poster_path: "/p.jpg"
        })

      conn = log_in_user(conn, user)
      stub_person(%{})

      {:ok, lv, _html} = live(conn, ~p"/person/tmdb/500")

      assert has_element?(lv, "#credits", "Pending")
      refute has_element?(lv, "#add-form-27205")
    end

    test "shows a truncation caption when total_credits exceeds the 60 cap", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
      stub_person(%{total_credits: 87})

      {:ok, _lv, html} = live(conn, ~p"/person/tmdb/500")

      assert html =~ "Showing top 60 of 87"
    end

    test "no caption is shown when every credit fits under the cap", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
      stub_person(%{})

      {:ok, _lv, html} = live(conn, ~p"/person/tmdb/500")

      refute html =~ "Showing top"
    end

    test "no credits renders the empty state", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
      stub_person(%{credits: [], total_credits: 0})

      {:ok, _lv, html} = live(conn, ~p"/person/tmdb/500")

      assert html =~ "No credits found"
    end

    test "a non-integer tmdb_id redirects to Discover instead of crashing", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
      assert {:error, {kind, %{to: "/"}}} = live(conn, ~p"/person/tmdb/not-a-number")
      assert kind in [:redirect, :live_redirect]
    end

    test "a 404 from TMDB redirects with a not-found flash", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())

      stub(Cinder.Catalog.TMDBMock, :get_person, fn 500, _locale ->
        {:error, {:tmdb_status, 404}}
      end)

      assert {:error, {kind, %{to: "/", flash: flash}}} = live(conn, ~p"/person/tmdb/500")
      assert kind in [:redirect, :live_redirect]
      assert flash["error"] =~ "not found"
    end

    test "a non-404 TMDB failure redirects with an outage flash, not a not-found one", %{
      conn: conn
    } do
      conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
      stub(Cinder.Catalog.TMDBMock, :get_person, fn 500, _locale -> {:error, :timeout} end)

      assert {:error, {kind, %{to: "/", flash: flash}}} = live(conn, ~p"/person/tmdb/500")
      assert kind in [:redirect, :live_redirect]
      assert flash["error"] =~ "Couldn't reach TMDB"
    end
  end

  describe "collection page" do
    test "renders the header and the movie-only parts grid", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
      stub_collection(%{})

      {:ok, _lv, html} = live(conn, ~p"/collection/tmdb/10")

      assert html =~ "Inception Collection"
      assert html =~ "Inception"
    end

    test "a part can be added straight from the page", %{conn: conn} do
      user = Cinder.AccountsFixtures.user_fixture()
      conn = log_in_user(conn, user)
      stub_collection(%{})

      {:ok, lv, _html} = live(conn, ~p"/collection/tmdb/10")
      lv |> form("#add-form-27205") |> render_submit()
      render_async(lv)

      assert [%{target_type: "movie", target_id: 27_205}] = Requests.list_for_user(user)
    end

    test "no parts renders the empty state", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
      stub_collection(%{parts: []})

      {:ok, _lv, html} = live(conn, ~p"/collection/tmdb/10")

      assert html =~ "No movies found"
    end

    test "a non-integer tmdb_id redirects to Discover instead of crashing", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
      assert {:error, {kind, %{to: "/"}}} = live(conn, ~p"/collection/tmdb/not-a-number")
      assert kind in [:redirect, :live_redirect]
    end

    test "a 404 from TMDB redirects with a not-found flash", %{conn: conn} do
      conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())

      stub(Cinder.Catalog.TMDBMock, :get_collection, fn 10, _locale ->
        {:error, {:tmdb_status, 404}}
      end)

      assert {:error, {kind, %{to: "/", flash: flash}}} = live(conn, ~p"/collection/tmdb/10")
      assert kind in [:redirect, :live_redirect]
      assert flash["error"] =~ "not found"
    end
  end

  test "a malformed add payload is ignored, not a crash", %{conn: conn} do
    conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
    stub_person(%{})
    {:ok, lv, _html} = live(conn, ~p"/person/tmdb/500")

    assert render_hook(lv, "add", %{"tmdb_id" => ["x"]}) =~ "Christopher Nolan"
    assert Catalog.list_movies() == []
  end
end
