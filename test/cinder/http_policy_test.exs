defmodule Cinder.HTTPPolicyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cinder.HTTPPolicy

  @request_task_event [:cinder, :http, :request_task]

  @public_ipv4 {93, 184, 216, 34}
  @public_ipv6 {0x2606, 0x2800, 0x220, 0x1, 0x248, 0x1893, 0x25C8, 0x1946}

  # Elixir 1.20.5's `URI.parse/1` drops each of these ports, so the merged URI alone would have no
  # port and read as 443 (#1102): above 65535, seven digits (parse's other drop branch),
  # scheme-relative, an IPv6 host, and a path that `URI.new/1` rejects.
  @out_of_range_port_locations [
    "https://public.example:65536/next",
    "https://cdn.example:70000/next",
    "https://cdn.example:1234567/next",
    "//cdn.example:70000/next",
    "https://[2606:2800:220:1:248:1893:25c8:1946]:70000/next",
    "https://cdn.example:70000/a b"
  ]

  # An absolute and a scheme-relative Location whose host holds a byte that is not valid UTF-8.
  @invalid_host_locations ["https://\xff.example/x", "//\xff.example/x"]

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
        validated = HTTPPolicy.validate_untrusted_url(url, resolver)
        assert match?({:error, :forbidden_address}, validated), "#{url}: #{inspect(validated)}"
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

  describe "untrusted_request_target/2" do
    test "pins the transport URL to the validated address while preserving the HTTP hostname" do
      resolver = fn "public.example" -> {:ok, [@public_ipv4]} end

      assert {:ok, target} =
               HTTPPolicy.untrusted_request_target(
                 "https://public.example/releases/file.torrent",
                 resolver
               )

      assert target.uri.host == "public.example"
      assert target.url.host == "93.184.216.34"
      assert target.connect_options == [hostname: "public.example"]

      options =
        HTTPPolicy.request_options(target,
          connect_options: [timeout: 5_000],
          headers: [{"host", "unsafe.example"}, {"x-test", "value"}]
        )

      assert %URI{host: "93.184.216.34"} = options[:url]
      assert options[:connect_options] == [timeout: 5_000, hostname: "public.example"]
      assert options[:headers] == [{"host", "public.example"}, {"x-test", "value"}]
    end

    test "keeps a configured same-origin private source unpinned" do
      resolver = fn _host -> flunk("a configured same-origin source must not use DNS") end

      assert {:ok, target} =
               HTTPPolicy.source_request_target(
                 "http://127.0.0.1:9696/download/1",
                 "http://127.0.0.1:9696",
                 resolver
               )

      assert target.uri == target.url
      assert target.connect_options == []
    end
  end

  describe "validate_untrusted_host/2" do
    test "rejects a forbidden literal address with no scheme involved" do
      resolver = fn _host -> flunk("literal addresses must not use DNS") end

      # No brackets: this takes a bare host, e.g. the un-bracketed form `URI.new/1` already
      # produces for `http://[::1]`'s `.host`, not a URL's bracketed authority component.
      for host <- ["127.0.0.1", "169.254.169.254", "10.0.0.1", "::1"] do
        validated = HTTPPolicy.validate_untrusted_host(host, resolver)
        assert match?({:error, :forbidden_address}, validated), "#{host}: #{inspect(validated)}"
      end
    end

    test "rejects a DNS answer set if any address is forbidden" do
      resolver = fn "tracker.example" -> {:ok, [@public_ipv4, {10, 0, 0, 1}]} end

      assert {:error, :forbidden_address} =
               HTTPPolicy.validate_untrusted_host("tracker.example", resolver)
    end

    test "accepts a safe hostname (e.g. a torrent tracker, no HTTP scheme required)" do
      resolver = fn "tracker.example" -> {:ok, [@public_ipv4]} end

      assert :ok = HTTPPolicy.validate_untrusted_host("tracker.example", resolver)
    end

    test "rejects an empty host" do
      resolver = fn _host -> flunk("an empty host must not use DNS") end
      assert {:error, :missing_host} = HTTPPolicy.validate_untrusted_host("", resolver)
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

  describe "source_origin/1" do
    test "keeps a URL with neither user info nor a fragment as the same text" do
      for url <- ["http://prowlarr:80", "HTTP://Prowlarr:9696/p?q=1", "https://[::1]"] do
        assert HTTPPolicy.source_origin(url) == url
      end
    end

    test "removes user info and a fragment, and source_request_target/3 accepts the result" do
      for {url, origin} <- [
            {"http://user:pw@prowlarr:9696", "http://prowlarr:9696"},
            {"http://@prowlarr:9696#", "http://prowlarr:9696"},
            {"https://user@Prowlarr:443/p?q=1#frag", "https://Prowlarr/p?q=1"}
          ] do
        assert HTTPPolicy.source_origin(url) == origin
        assert HTTPPolicy.same_origin?(url, origin)

        assert {:ok, %{connect_options: []}} =
                 HTTPPolicy.source_request_target(
                   "#{origin}/1/download",
                   origin,
                   fn _host -> flunk("the source origin must not use DNS validation") end
                 )
      end
    end

    test "returns nil for text URI.new/1 rejects" do
      assert HTTPPolicy.source_origin("http://prow larr:9696") == nil
      assert HTTPPolicy.source_origin("http://user@prowlarr:9696/" <> <<0xFF>>) == nil
    end
  end

  describe "out-of-range ports on a source URL or an untrusted redirect" do
    test "validate_source_url/3 and source_request_target/3 refuse one on the source's own host" do
      resolver = &refuse_dns/1

      for url <- ["https://indexer.example:65536/get", "https://indexer.example:70000/a b"] do
        validated = HTTPPolicy.validate_source_url(url, "https://indexer.example", resolver)
        assert validated == {:error, :invalid_port}, "#{url}: #{inspect(validated)}"

        target = HTTPPolicy.source_request_target(url, "https://indexer.example", resolver)
        assert target == {:error, :invalid_port}, "#{url}: #{inspect(target)}"
      end
    end

    test "untrusted_redirect_target/3 refuses one before any DNS lookup" do
      resolver = &refuse_dns/1

      for location <- @out_of_range_port_locations do
        target =
          HTTPPolicy.untrusted_redirect_target("https://public.example/start", location, resolver)

        assert target == {:error, :invalid_port}, "#{location}: #{inspect(target)}"
      end
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

    test "rejects an out-of-range redirect port under each policy, before any DNS lookup" do
      resolver = &refuse_dns/1

      for location <- @out_of_range_port_locations,
          {label, policy} <- [same_origin: :same_origin, resolver: resolver] do
        result =
          HTTPPolicy.resolve_redirect("https://public.example:443/start", location, policy)

        assert result == {:error, :invalid_port},
               "#{location} under #{label}: #{inspect(result)}"
      end
    end

    # The download clients turn a redirect's `:unsupported_scheme` into `:unsupported_download_url`,
    # which parks a movie's search at once, where `:invalid_port` counts one failed attempt. So an
    # out-of-range port keeps the answer of the scheme and host checks.
    test "checks a redirect's scheme and host before its out-of-range port" do
      for {location, expected} <- [
            {"ftp://cdn.example:70000/next", {:error, :unsupported_scheme}},
            {"https://:70000/next", {:error, :missing_host}}
          ],
          {label, policy} <- [same_origin: :same_origin, resolver: &refuse_dns/1] do
        result = HTTPPolicy.resolve_redirect("https://public.example/start", location, policy)
        assert result == expected, "#{location} under #{label}: #{inspect(result)}"
      end
    end

    test "resolves a Location with no port or an in-range port as the merge does" do
      resolver = fn _host -> {:ok, [@public_ipv4]} end

      for {location, expected} <- [
            {"/files/a b", "https://public.example/files/a b"},
            {"//public.example/next", "https://public.example/next"},
            {"https://public.example:/next", "https://public.example/next"},
            {"//public.example:00443/next", "https://public.example/next"},
            # The merge ignores an authority with no host, so its port too.
            {"//:70000/next", "https://public.example/next"}
          ],
          {label, policy} <- [same_origin: :same_origin, resolver: resolver] do
        resolved =
          with {:ok, uri} <-
                 HTTPPolicy.resolve_redirect("https://public.example/start", location, policy),
               do: {:ok, URI.to_string(uri)}

        assert resolved == {:ok, expected}, "#{location} under #{label}"
      end

      assert {:ok, %URI{port: 8443} = uri} =
               HTTPPolicy.resolve_redirect(
                 "https://public.example/start",
                 "https://cdn.example:8443/next",
                 resolver
               )

      assert URI.to_string(uri) == "https://cdn.example:8443/next"
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

  # A remote server picks a redirect's Location, and Req passes its bytes on as they came. A host
  # whose bytes are not valid UTF-8 raised from host normalization or `URI.new/1` (#1158).
  describe "a URL or host whose bytes are not valid UTF-8" do
    test "resolve_redirect/3 refuses such a host under each policy, before any DNS lookup" do
      for location <- @invalid_host_locations,
          {label, policy} <- [
            same_origin: :same_origin,
            untrusted: :untrusted,
            resolver: &refuse_invalid_host_dns/1
          ] do
        result = HTTPPolicy.resolve_redirect("https://public.example/start", location, policy)

        assert result == {:error, :invalid_url},
               "#{inspect(location)} under #{label}: #{inspect(result)}"
      end
    end

    test "untrusted_redirect_target/3 refuses such a host before any DNS lookup" do
      for location <- @invalid_host_locations do
        result =
          HTTPPolicy.untrusted_redirect_target(
            "https://public.example/start",
            location,
            &refuse_invalid_host_dns/1
          )

        assert result == {:error, :invalid_url}, "#{inspect(location)}: #{inspect(result)}"
      end
    end

    test "validate_untrusted_url/2 and untrusted_request_target/2 refuse such a byte anywhere in a string URL, and in a parsed host" do
      for url <- [
            "https://\xff.example/x",
            "https://public.example/a\xff",
            URI.parse("https://\xff.example/x")
          ] do
        validated = HTTPPolicy.validate_untrusted_url(url, &refuse_invalid_host_dns/1)
        assert validated == {:error, :invalid_url}, "#{inspect(url)}: #{inspect(validated)}"

        target = HTTPPolicy.untrusted_request_target(url, &refuse_invalid_host_dns/1)
        assert target == {:error, :invalid_url}, "#{inspect(url)}: #{inspect(target)}"
      end
    end

    test "validate_source_url/3 and source_request_target/3 refuse such a host, and such a path off the source's origin" do
      for url <- [
            "https://\xff.example/x",
            URI.parse("https://\xff.example/x"),
            "https://other.example/a\xff"
          ] do
        validated =
          HTTPPolicy.validate_source_url(
            url,
            "https://public.example",
            &refuse_invalid_host_dns/1
          )

        assert validated == {:error, :invalid_url}, "#{inspect(url)}: #{inspect(validated)}"

        target =
          HTTPPolicy.source_request_target(
            url,
            "https://public.example",
            &refuse_invalid_host_dns/1
          )

        assert target == {:error, :invalid_url}, "#{inspect(url)}: #{inspect(target)}"
      end
    end

    test "validate_source_url/3 and source_request_target/3 still accept such a path on the source's own origin" do
      url = "https://public.example/a\xff"

      assert {:ok, %URI{host: "public.example", path: "/a\xff"}} =
               HTTPPolicy.validate_source_url(
                 url,
                 "https://public.example",
                 &refuse_invalid_host_dns/1
               )

      assert {:ok, %{uri: %URI{host: "public.example", path: "/a\xff"}, connect_options: []}} =
               HTTPPolicy.source_request_target(
                 url,
                 "https://public.example",
                 &refuse_invalid_host_dns/1
               )
    end

    test "same_origin?/2 is false when either side has such a host" do
      invalid = "https://\xff.example/"
      valid = "https://public.example/"

      for left <- [invalid, URI.parse(invalid)],
          right <- [invalid, URI.parse(invalid), valid, URI.parse(valid)] do
        refute HTTPPolicy.same_origin?(left, right), "#{inspect(left)} vs #{inspect(right)}"
        refute HTTPPolicy.same_origin?(right, left), "#{inspect(right)} vs #{inspect(left)}"
      end
    end

    test "validate_untrusted_host/2 refuses such a host before any DNS lookup" do
      assert {:error, :invalid_url} =
               HTTPPolicy.validate_untrusted_host("\xff.example", &refuse_invalid_host_dns/1)
    end

    # The download clients turn `:unsupported_scheme` into the permanent `:unsupported_download_url`,
    # and an invalid host must not read as `:invalid_port`. The `:0` port survives the parse and
    # fails the port check; the `:70000` one is the port that the merge drops (#1102).
    test "a redirect's scheme comes before its host bytes, and its host bytes before its port" do
      cases = [
        {"ftp://\xff.example/x", {:error, :unsupported_scheme}},
        {"https://\xff.example:70000/x", {:error, :invalid_url}},
        {"https://\xff.example:0/x", {:error, :invalid_url}}
      ]

      for {location, expected} <- cases,
          {label, policy} <- [same_origin: :same_origin, resolver: &refuse_invalid_host_dns/1] do
        result = HTTPPolicy.resolve_redirect("https://public.example/start", location, policy)
        assert result == expected, "#{inspect(location)} under #{label}: #{inspect(result)}"
      end

      for {location, expected} <- cases do
        result =
          HTTPPolicy.untrusted_redirect_target(
            "https://public.example/start",
            location,
            &refuse_invalid_host_dns/1
          )

        assert result == expected, "#{inspect(location)}: #{inspect(result)}"
      end
    end

    test "a valid UTF-8 non-ASCII host and a percent-encoded host still reach the resolver" do
      parent = self()

      resolver = fn host ->
        send(parent, {:resolved, host})
        {:ok, [@public_ipv4]}
      end

      for host <- ["é.example", "%ff.example"] do
        assert {:ok, %{uri: %URI{host: ^host}}} =
                 HTTPPolicy.untrusted_redirect_target(
                   "https://public.example/start",
                   "https://#{host}/x",
                   resolver
                 )

        assert_received {:resolved, ^host}

        assert :ok = HTTPPolicy.validate_untrusted_host(host, resolver)
        assert_received {:resolved, ^host}
      end
    end

    test "such a byte in a redirect's path or query still resolves" do
      resolver = fn _host -> {:ok, [@public_ipv4]} end

      for {location, expected} <- [
            {"/a\xffb", "https://public.example/a\xffb"},
            {"/a?q=\xff", "https://public.example/a?q=\xff"}
          ],
          {label, policy} <- [same_origin: :same_origin, resolver: resolver] do
        resolved =
          with {:ok, uri} <-
                 HTTPPolicy.resolve_redirect("https://public.example/start", location, policy),
               do: {:ok, URI.to_string(uri)}

        assert resolved == {:ok, expected}, "#{inspect(location)} under #{label}"
      end
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

    test "a caller that reaches the stub's owner only through $callers gets the stub's response" do
      Req.Test.stub(Cinder.HTTPPolicyCallersStub, fn conn -> Req.Test.json(conn, %{ok: true}) end)

      # The task can't grant access to the stub (it doesn't own it), as a `Cinder.Health` probe
      # in a sweep task can't.
      task =
        Task.async(fn ->
          HTTPPolicy.bounded_request(
            [
              url: "https://public.example/data",
              plug: {Req.Test, Cinder.HTTPPolicyCallersStub}
            ],
            64
          )
        end)

      assert {:ok, %{status: 200, body: %{"ok" => true}}} = Task.await(task)
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

      # 500ms, not 50: the assertion is "completes *within* the deadline", and a 5ms sleep plus
      # scheduling overhead on a loaded runner blew a 50ms budget about 1 run in 15 (#246).
      assert {:ok, %{body: "firstsecond"}} =
               HTTPPolicy.bounded_request(Req.new(adapter: adapter), 64, 500)
    end

    test "cancels a request blocked before headers at the wall-clock deadline" do
      parent = self()

      Req.Test.stub(Cinder.HTTPPolicyBlockedStub, fn conn ->
        send(parent, {:request_started, self()})
        # Block until the wall-clock deadline cancels (kills) this request task — the behavior
        # under test — instead of sleeping a fixed span tuned above the deadline. The generous
        # `after` is only a safety valve so a regressed deadline fails within seconds rather than
        # hanging the suite; on the happy path the task is killed long before it elapses.
        receive do
          :never -> :ok
        after
          10_000 -> :ok
        end

        Req.Test.text(conn, "late-secret")
      end)

      started_at = System.monotonic_time(:millisecond)

      task_pid =
        Cinder.TelemetryHelpers.capture(@request_task_event, fn ->
          HTTPPolicy.bounded_request(
            [
              url: "https://public.example/blocked",
              plug: {Req.Test, Cinder.HTTPPolicyBlockedStub}
            ],
            64,
            500
          )
        end)
        |> assert_killed_at_deadline(started_at)

      # A runner slower than the deadline to bring the task to the stub leaves no stub message
      # (#1092), so the test found the task through the event above and the message is optional.
      receive do
        {:request_started, request_pid} -> assert request_pid == task_pid
      after
        0 -> :ok
      end

      assert late_messages() == []
    end

    test "cancels a request whose task reaches the stub only after the deadline" do
      parent = self()

      Req.Test.stub(Cinder.HTTPPolicySlowStartStub, fn conn ->
        send(parent, {:request_started, self()})
        Req.Test.text(conn, "late-secret")
      end)

      # A request step holds the task for 10 s before Req's pipeline reaches the plug: the slow
      # task start of #1092, made longer than every bound here. The deadline kills the task during
      # the hold, and the elapsed bound below ends before the hold does, so a call that passes it
      # killed the task before the stub ran and the test can refute the stub's message outright. A
      # deadline that never cancels lets the hold end and the stub's body through, which fails the
      # match and the bound.
      request =
        [
          url: "https://public.example/slow-start",
          plug: {Req.Test, Cinder.HTTPPolicySlowStartStub}
        ]
        |> Req.new()
        |> Req.Request.append_request_steps(
          slow_start: fn request ->
            receive do
              :never -> :ok
            after
              10_000 -> :ok
            end

            request
          end
        )

      started_at = System.monotonic_time(:millisecond)

      Cinder.TelemetryHelpers.capture(@request_task_event, fn ->
        HTTPPolicy.bounded_request(request, 64, 500)
      end)
      |> assert_killed_at_deadline(started_at)

      assert late_messages() == []
    end

    test "gives each of two concurrent calls its own request task event" do
      parent = self()

      Req.Test.stub(Cinder.HTTPPolicyConcurrentStub, fn conn ->
        # The request task's `$callers` starts with the process that called `bounded_request/3`.
        [caller | _] = Process.get(:"$callers")
        send(parent, {:request_started, caller, self()})

        # Hold each request until the test has seen both, so the two calls overlap. The valve
        # only keeps a lost release from hanging the suite.
        receive do
          :release -> :ok
        after
          10_000 -> :ok
        end

        Req.Test.text(conn, "ok")
      end)

      call = fn ->
        HTTPPolicy.bounded_request(
          [
            url: "https://public.example/concurrent",
            plug: {Req.Test, Cinder.HTTPPolicyConcurrentStub}
          ],
          64,
          30_000
        )
      end

      {{caller_tasks, stub_tasks, results}, events} =
        Cinder.TelemetryHelpers.capture(@request_task_event, fn ->
          caller_tasks = [Task.async(call), Task.async(call)]
          assert_receive {:request_started, first_caller, first_task}
          assert_receive {:request_started, second_caller, second_task}
          send(first_task, :release)
          send(second_task, :release)
          stub_tasks = %{first_caller => first_task, second_caller => second_task}
          {caller_tasks, stub_tasks, Task.await_many(caller_tasks)}
        end)

      assert [{:ok, %{body: "ok"}}, {:ok, %{body: "ok"}}] = results
      caller_pids = Enum.map(caller_tasks, & &1.pid)
      assert Enum.sort(Map.keys(stub_tasks)) == Enum.sort(caller_pids)

      # Each caller's event names the task that reached the stub for that caller, and only it.
      for caller <- caller_pids do
        assert request_task_pids(events, caller) == [Map.fetch!(stub_tasks, caller)]
      end

      assert [first_task, second_task] = Map.values(stub_tasks)
      refute first_task == second_task
    end

    test "emits [:cinder, :http, :request] with the host, duration, and :ok on success" do
      Req.Test.stub(Cinder.HTTPPolicyTelemetryOkStub, fn conn ->
        Req.Test.json(conn, %{ok: true})
      end)

      {result, events} =
        Cinder.TelemetryHelpers.capture([:cinder, :http, :request], fn ->
          HTTPPolicy.bounded_request(
            [
              url: "https://public.example/data",
              plug: {Req.Test, Cinder.HTTPPolicyTelemetryOkStub}
            ],
            64,
            5_000
          )
        end)

      assert {:ok, %{status: 200}} = result
      # Scope to this request's own host: [:cinder, :http, :request] is a global telemetry event,
      # so a concurrent async test's HTTP request would otherwise bleed into `events`.
      own = Enum.filter(events, fn {_m, %{host: h}} -> h == "public.example" end)
      assert [{%{duration: duration}, %{host: "public.example", status: :ok}}] = own
      assert is_integer(duration) and duration >= 0
    end

    test "emits [:cinder, :http, :request] with :error on a bounded-request failure" do
      Req.Test.stub(Cinder.HTTPPolicyTelemetryErrorStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{bad}")
      end)

      {result, events} =
        Cinder.TelemetryHelpers.capture([:cinder, :http, :request], fn ->
          HTTPPolicy.bounded_request(
            [
              url: "https://public.example/data",
              plug: {Req.Test, Cinder.HTTPPolicyTelemetryErrorStub}
            ],
            4,
            5_000
          )
        end)

      assert {:error, :response_too_large} = result
      # Scope to this request's own host (see the :ok case): the event name is global.
      own = Enum.filter(events, fn {_m, %{host: h}} -> h == "public.example" end)
      assert [{%{duration: _}, %{host: "public.example", status: :error}}] = own
    end

    test "isolates an unexpected request crash from the caller" do
      adapter = fn _request -> raise "adapter crashed" end

      # Generous deadline on purpose: this asserts the crash PROPAGATES (isolation), not timeout
      # behaviour, so the near-instant crash must win the race against the deadline even under a
      # loaded suite. A tight bound (was 200ms) let the deadline occasionally fire first, returning
      # {:error, :request_timeout} — the intermittent suite failure. Timeout behaviour is covered by
      # the :request_timeout tests above.
      capture_log(fn ->
        assert {:error, {%RuntimeError{message: "adapter crashed"}, _stacktrace}} =
                 HTTPPolicy.bounded_request(Req.new(adapter: adapter), 64, 5_000)
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

  # Checks a `bounded_request/3` call that the 500 ms deadline cancelled, from the
  # `{result, events}` of `Cinder.TelemetryHelpers.capture/2`, and returns its request task's pid.
  #
  # The elapsed bound sits 5 s past the deadline, the house bound for a wall-clock load flake
  # (docs/agents/ci.md "Wall-clock tests"). Loaded runners returned 336 ms (#908), then 875 ms
  # (#1038) past the deadline, since each step around it (the task start, `Req.Test.allow`, the
  # kill) waits for a shared process to reply or for the test process to run again. A deadline of
  # 5.5 s or more still fails this bound. Both tests hold the task for 10 s, above the bound (the
  # stub's valve, the slow-start step), so a request the deadline never cancels fails the bound
  # too. A deadline past those 10 s also lets the stub's body through, which fails the result
  # match.
  defp assert_killed_at_deadline({result, events}, started_at) do
    assert {:error, :request_timeout} = result
    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed < 5_500
    assert [task_pid] = request_task_pids(events, self())
    refute Process.alive?(task_pid)
    task_pid
  end

  # The request tasks that `caller`'s own `bounded_request/3` calls started, from the events of
  # `Cinder.TelemetryHelpers.capture/2`. Its handler forwards the event from every process, so a
  # concurrent async test's call is in `events` too: the caller in the metadata tells them apart.
  defp request_task_pids(events, caller) do
    for {_measurements, %{caller: ^caller, task_pid: task_pid}} <- events, do: task_pid
  end

  defp refuse_dns(host), do: flunk("an out-of-range port must not resolve #{host}")

  defp refuse_invalid_host_dns(host),
    do: flunk("a URL that is not valid UTF-8 must not resolve #{inspect(host)}")

  # The test process's mailbox, without the events `Cinder.TelemetryHelpers.capture/2` forwarded
  # after it drained. A process that found its handler before `:telemetry.detach/1` can still
  # send one, so another async test's `bounded_request/3` call can leave one here.
  defp late_messages do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.reject(messages, &match?({:telemetry_captured, _ref, _measurements, _metadata}, &1))
  end
end
