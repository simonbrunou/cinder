defmodule Cinder.HTTPPolicyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cinder.HTTPPolicy

  @public_ipv4 {93, 184, 216, 34}
  @public_ipv6 {0x2606, 0x2800, 0x220, 0x1, 0x248, 0x1893, 0x25C8, 0x1946}

  describe "same_origin?/2" do
    test "normalizes scheme and host case and default ports" do
      assert HTTPPolicy.same_origin?("HTTP://Example.COM/path", "http://example.com:80/other")
      assert HTTPPolicy.same_origin?("https://EXAMPLE.com", "HTTPS://example.COM:443/path")
      assert HTTPPolicy.same_origin?("https://example.com:8443/a", "https://EXAMPLE.com:8443/b")
    end

    test "canonicalizes equivalent IP literal hosts" do
      for alternate <- ["2130706433", "0x7f000001", "017700000001", "127.1"] do
        assert HTTPPolicy.same_origin?("http://#{alternate}/a", "http://127.0.0.1/b")
      end

      assert HTTPPolicy.same_origin?(
               "https://[2001:0db8:0:0:0:0:0:1]/a",
               "https://[2001:db8::1]/b"
             )
    end

    test "rejects different schemes, hosts, and effective ports" do
      refute HTTPPolicy.same_origin?("http://example.com", "https://example.com")
      refute HTTPPolicy.same_origin?("https://example.com", "https://other.example")
      refute HTTPPolicy.same_origin?("https://example.com", "https://example.com:444")
      refute HTTPPolicy.same_origin?("https://[2001:db8::1]", "https://[2001:db8::2]")
      refute HTTPPolicy.same_origin?("https://example.com:0", "https://example.com:0")
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

    test "rejects invalid ports before resolution and accepts a valid non-default port" do
      resolver = fn
        "public.example" -> {:ok, [@public_ipv4]}
        _host -> flunk("invalid ports must not use DNS")
      end

      assert {:error, :invalid_port} =
               HTTPPolicy.validate_untrusted_url("https://invalid.example:0/file", resolver)

      assert {:error, :invalid_port} =
               HTTPPolicy.validate_untrusted_url("https://invalid.example:65536/file", resolver)

      assert {:ok, %URI{port: 8443}} =
               HTTPPolicy.validate_untrusted_url("https://public.example:8443/file", resolver)
    end
  end

  describe "validate_source_url/3" do
    test "allows a private URL only when it matches its recorded source origin" do
      resolver = fn _host -> flunk("the configured source origin must not use DNS validation") end

      assert {:ok, %URI{host: "127.0.0.1", port: 9696}} =
               HTTPPolicy.validate_source_url(
                 "http://127.0.0.1:9696/download/1",
                 "http://127.0.0.1:9696",
                 resolver
               )

      assert {:error, :forbidden_address} =
               HTTPPolicy.validate_source_url(
                 "http://127.0.0.2/download/1",
                 "http://127.0.0.1:9696",
                 resolver
               )
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

    test "rejects an invalid redirect port" do
      assert {:error, :invalid_port} =
               HTTPPolicy.resolve_redirect(
                 "https://api.example:8443/start",
                 "https://api.example:65536/next",
                 :same_origin
               )
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
    test "decodes application/json only after bounded collection" do
      Req.Test.stub(Cinder.HTTPPolicyStub, fn conn -> Req.Test.json(conn, %{ok: true}) end)

      assert {:ok, %{status: 200, body: %{"ok" => true}}} =
               HTTPPolicy.bounded_request(
                 [
                   url: "https://public.example/data",
                   plug: {Req.Test, Cinder.HTTPPolicyStub}
                 ],
                 64
               )
    end

    test "decodes structured +json media types" do
      Req.Test.stub(Cinder.HTTPPolicyProblemStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/problem+json")
        |> Plug.Conn.send_resp(200, ~s({"error":"nope"}))
      end)

      assert {:ok, %{body: %{"error" => "nope"}}} =
               HTTPPolicy.bounded_request(
                 [
                   url: "https://public.example/problem",
                   plug: {Req.Test, Cinder.HTTPPolicyProblemStub}
                 ],
                 64
               )
    end

    test "preserves raw non-JSON response bytes" do
      bytes = <<0, 255, 1, 2>>

      Req.Test.stub(Cinder.HTTPPolicyBinaryStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-bittorrent")
        |> Plug.Conn.send_resp(200, bytes)
      end)

      assert {:ok, %{body: ^bytes}} =
               HTTPPolicy.bounded_request(
                 [
                   url: "https://public.example/file.torrent",
                   plug: {Req.Test, Cinder.HTTPPolicyBinaryStub}
                 ],
                 64
               )
    end

    test "returns a stable malformed JSON error without retaining remote content" do
      Req.Test.stub(Cinder.HTTPPolicyMalformedJSONStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"token":"super-secret"))
      end)

      assert {:error, :invalid_json} =
               HTTPPolicy.bounded_request(
                 [
                   url: "https://public.example/data",
                   plug: {Req.Test, Cinder.HTTPPolicyMalformedJSONStub}
                 ],
                 64
               )
    end

    test "halts oversized JSON before decoding with a stable error" do
      Req.Test.stub(Cinder.HTTPPolicyLargeStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{bad}")
      end)

      assert {:error, :response_too_large} =
               HTTPPolicy.bounded_request(
                 [
                   url: "https://public.example/data",
                   plug: {Req.Test, Cinder.HTTPPolicyLargeStub}
                 ],
                 4
               )
    end

    test "collects a trickling response that completes within the total deadline" do
      adapter = fn request ->
        response = Req.Response.new(status: 200)
        {:cont, acc} = request.into.({:data, "first"}, {request, response})
        Process.sleep(5)
        {:cont, acc} = request.into.({:data, "second"}, acc)
        acc
      end

      assert {:ok, %{body: "firstsecond"}} =
               HTTPPolicy.bounded_request(Req.new(adapter: adapter), 64, 50)
    end

    test "cancels a request blocked before headers at the wall-clock deadline" do
      parent = self()

      Req.Test.stub(Cinder.HTTPPolicyBlockedStub, fn conn ->
        send(parent, {:request_started, self()})
        Process.sleep(100)
        Req.Test.text(conn, "late-secret")
      end)

      started_at = System.monotonic_time(:millisecond)

      assert {:error, :request_timeout} =
               HTTPPolicy.bounded_request(
                 [
                   url: "https://public.example/blocked",
                   plug: {Req.Test, Cinder.HTTPPolicyBlockedStub}
                 ],
                 64,
                 20
               )

      elapsed = System.monotonic_time(:millisecond) - started_at
      assert elapsed < 80
      assert_received {:request_started, request_pid}
      refute request_pid == self()
      refute Process.alive?(request_pid)
      refute_received _late_task_message
    end

    test "isolates an unexpected request crash from the caller" do
      adapter = fn _request -> raise "adapter crashed" end

      capture_log(fn ->
        assert {:error, {%RuntimeError{message: "adapter crashed"}, _stacktrace}} =
                 HTTPPolicy.bounded_request(Req.new(adapter: adapter), 64, 200)
      end)
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
