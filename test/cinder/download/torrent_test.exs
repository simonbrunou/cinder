defmodule Cinder.Download.TorrentTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.Torrent

  # Minimal valid torrent: d 8:announce 11:http://x/an 4:info <infoval> e
  defp torrent(infoval), do: "d8:announce11:http://x/an4:info" <> infoval <> "e"

  test "computes SHA-1 of the original info value (not a re-encode)" do
    infoval = "d6:lengthi1024e4:name5:M.mkv12:piece lengthi16384ee"
    expected = :crypto.hash(:sha, infoval) |> Base.encode16(case: :lower)
    assert {:ok, ^expected} = Torrent.infohash(torrent(infoval))
  end

  test "handles nested lists and dicts inside info" do
    infoval = "d5:filesld6:lengthi1e4:pathl1:aeee4:name1:xe"
    expected = :crypto.hash(:sha, infoval) |> Base.encode16(case: :lower)
    assert {:ok, ^expected} = Torrent.infohash(torrent(infoval))
  end

  test "uses the truncated SHA-256 id for a v2-only torrent" do
    infoval =
      "d9:file treed5:M.mkvd0:d6:lengthi5e11:pieces root32:#{String.duplicate("x", 32)}eee" <>
        "12:meta versioni2e4:name5:M.mkv12:piece lengthi16384ee"

    expected = :crypto.hash(:sha256, infoval) |> binary_part(0, 20) |> Base.encode16(case: :lower)
    assert {:ok, ^expected} = Torrent.infohash(torrent(infoval))
  end

  test "uses the truncated SHA-256 id for a hybrid torrent" do
    infoval =
      "d9:file treed5:M.mkvd0:d6:lengthi5e11:pieces root32:#{String.duplicate("x", 32)}eee" <>
        "6:lengthi5e12:meta versioni2e4:name5:M.mkv12:piece lengthi16384e" <>
        "6:pieces20:#{String.duplicate("y", 20)}e"

    expected = :crypto.hash(:sha256, infoval) |> binary_part(0, 20) |> Base.encode16(case: :lower)
    assert {:ok, ^expected} = Torrent.infohash(torrent(infoval))
  end

  test "rejects an unsupported metainfo version" do
    infoval = "d12:meta versioni3e4:name5:M.mkve"
    assert {:error, :bad_torrent} = Torrent.infohash(torrent(infoval))
  end

  test "rejects non-bencode / HTML input" do
    assert {:error, :bad_torrent} = Torrent.infohash("<html>not found</html>")
    assert {:error, :bad_torrent} = Torrent.infohash("")
    # a dict with no info key
    assert {:error, :bad_torrent} = Torrent.infohash("d8:announce3:abce")
    # truncated
    assert {:error, :bad_torrent} = Torrent.infohash("d4:infod6:length")
  end

  test "rejects an oversized byte-string length prefix without CPU amplification" do
    task = Task.async(fn -> Torrent.infohash("d" <> String.duplicate("9", 500_000)) end)
    assert {:error, :bad_torrent} = Task.await(task, 500)
  end

  test "rejects a torrent whose info value is an integer" do
    # "d4:infoi5ee" — info value is bencode integer i5e, not a dict
    assert {:error, :bad_torrent} = Torrent.infohash("d4:infoi5ee")
  end

  test "rejects a torrent whose info value is a string" do
    # "d4:info3:abce" — info value is bencode string "abc", not a dict
    assert {:error, :bad_torrent} = Torrent.infohash("d4:info3:abce")
  end

  test "rejects a torrent whose info value is a list" do
    # "d4:infol1:aee" — info value is bencode list, not a dict
    assert {:error, :bad_torrent} = Torrent.infohash("d4:infol1:aee")
  end

  describe "nesting depth limit" do
    defp nested(n), do: String.duplicate("l", n) <> String.duplicate("e", n)
    defp deep_torrent(n), do: "d4:infod1:a" <> nested(n) <> "6:lengthi1eee"

    test "accepts nesting up to 64 levels (top dict + info dict + 62 lists)" do
      assert {:ok, _hash} = Torrent.infohash(deep_torrent(62))
    end

    test "rejects a well-formed torrent nested past 64 levels" do
      assert {:error, :bad_torrent} = Torrent.infohash(deep_torrent(63))
      assert {:error, :bad_torrent} = Torrent.infohash(deep_torrent(5_000))
    end

    test "rejects a hostile body of millions of unterminated list openers without recursing" do
      body = "d1:a" <> String.duplicate("l", 5_000_000)
      assert {:error, :bad_torrent} = Torrent.infohash(body)
      assert {:error, :bad_torrent} = Torrent.sanitize_embedded_urls(body, &MapSet.new/1)
      assert Torrent.embedded_urls(body) == []
    end

    test "sanitize_embedded_urls/2 rejects deep nesting in a skipped value" do
      bytes = "d1:x" <> nested(200) <> "e"
      assert {:error, :bad_torrent} = Torrent.sanitize_embedded_urls(bytes, &MapSet.new/1)
    end

    test "embedded_urls/1 returns [] for a deeply nested torrent" do
      assert Torrent.embedded_urls("d8:announce11:http://x/an1:x" <> nested(200) <> "e") == []
    end
  end

  # Minimal bencode encoder for building metainfo fixtures without hand-counting byte lengths.
  defp benc(s) when is_binary(s), do: "#{byte_size(s)}:#{s}"
  defp benc(n) when is_integer(n), do: "i#{n}e"
  defp benc(list) when is_list(list), do: "l" <> Enum.map_join(list, &benc/1) <> "e"

  defp torrent_with(fields) do
    info = %{"length" => 1, "name" => "x", "piece length" => 16_384}

    body =
      [{"info", info} | fields]
      |> Enum.map_join(fn {k, v} -> benc(k) <> encode(v) end)

    "d" <> body <> "e"
  end

  defp encode(%{} = map),
    do: "d" <> Enum.map_join(map, fn {k, v} -> benc(k) <> encode(v) end) <> "e"

  defp encode(v), do: benc(v)

  describe "embedded_urls/1" do
    test "extracts announce, announce-list, url-list, and httpseeds" do
      bytes =
        torrent_with([
          {"announce", "http://tracker.a/ann"},
          {"announce-list", [["http://tracker.b/ann"], ["http://tracker.c/ann"]]},
          {"url-list", ["http://seed.a/files/"]},
          {"httpseeds", ["http://seed.b/webseed/"]}
        ])

      urls = Torrent.embedded_urls(bytes)

      for expected <- [
            "http://tracker.a/ann",
            "http://tracker.b/ann",
            "http://tracker.c/ann",
            "http://seed.a/files/",
            "http://seed.b/webseed/"
          ] do
        assert expected in urls
      end
    end

    test "accepts a bare-string url-list (a single web seed, not a list)" do
      bytes = torrent_with([{"url-list", "http://seed.a/files/"}])
      assert Torrent.embedded_urls(bytes) == ["http://seed.a/files/"]
    end

    test "returns [] when no tracker/web-seed fields are present" do
      assert Torrent.embedded_urls(torrent_with([])) == []
    end

    test "returns [] rather than crashing on malformed metainfo" do
      assert Torrent.embedded_urls("<html>nope</html>") == []
      # announce is an integer, not a string — filtered out, not raised on.
      assert Torrent.embedded_urls("d8:announcei5ee") == []
      assert Torrent.embedded_urls("") == []
    end
  end

  describe "sanitize_embedded_urls/2" do
    test "drops rejected URLs, emptied tiers, and emptied fields; the infohash survives" do
      bytes =
        torrent_with([
          {"announce", "http://bad.example/ann"},
          {"announce-list",
           [["http://bad.example/ann", "http://good.example/ann"], ["http://bad.example/2"]]},
          {"url-list", ["http://bad.example/seed"]}
        ])

      {:ok, original_hash} = Torrent.infohash(bytes)
      vet = fn hosts -> hosts |> Enum.reject(&(&1 == "bad.example")) |> MapSet.new() end

      assert {:ok, clean} = Torrent.sanitize_embedded_urls(bytes, vet)
      assert Torrent.embedded_urls(clean) == ["http://good.example/ann"]
      assert Torrent.infohash(clean) == {:ok, original_hash}
    end

    test "an all-approved torrent round-trips byte-identically" do
      bytes =
        torrent_with([
          {"announce", "http://tracker.a/ann"},
          {"url-list", "http://seed.a/files/"}
        ])

      assert {:ok, ^bytes} = Torrent.sanitize_embedded_urls(bytes, &MapSet.new/1)
    end

    test "errors on non-torrent input rather than crashing" do
      assert {:error, :bad_torrent} =
               Torrent.sanitize_embedded_urls("<html>nope</html>", &MapSet.new/1)
    end

    test "hands the vetter every surviving host, lower-cased, in document order" do
      bytes =
        torrent_with([
          {"announce", "http://A.example/ann"},
          {"announce-list", [["udp://b.example:1/x", "ftp://skip.example/x"]]},
          {"url-list", ["https://c.example/f", "http://192.168.1.10:80?@x/y"]}
        ])

      test_pid = self()

      vet = fn hosts ->
        send(test_pid, {:vetted, hosts})
        MapSet.new(hosts)
      end

      assert {:ok, _clean} = Torrent.sanitize_embedded_urls(bytes, vet)
      assert_received {:vetted, ["a.example", "b.example", "c.example"]}
    end

    test "fails closed: drops unparseable, hostless, userinfo, and wrong-scheme endpoints" do
      bytes =
        torrent_with([
          {"announce", "http://192.168.1.10:8123/x?a=>"},
          {"announce-list",
           [
             ["http://attacker.tld:80?@192.168.1.10:8080/announce", "ftp://good.example/a"],
             ["udp://tracker.example:1337/announce", "http:///nohost", "garbage"]
           ]},
          {"url-list", ["udp://seed.example/x", "https://seed.example/files/"]},
          {"nodes", [["192.168.1.10", 6881]]}
        ])

      {:ok, hash} = Torrent.infohash(bytes)

      assert {:ok, clean} = Torrent.sanitize_embedded_urls(bytes, &MapSet.new/1)

      assert Enum.sort(Torrent.embedded_urls(clean)) ==
               ["https://seed.example/files/", "udp://tracker.example:1337/announce"]

      refute clean =~ "nodes"
      assert Torrent.infohash(clean) == {:ok, hash}
    end
  end

  describe "sanitize_magnet/2" do
    @xt "xt=urn:btih:0123456789abcdef0123456789abcdef01234567"

    test "normalizes keys, drops x.pe and dht, keeps other params" do
      magnet =
        "magnet:?#{@xt}&dn=Movie&TR=#{enc("udp://192.168.1.10:1/a")}&tr.1=#{enc("udp://192.168.1.10:1/b")}" <>
          "&tr.=#{enc("udp://192.168.1.10:1/c")}&TR.=#{enc("udp://192.168.1.10:1/d")}" <>
          "&tr.x=#{enc("udp://192.168.1.10:1/e")}&ws.=#{enc("http://192.168.1.10/f")}" <>
          "&x.pe.1=192.168.1.10:6881&DHT.2=192.168.1.10:6881" <>
          "&x.pe=192.168.1.10:6881&dht=192.168.1.10:6881&tr=#{enc("udp://good.example:1/a")}"

      vet = fn hosts -> MapSet.new(Enum.filter(hosts, &(&1 == "good.example"))) end
      assert {:ok, clean} = Torrent.sanitize_magnet(magnet, vet)

      assert URI.decode_query(URI.parse(clean).query) ==
               %{
                 "xt" => "urn:btih:0123456789abcdef0123456789abcdef01234567",
                 "dn" => "Movie",
                 "tr" => "udp://good.example:1/a"
               }
    end

    test "drops unparseable, userinfo, and wrong-scheme endpoints" do
      magnet =
        "magnet:?#{@xt}&tr=#{enc("http://192.168.1.10:8123/x?a=>")}" <>
          "&tr=#{enc("http://attacker.tld:80?@192.168.1.10:8080/announce")}" <>
          "&ws=#{enc("udp://good.example/x")}&xs=#{enc("ftp://good.example/x")}"

      assert {:ok, clean} = Torrent.sanitize_magnet(magnet, &MapSet.new/1)

      assert URI.decode_query(URI.parse(clean).query) == %{
               "xt" => "urn:btih:0123456789abcdef0123456789abcdef01234567"
             }
    end

    test "rejects a magnet it cannot parse" do
      assert {:error, :bad_magnet} =
               Torrent.sanitize_magnet(
                 "magnet:?xt=urn:btih:ab&tr=http://10.0.0.1:80/x?a=>",
                 &MapSet.new/1
               )

      assert {:error, :bad_magnet} = Torrent.sanitize_magnet("magnet:", &MapSet.new/1)
    end

    defp enc(s), do: URI.encode_www_form(s)
  end
end
