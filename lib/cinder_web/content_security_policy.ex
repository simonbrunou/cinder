defmodule CinderWeb.ContentSecurityPolicy do
  @moduledoc """
  Sets a `content-security-policy` response header with a per-request nonce.

  No XSS sink exists today (no `raw/1`, `{:safe}`, `innerHTML`; all external metadata renders
  through auto-escaping HEEx), so this is defense-in-depth — it contains a future `raw()` call
  or dependency bug rather than closing an active hole. See finding 5,
  `docs/audits/2026-07-24-pre-public-exposure-security-audit.md`.

  Runs in the `:browser` pipeline *after* `:put_secure_browser_headers` (whose default CSP is
  just `base-uri 'self'; frame-ancestors 'self'`) and replaces it outright with the full policy
  below. The nonce is assigned on the conn as `:csp_nonce` so the root layout can apply it to
  the inline theme-toggle `<script>` — under `script-src` with a nonce present, an inline
  script without a matching nonce is blocked.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.url_encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp policy(nonce) do
    "default-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'; " <>
      "script-src 'self' 'nonce-#{nonce}'; style-src 'self' 'unsafe-inline'; " <>
      "img-src 'self' https://image.tmdb.org data:; connect-src 'self' ws: wss:"
  end
end
