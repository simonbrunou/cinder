defmodule Cinder.HTTPPolicyTest do
  use ExUnit.Case, async: true

  alias Cinder.HTTPPolicy

  @public_ipv4 {93, 184, 216, 34}
  @public_ipv6 {0x2606, 0x2800, 0x220, 0x1, 0x248, 0x1893, 0x25C8, 0x1946}

  describe "same_origin?/2" do
    test "normalizes scheme and host case and default ports" do
      assert HTTPPolicy.same_origin?("HTTP://Example.COM/path", "http://example.com:80/other")
      assert HTTPPolicy.same_origin?("https://EXAMPLE.com", "HTTPS://example.COM:443/path")
    end

    test "rejects different schemes, hosts, and effective ports" do
      refute HTTPPolicy.same_origin?("http://example.com", "https://example.com")
      refute HTTPPolicy.same_origin?("https://example.com", "https://other.example")
      refute HTTPPolicy.same_origin?("https://example.com", "https://example.com:444")
      refute HTTPPolicy.same_origin?("not a URL", "not a URL")
    end
  end

  describe "validate_untrusted_url/2" do
    test "rejects forbidden literal address ranges and alternate IPv4 forms" do
      forbidden = [
        "http://0.0.0.0",
        "http://10.0.0.1",
        "http://100.64.0.1",
        "http://127.0.0.1",
        "http://127.1",
        "http://169.254.1.1",
        "http://172.16.0.1",
        "http://192.168.1.1",
        "http://192.0.2.1",
        "http://198.18.0.1",
        "http://224.0.0.1",
        "http://240.0.0.1",
        "http://2130706433",
        "http://0x7f000001",
        "http://017700000001",
        "http://[::]",
        "http://[::1]",
        "http://[::ffff:127.0.0.1]",
        "http://[::ffff:7f00:1]",
        "http://[fc00::1]",
        "http://[fe80::1]",
        "http://[ff02::1]",
        "http://[2001:db8::1]",
        "http://[3fff::1]",
        "http://[5f00::1]",
        "http://[100:0:0:1::1]",
        "http://[4000::1]"
      ]

      resolver = fn _host -> flunk("literal addresses must not use DNS") end

      for url <- forbidden do
        assert {:error, :forbidden_address} = HTTPPolicy.validate_untrusted_url(url, resolver),
               url
      end
    end

    test "rejects a DNS answer set if any address is forbidden" do
      resolver = fn "mixed.example" -> {:ok, [@public_ipv4, {10, 0, 0, 1}]} end

      assert {:error, :forbidden_address} =
               HTTPPolicy.validate_untrusted_url("https://mixed.example/file", resolver)
    end

    test "rejects forbidden IPv4-mapped IPv6 DNS answers" do
      mapped_loopback = {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
      resolver = fn "mapped.example" -> {:ok, [@public_ipv4, mapped_loopback]} end

      assert {:error, :forbidden_address} =
               HTTPPolicy.validate_untrusted_url("https://mapped.example", resolver)
    end

    test "accepts public HTTPS destinations and returns the parsed URI" do
      resolver = fn "public.example" -> {:ok, [@public_ipv4, @public_ipv6]} end

      assert {:ok, %URI{scheme: "https", host: "public.example"}} =
               HTTPPolicy.validate_untrusted_url(
                 "https://public.example/releases/file.torrent",
                 resolver
               )
    end

    test "rejects malformed and unsupported URLs before DNS" do
      resolver = fn _host -> flunk("invalid URLs must not use DNS") end

      invalid = [
        {"ftp://public.example/file", :unsupported_scheme},
        {"https:///missing-host", :missing_host},
        {"https://user:secret@public.example/file", :userinfo_not_allowed},
        {"https://public.example/file#fragment", :fragment_not_allowed}
      ]

      for {url, reason} <- invalid do
        assert {:error, ^reason} = HTTPPolicy.validate_untrusted_url(url, resolver)
      end
    end

    test "returns a stable DNS error and rejects empty answer sets" do
      assert {:error, :dns_resolution_failed} =
               HTTPPolicy.validate_untrusted_url("https://missing.example", fn _ ->
                 {:error, :nxdomain}
               end)

      assert {:error, :dns_resolution_failed} =
               HTTPPolicy.validate_untrusted_url("https://empty.example", fn _ -> {:ok, []} end)
    end
  end

  describe "resolve_redirect/3" do
    test "allows relative same-origin redirects for configured origins" do
      assert {:ok, %URI{} = uri} =
               HTTPPolicy.resolve_redirect(
                 "http://192.168.1.10:8080/api/start",
                 "../next?id=1",
                 :same_origin
               )

      assert URI.to_string(uri) == "http://192.168.1.10:8080/next?id=1"
    end

    test "rejects cross-origin configured redirects" do
      assert {:error, :cross_origin_redirect} =
               HTTPPolicy.resolve_redirect(
                 "https://api.example/start",
                 "//other.example/next",
                 :same_origin
               )
    end

    test "rejects HTTPS downgrades and redirect userinfo" do
      resolver = fn _host -> {:ok, [@public_ipv4]} end

      for policy <- [:same_origin, resolver] do
        assert {:error, :https_downgrade} =
                 HTTPPolicy.resolve_redirect(
                   "https://public.example/start",
                   "http://public.example/next",
                   policy
                 )

        assert {:error, :userinfo_not_allowed} =
                 HTTPPolicy.resolve_redirect(
                   "https://public.example/start",
                   "https://user:secret@public.example/next",
                   policy
                 )
      end
    end

    test "revalidates every untrusted redirect destination" do
      parent = self()

      resolver = fn host ->
        send(parent, {:resolved, host})
        {:ok, [@public_ipv4]}
      end

      assert {:ok, %URI{host: "cdn.example"}} =
               HTTPPolicy.resolve_redirect(
                 "https://public.example/start",
                 "https://cdn.example/file",
                 resolver
               )

      assert_receive {:resolved, "cdn.example"}

      assert {:error, :forbidden_address} =
               HTTPPolicy.resolve_redirect(
                 "https://public.example/start",
                 "https://private.example/file",
                 fn "private.example" -> {:ok, [{192, 168, 1, 10}]} end
               )
    end

    test "supports the default untrusted policy for production callers" do
      assert {:ok, %URI{host: "93.184.216.34"}} =
               HTTPPolicy.resolve_redirect(
                 "https://93.184.216.34/start",
                 "/file",
                 :untrusted
               )
    end
  end

  describe "bounded_request/2" do
    test "collects a response within the byte limit without decoding it" do
      Req.Test.stub(Cinder.HTTPPolicyStub, fn conn -> Req.Test.json(conn, %{ok: true}) end)

      assert {:ok, %{status: 200, body: body}} =
               HTTPPolicy.bounded_request(
                 [
                   url: "https://public.example/data",
                   plug: {Req.Test, Cinder.HTTPPolicyStub}
                 ],
                 64
               )

      assert body == ~s({"ok":true})
    end

    test "halts oversized bodies with a stable error" do
      Req.Test.stub(Cinder.HTTPPolicyLargeStub, fn conn -> Req.Test.text(conn, "12345") end)

      assert {:error, :response_too_large} =
               HTTPPolicy.bounded_request(
                 [
                   url: "https://public.example/data",
                   plug: {Req.Test, Cinder.HTTPPolicyLargeStub}
                 ],
                 4
               )
    end
  end

  describe "sanitize_log/1" do
    test "removes CR/LF and bounds remote strings" do
      sanitized = HTTPPolicy.sanitize_log("remote\r\nforged:" <> String.duplicate("x", 600))

      refute sanitized =~ "\r"
      refute sanitized =~ "\n"
      assert byte_size(sanitized) <= 500
      assert String.starts_with?(sanitized, "remoteforged:")
    end
  end
end
