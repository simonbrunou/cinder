defmodule CinderWeb.DataExportController do
  @moduledoc """
  GDPR Art.15/20 data export: streams the authenticated user's OWN account data and requests as a
  downloadable JSON attachment. Strictly scoped to the session user (no id param), and never
  includes secrets (`hashed_password`, tokens).
  """
  use CinderWeb, :controller

  alias Cinder.Accounts
  alias Cinder.Requests

  def export(conn, _params) do
    user = conn.assigns.current_scope.user

    payload = %{
      exported_at: DateTime.to_iso8601(DateTime.utc_now()),
      account: Accounts.export_user_data(user),
      requests: Requests.export_for_user(user)
    }

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="cinder-account-export.json")
    )
    |> send_resp(200, Jason.encode!(payload, pretty: true))
  end
end
