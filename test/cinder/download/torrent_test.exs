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
end
