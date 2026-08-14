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
      keep? = fn url -> not String.contains?(url, "bad.example") end

      assert {:ok, clean} = Torrent.sanitize_embedded_urls(bytes, keep?)
      assert Torrent.embedded_urls(clean) == ["http://good.example/ann"]
      assert Torrent.infohash(clean) == {:ok, original_hash}
    end

    test "an all-approved torrent round-trips byte-identically" do
      bytes =
        torrent_with([
          {"announce", "http://tracker.a/ann"},
          {"url-list", "http://seed.a/files/"}
        ])

      assert {:ok, ^bytes} = Torrent.sanitize_embedded_urls(bytes, fn _url -> true end)
    end

    test "errors on non-torrent input rather than crashing" do
      assert {:error, :bad_torrent} =
               Torrent.sanitize_embedded_urls("<html>nope</html>", fn _url -> true end)
    end
  end
end
