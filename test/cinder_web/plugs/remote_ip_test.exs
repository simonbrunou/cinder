defmodule CinderWeb.Plugs.RemoteIpTest do
  # Pure plug unit test — no DB, no shared global state.
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias CinderWeb.Plugs.RemoteIp

  defp call(peer, headers) do
    conn = %{conn(:get, "/") | remote_ip: peer}

    conn =
      Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

    RemoteIp.call(conn, RemoteIp.init([]))
  end

  test "rewrites remote_ip from cf-connecting-ip when the direct peer is loopback" do
    conn = call({127, 0, 0, 1}, [{"cf-connecting-ip", "203.0.113.7"}])
    assert conn.remote_ip == {203, 0, 113, 7}
  end

  test "trusts the header from an RFC1918 (containerized cloudflared) peer" do
    conn = call({172, 20, 0, 3}, [{"cf-connecting-ip", "198.51.100.42"}])
    assert conn.remote_ip == {198, 51, 100, 42}
  end

  test "parses an IPv6 client address" do
    conn = call({127, 0, 0, 1}, [{"cf-connecting-ip", "2001:db8::1"}])
    assert conn.remote_ip == {8193, 3512, 0, 0, 0, 0, 0, 1}
  end

  test "IGNORES the header from a public direct peer (no spoofing)" do
    conn = call({203, 0, 113, 1}, [{"cf-connecting-ip", "10.0.0.5"}])
    # A direct internet client cannot forge its own client IP.
    assert conn.remote_ip == {203, 0, 113, 1}
  end

  test "leaves remote_ip untouched when the header is absent" do
    conn = call({127, 0, 0, 1}, [])
    assert conn.remote_ip == {127, 0, 0, 1}
  end

  test "leaves remote_ip untouched when the header is malformed" do
    conn = call({127, 0, 0, 1}, [{"cf-connecting-ip", "not-an-ip"}])
    assert conn.remote_ip == {127, 0, 0, 1}
  end
end
