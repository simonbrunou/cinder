defmodule CinderWeb.DataExportControllerTest do
  use CinderWeb.ConnCase

  import Cinder.AccountsFixtures
  alias Cinder.Repo
  alias Cinder.Requests.Request

  describe "GET /users/export" do
    test "downloads the current user's data as a JSON attachment without secrets", %{conn: conn} do
      user = user_fixture() |> set_password()

      Repo.insert!(%Request{
        user_id: user.id,
        target_type: "movie",
        target_id: 603,
        title: "The Matrix",
        year: 1999,
        status: :approved
      })

      conn = conn |> log_in_user(user) |> get(~p"/users/export")

      assert response_content_type(conn, :json)
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "cinder-account-export.json"

      body = conn.resp_body
      # Secrets must never appear in the export.
      refute body =~ "hashed_password"
      refute body =~ user.hashed_password
      refute body =~ "user_token"

      decoded = Jason.decode!(body)
      assert decoded["account"]["email"] == user.email
      assert decoded["account"]["role"] == "user"
      refute Map.has_key?(decoded["account"], "hashed_password")

      assert [req] = decoded["requests"]
      assert req["target_id"] == 603
      assert req["title"] == "The Matrix"
      assert req["status"] == "approved"
    end

    test "scopes strictly to the session user — another user's requests never appear", %{
      conn: conn
    } do
      user = user_fixture()
      other = user_fixture()

      Repo.insert!(%Request{
        user_id: user.id,
        target_type: "movie",
        target_id: 111,
        title: "Mine",
        status: :pending
      })

      Repo.insert!(%Request{
        user_id: other.id,
        target_type: "movie",
        target_id: 222,
        title: "Theirs",
        status: :pending
      })

      conn = conn |> log_in_user(user) |> get(~p"/users/export")
      decoded = Jason.decode!(conn.resp_body)

      assert Enum.map(decoded["requests"], & &1["title"]) == ["Mine"]
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, ~p"/users/export")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
