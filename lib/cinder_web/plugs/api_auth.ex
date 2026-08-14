defmodule CinderWeb.Plugs.ApiAuth do
  @moduledoc """
  Gates the household `/api/v1` scope on the admin API key, presented in an `x-api-key`
  request header.

  Every failure — header absent, header wrong, key revoked — is the same bare 401 JSON body, so
  a caller learns only "not authorized" and never whether a key exists or how close it got.
  There is no `WWW-Authenticate` challenge: this is a machine endpoint, and prompting a browser
  for credentials would be noise. Sessions are irrelevant here; the plug reads nothing but the
  header.
  """
  import Plug.Conn

  alias Cinder.ApiKey

  @header "x-api-key"
  @unauthorized ~s({"error":"unauthorized"})

  def init(opts), do: opts

  def call(conn, _opts) do
    # Exactly one header. A duplicated header is a malformed request, not an invitation to
    # try each value in turn.
    case get_req_header(conn, @header) do
      [key] -> if ApiKey.valid?(key), do: conn, else: deny(conn)
      _ -> deny(conn)
    end
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:unauthorized, @unauthorized)
    |> halt()
  end
end
