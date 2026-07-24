defmodule CinderWeb.Plugs.RemoteIp do
  @moduledoc """
  Resolves the real client IP from Cloudflare's `cf-connecting-ip` header and rewrites
  `conn.remote_ip` to it, BEFORE the router/controllers ever read it. Behind cloudflared,
  every visitor's raw TCP peer is the tunnel's own hop — without this, IP-keyed logic
  (`Cinder.Accounts.LoginRateLimiter`, `Cinder.Accounts.IpRateLimiter`) collapses to a single
  shared key for the whole internet.

  ## Trust model

  The header is honored ONLY when the DIRECT peer (`conn.remote_ip` as delivered by the
  transport, i.e. before this plug touches it) is private/loopback/link-local — that's
  cloudflared talking to us on our own network (loopback if host-networked, an RFC1918
  Docker-network address if containerized). A PUBLIC direct peer's header is ignored
  outright, so an ordinary internet client can never spoof its own `cf-connecting-ip` and
  impersonate someone else.

  This is safe only because nothing but cloudflared can reach the origin port at all (see
  the pre-exposure security audit's "critical deployment dependency": the compose binding
  stays loopback-only, and cloudflared/Cinder share an internal Docker network when
  containerized). That network isolation — not the peer being loopback specifically — is
  what makes the header trustworthy; the private-peer check below just recognizes
  cloudflared's own address shape.

  `CF-Connecting-IP` carries exactly one client IP (never a comma-separated chain like
  `X-Forwarded-For`), so there is no "which hop do I trust" ambiguity: parse it as a single
  address, or don't trust it.
  """
  @behaviour Plug

  import Plug.Conn

  @header "cf-connecting-ip"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with true <- private_peer?(conn.remote_ip),
         [value] <- get_req_header(conn, @header),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(value)) do
      %{conn | remote_ip: ip}
    else
      _ -> conn
    end
  end

  # Loopback, RFC1918 private, and link-local — the shapes a host-networked or
  # Docker-networked cloudflared peer can take. Deliberately narrower than
  # `Cinder.HTTPPolicy`'s SSRF forbidden-address list: this only needs to recognize "this is
  # our own reverse proxy," not defend against every special-use range.
  defp private_peer?({127, _, _, _}), do: true
  defp private_peer?({10, _, _, _}), do: true
  defp private_peer?({172, b, _, _}) when b in 16..31, do: true
  defp private_peer?({192, 168, _, _}), do: true
  defp private_peer?({169, 254, _, _}), do: true
  defp private_peer?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_peer?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: private_peer?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})

  defp private_peer?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  defp private_peer?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: true
  defp private_peer?(_address), do: false
end
