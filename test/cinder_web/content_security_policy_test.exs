defmodule CinderWeb.ContentSecurityPolicyTest do
  use CinderWeb.ConnCase, async: true

  alias CinderWeb.ContentSecurityPolicy

  describe "plug" do
    test "sets a content-security-policy header with a per-request nonce" do
      conn = build_conn() |> ContentSecurityPolicy.call([])

      nonce = conn.assigns.csp_nonce
      assert is_binary(nonce) and nonce != ""

      assert [csp] = get_resp_header(conn, "content-security-policy")

      assert csp ==
               "default-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'; " <>
                 "script-src 'self' 'nonce-#{nonce}'; style-src 'self' 'unsafe-inline'; " <>
                 "img-src 'self' https://image.tmdb.org data:; connect-src 'self' ws: wss:"
    end

    test "generates a different nonce on every call" do
      nonce1 = (build_conn() |> ContentSecurityPolicy.call([])).assigns.csp_nonce
      nonce2 = (build_conn() |> ContentSecurityPolicy.call([])).assigns.csp_nonce

      refute nonce1 == nonce2
    end
  end

  describe "integration via the :browser pipeline" do
    test "a real response carries the CSP header and the layout's inline script carries the matching nonce",
         %{conn: conn} do
      conn = get(conn, ~p"/users/log-in")

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "script-src 'self' 'nonce-"

      assert [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, csp)
      assert conn.resp_body =~ ~s(<script nonce="#{nonce}">)
    end
  end
end
