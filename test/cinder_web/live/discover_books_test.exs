defmodule CinderWeb.DiscoverBooksTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Books
  alias Cinder.Books.{PrimaryMetadataMock, SecondaryMetadataMock}
  alias Cinder.Catalog
  alias Cinder.Requests
  alias CinderWeb.DiscoverLive

  setup :register_and_log_in_user
  setup :set_mox_global

  setup do
    stub(Cinder.Catalog.TMDBMock, :search, fn _, _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _, _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :search_person, fn _, _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :search_collection, fn _, _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :trending, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :popular_movies, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :top_rated_movies, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :now_playing_movies, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :popular_tv, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :top_rated_tv, fn _ -> {:ok, []} end)
    stub(PrimaryMetadataMock, :provider, fn -> :openlibrary end)
    stub(SecondaryMetadataMock, :provider, fn -> :hardcover end)
    :ok
  end

  test "book results render accessible cards and the Books filter chip", %{
    conn: conn,
    user: user
  } do
    candidate = candidate(:openlibrary, "OL50548W", "Beloved")
    expect(PrimaryMetadataMock, :search, fn "beloved" -> {:ok, [candidate]} end)

    {:ok, work} =
      Books.upsert_work(%{
        title: "Beloved",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: "OL50548W"}
      })

    assert {:ok, _} =
             Requests.create_request(user, %{
               target_type: "book",
               target_id: work.id,
               media_kind: :ebook
             })

    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> form("#search-form", %{"query" => "beloved"}) |> render_change()
    render_async(lv)

    assert has_element?(lv, "#book-results", "Beloved")
    assert has_element?(lv, ~s(button[phx-value-type="book"]), "Books")

    assert has_element?(
             lv,
             ~s(a[href="/book/openlibrary/OL50548W"][aria-label*="Beloved"])
           )

    assert has_element?(lv, "#book-results", "eBook")
    assert has_element?(lv, "#book-results", "Pending")
  end

  test "a book target approval updates the card badge without a reload", %{
    conn: conn,
    user: user
  } do
    candidate = candidate(:openlibrary, "OL50548W", "Beloved")
    expect(PrimaryMetadataMock, :search, fn "beloved" -> {:ok, [candidate]} end)

    {:ok, work} =
      Books.upsert_work(%{
        title: "Beloved",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: "OL50548W"}
      })

    assert {:ok, _} =
             Requests.create_request(user, %{
               target_type: "book",
               target_id: work.id,
               media_kind: :ebook
             })

    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> form("#search-form", %{"query" => "beloved"}) |> render_change()
    render_async(lv)
    assert has_element?(lv, "#book-results", "Pending")

    # The target moves with no request event behind it — an admin approving from another
    # session, and from B4 an import. Discover must hear it on the targets topic.
    {:ok, profile} = Catalog.create_profile(%{name: "eBooks", kind: :ebook, handling: :standard})
    assert {:ok, _target} = Books.monitor_target(work, :ebook, profile)

    assert render(lv) =~ "Approved"
    refute has_element?(lv, "#book-results", "Pending")
  end

  test "book and video filters isolate their own result sections", %{conn: conn} do
    candidate = candidate(:openlibrary, "OL50548W", "Beloved")
    expect(PrimaryMetadataMock, :search, fn "beloved" -> {:ok, [candidate]} end)

    stub(Cinder.Catalog.TMDBMock, :search, fn _, _ ->
      {:ok,
       [
         %{
           tmdb_id: 27_205,
           title: "Inception",
           year: 2010,
           poster_path: "/p.jpg",
           original_language: "en"
         }
       ]}
    end)

    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> form("#search-form", %{"query" => "beloved"}) |> render_change()
    render_async(lv)

    html = lv |> element(~s(button[phx-value-type="book"])) |> render_click()
    assert html =~ "Beloved"
    refute html =~ "Inception"

    html = lv |> element(~s(button[phx-value-type="movie"])) |> render_click()
    assert html =~ "Inception"
    refute html =~ "Beloved"
  end

  test "a books outage leaves movie results intact", %{conn: conn} do
    expect(PrimaryMetadataMock, :search, fn "inception" -> {:error, :timeout} end)
    expect(SecondaryMetadataMock, :search, fn "inception" -> {:error, :not_configured} end)

    stub(Cinder.Catalog.TMDBMock, :search, fn _, _ ->
      {:ok,
       [
         %{
           tmdb_id: 27_205,
           title: "Inception",
           year: 2010,
           poster_path: "/p.jpg",
           original_language: "en"
         }
       ]}
    end)

    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    render_async(lv)

    assert has_element?(lv, "#results", "Inception")
    assert has_element?(lv, "#books-search-error")
  end

  test "a stale books result is discarded" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{query: "new query", book_results: [candidate(:openlibrary, "new", "New")]}
    }

    assert {:noreply, ^socket} =
             DiscoverLive.handle_async(
               :books,
               {:ok, {"old query", {:ok, [candidate(:openlibrary, "old", "Old")]}}},
               socket
             )
  end

  # `cancel_async/3` neither demonitors nor drops the private entry, so a superseded task's DOWN
  # still arrives. The branch that only cancels — the query fell back under the floor — has no
  # follow-on `start_async` to prune it by ref, so without the dedicated reason this reports an
  # outage the user never had.
  test "a superseded search is swallowed, but a real crash still reports the outage" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        query: "ha",
        book_results: [],
        book_states: %{},
        books_state: :idle
      }
    }

    assert {:noreply, ^socket} =
             DiscoverLive.handle_async(:books, {:exit, {:shutdown, :superseded}}, socket)

    assert {:noreply, crashed} =
             DiscoverLive.handle_async(:books, {:exit, {:shutdown, :boom}}, socket)

    assert crashed.assigns.books_state == :error
  end

  test "a two-character query does not search books", %{conn: conn} do
    parent = self()

    stub(PrimaryMetadataMock, :search, fn query ->
      send(parent, {:books_search, query})
      {:ok, []}
    end)

    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> form("#search-form", %{"query" => "it"}) |> render_change()

    refute_receive {:books_search, _query}, 100
  end

  defp candidate(provider, foreign_id, title) do
    %{
      provider: provider,
      foreign_id: foreign_id,
      title: title,
      contributors: [%{foreign_id: "author-1", name: "Toni Morrison", role: "author"}],
      contributors_incomplete: false,
      first_published_year: 1987,
      edition_count: 12
    }
  end
end
