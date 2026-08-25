defmodule CinderWeb.BookDiscoveryLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Books.{PrimaryMetadataMock, SecondaryMetadataMock}
  alias Cinder.Catalog
  alias Cinder.Repo
  alias Cinder.Requests

  setup :set_mox_global

  setup do
    stub(PrimaryMetadataMock, :provider, fn -> :openlibrary end)
    stub(SecondaryMetadataMock, :provider, fn -> :hardcover end)
    stub(PrimaryMetadataMock, :get_work, fn "OL50548W" -> {:ok, work()} end)

    {:ok, ebook} =
      Catalog.create_profile(%{name: "Ebooks", kind: :ebook, handling: :standard})

    {:ok, audiobook} =
      Catalog.create_profile(%{name: "Audiobooks", kind: :audiobook, handling: :standard})

    %{ebook_profile: ebook, audiobook_profile: audiobook}
  end

  describe "resolution" do
    setup :register_and_log_in_user

    test "an unknown provider returns 404", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, "/book/unknown/id") end
    end

    # Plug percent-decodes the segment before it reaches us, and `Hardcover.get_work/1`
    # interpolates it straight into "/work/\#{foreign_id}" — a decoded "/" would climb out of
    # that path and carry the configured bearer key with it.
    test "a foreign id that is not opaque returns 404", %{conn: conn} do
      for path <- ["/book/openlibrary/..%2F..%2Fadmin%2Fkeys", "/book/openlibrary/a%5Cb"] do
        assert_error_sent 404, fn -> get(conn, path) end
      end
    end

    # The 404 above is a dead mount, which never reaches `start_async` — so it would hold even
    # with the guard removed. This is the half that actually pins it: a live mount resolves a
    # good id and must not resolve a traversing one.
    test "a live mount resolves an opaque id and refuses a traversing one", %{conn: conn} do
      expect(PrimaryMetadataMock, :get_work, 1, fn "OL50548W" -> {:ok, work()} end)

      {:ok, lv, _html} = live(conn, ~p"/book/openlibrary/OL50548W")
      render_async(lv)
      assert has_element?(lv, "#book-work")

      assert_raise Ecto.NoResultsError, fn -> live(conn, "/book/openlibrary/..%2F..%2Fadmin") end
    end

    test "a provider failure renders an honest inline retry state", %{conn: conn} do
      stub(PrimaryMetadataMock, :get_work, fn "OL50548W" -> {:error, :timeout} end)

      {:ok, lv, _html} = live(conn, ~p"/book/openlibrary/OL50548W")
      html = render_async(lv)

      assert has_element?(lv, "#book-resolution-error")
      assert has_element?(lv, "#retry-book-resolution", "Try again")
      assert html =~ "couldn’t load"
      refute html =~ "does not exist"
      refute html =~ "not found"
    end

    test "renders the work metadata and digital-edition summary", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/book/openlibrary/OL50548W")
      html = render_async(lv)

      assert html =~ "Beloved"
      assert html =~ "Toni Morrison"
      assert html =~ "author"
      assert html =~ "Ken Liu"
      assert html =~ "translator"
      assert html =~ "1987"
      assert html =~ "A ghost story."
      assert html =~ "Beloved Trilogy"
      assert html =~ "1 eBook edition"
      assert html =~ "1 audiobook edition"
      assert html =~ "eng"
      assert html =~ "fra"
    end
  end

  describe "requesting as a household member" do
    setup :register_and_log_in_user

    test "creates one pending request and no book target", %{conn: conn, user: user} do
      {:ok, lv, _html} = open_book(conn)

      lv |> element("#request-ebook") |> render_click()
      render_async(lv)

      assert [%{target_type: "book", media_kind: :ebook, status: :pending}] =
               Requests.list_for_user(user)

      assert Repo.aggregate(BookTarget, :count) == 0
    end

    test "the two media kinds are independently requestable", %{conn: conn, user: user} do
      {:ok, lv, _html} = open_book(conn)

      lv |> element("#request-ebook") |> render_click()
      render_async(lv)

      assert has_element?(lv, "#request-audiobook")

      lv |> element("#request-audiobook") |> render_click()
      render_async(lv)

      assert Requests.list_for_user(user)
             |> Enum.map(&{&1.media_kind, &1.status})
             |> Enum.sort() == [{:audiobook, :pending}, {:ebook, :pending}]
    end

    test "a second press on a pending kind reports the duplicate and inserts nothing", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = open_book(conn)

      lv |> element("#request-ebook") |> render_click()
      render_async(lv)

      render_hook(lv, "request", %{"kind" => "ebook"})
      html = render_async(lv)

      assert html =~ "already requested"
      assert length(Requests.list_for_user(user)) == 1
    end

    test "without a profile the request is unavailable without an admin link", %{
      conn: conn,
      ebook_profile: profile
    } do
      assert {:ok, _} = Catalog.delete_profile(profile)

      {:ok, lv, _html} = open_book(conn)

      refute has_element?(lv, "#request-ebook")
      assert has_element?(lv, "#ebook-unavailable")
      refute has_element?(lv, ~s(a[href="/settings/profiles"]))
    end
  end

  describe "requesting as an admin" do
    setup :register_and_log_in_admin

    test "auto-approves into one monitored target with the default profile", %{
      conn: conn,
      user: admin,
      ebook_profile: profile
    } do
      {:ok, lv, _html} = open_book(conn)

      lv |> element("#request-ebook") |> render_click()
      render_async(lv)

      assert [%{status: :approved, media_kind: :ebook, target_id: work_id}] =
               Requests.list_for_user(admin)

      assert [%BookTarget{status: :monitored, profile_id: profile_id}] =
               work_id |> Books.get_work() |> Books.list_targets()

      assert profile_id == profile.id
    end

    test "without a profile the request button is replaced by the profile-settings link", %{
      conn: conn,
      ebook_profile: profile
    } do
      assert {:ok, _} = Catalog.delete_profile(profile)

      {:ok, lv, _html} = open_book(conn)

      refute has_element?(lv, "#request-ebook")
      assert has_element?(lv, ~s(a[href="/settings/profiles"]), "Configure")
    end

    test "a target approval updates the per-kind badge without a reload", %{
      conn: conn,
      ebook_profile: profile
    } do
      assert {:ok, work} = Books.import_resolution(resolution())
      {:ok, lv, _html} = open_book(conn)
      refute has_element?(lv, "#book-state-ebook", "Approved")

      assert {:ok, _target} = Books.monitor_target(work, :ebook, profile)

      assert has_element?(lv, "#book-state-ebook", "Approved")
    end
  end

  defp open_book(conn) do
    {:ok, lv, _html} = live(conn, ~p"/book/openlibrary/OL50548W")
    render_async(lv)
    {:ok, lv, render(lv)}
  end

  defp resolution, do: %{provider: :openlibrary, work: work()}

  defp work do
    %{
      provider: :openlibrary,
      foreign_id: "OL50548W",
      title: "Beloved",
      first_published_on: ~D[1987-09-16],
      overview: "A ghost story.",
      contributors: [
        %{foreign_id: "OL30084A", name: "Toni Morrison", role: "author"},
        %{foreign_id: "OL1A", name: "Ken Liu", role: "translator"}
      ],
      contributors_incomplete: false,
      editions: [
        edition("OL2M", :ebook, "eng"),
        edition("OL3M", :audiobook, "fra")
      ],
      series: [%{name: "Beloved Trilogy", position: "1"}]
    }
  end

  defp edition(id, kind, language) do
    %{
      foreign_id: id,
      media_kind: kind,
      title: "Beloved",
      language: language,
      format: nil,
      publisher: nil,
      release_date: nil,
      abridged: nil,
      isbn13: nil,
      asin: nil
    }
  end
end
