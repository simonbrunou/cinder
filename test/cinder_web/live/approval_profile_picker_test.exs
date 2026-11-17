defmodule CinderWeb.ApprovalProfilePickerTest do
  # #811: the confirmed-profile picker on `/requests` and the dashboard approval queue offers each
  # pending row exactly its target's profile kind, now read from `Cinder.Requests.profile_kind/1`:
  # the movie profiles for a movie, the TV ones for a season, and the book kind's own for a book.
  use CinderWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures

  alias Cinder.Catalog
  alias Cinder.Repo
  alias Cinder.Requests.Request

  setup :register_and_log_in_admin
  setup :set_mox_global

  setup do
    # The dashboard runs Health.check_all/0 in a start_async task, so every probe needs a stub.
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
    stub(Cinder.Books.PrimaryMetadataMock, :provider, fn -> :openlibrary end)
    stub(Cinder.Books.SecondaryMetadataMock, :provider, fn -> :hardcover end)
    stub(Cinder.Books.PrimaryMetadataMock, :health, fn -> :ok end)
    stub(Cinder.Books.SecondaryMetadataMock, :health, fn -> :ok end)
    stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
    stub(Cinder.Library.AudiobookServerMock, :health, fn -> :ok end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn _, _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
    stub(Cinder.Accounts.PlexAuthMock, :account, fn _token, _opts -> {:ok, %{id: 1}} end)
    stub(Cinder.Accounts.PlexAuthMock, :server_machine_id, fn _opts -> {:ok, "machine-1"} end)

    stub(Cinder.Accounts.PlexAuthMock, :server_share_ids, fn _token, _id, _opts -> {:ok, []} end)

    for {name, kind} <- [
          {"Ebooks A", :ebook},
          {"Ebooks B", :ebook},
          {"Audiobooks", :audiobook}
        ] do
      {:ok, _profile} = Catalog.create_profile(%{name: name, kind: kind, handling: :standard})
    end

    user = user_fixture()

    rows =
      for {kind, attrs} <- [
            movies: %{target_type: "movie", title: "Heat"},
            tv: %{target_type: "season", season_number: 2, title: "Dark"},
            ebook: %{target_type: "book", media_kind: :ebook, title: "Dune"},
            audiobook: %{target_type: "book", media_kind: :audiobook, title: "Emma"}
          ] do
        request =
          Repo.insert!(
            struct(
              %Request{
                user_id: user.id,
                target_id: System.unique_integer([:positive]),
                status: :pending
              },
              attrs
            )
          )

        {kind, request}
      end

    %{rows: rows}
  end

  for {path, prefix} <- [
        {"/requests", "approval-profile"},
        {"/dashboard", "dashboard-approval-profile"}
      ] do
    test "#{path} offers each pending row its own kind's profiles", %{conn: conn, rows: rows} do
      {:ok, lv, _html} = live(conn, unquote(path))
      render_async(lv)

      for {kind, request} <- rows do
        expected = kind |> Catalog.list_profiles() |> Enum.map(&to_string(&1.id)) |> Enum.sort()
        assert expected != [], "no #{kind} profile to offer"

        assert option_values(lv, "##{unquote(prefix)}-#{request.id}") == expected,
               "#{request.target_type} #{kind}"
      end
    end
  end

  defp option_values(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option")
    |> LazyHTML.attribute("value")
    |> Enum.sort()
  end
end
