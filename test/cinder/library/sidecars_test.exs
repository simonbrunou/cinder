defmodule Cinder.Library.SidecarsTest do
  use ExUnit.Case, async: true
  import Mox
  setup :verify_on_exit!

  alias Cinder.Library.FilesystemMock
  alias Cinder.Library.Sidecars

  test "language/1 maps filename tokens to iso codes; flags ignored; unknown -> und" do
    assert Sidecars.language("Movie (2020).en.srt") == "en"
    assert Sidecars.language("Movie (2020).eng.forced.srt") == "en"
    assert Sidecars.language("Movie (2020).fre.srt") == "fr"
    assert Sidecars.language("subs.srt") == "und"
    assert Sidecars.language("Movie (2020).forced.srt") == "und"
  end

  test "files/1 returns stem-matching sidecars with languages" do
    dir = "/dl/Movie (2020)"
    src = "#{dir}/Movie (2020).mkv"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok,
       [
         {"#{dir}/Movie (2020).mkv", 900},
         {"#{dir}/Movie (2020).en.srt", 10},
         {"#{dir}/Movie (2020).fr.srt", 10},
         {"#{dir}/other.txt", 1}
       ]}
    end)

    assert Sidecars.files(src) == [
             {"#{dir}/Movie (2020).en.srt", "en"},
             {"#{dir}/Movie (2020).fr.srt", "fr"}
           ]
  end

  test "link/2 hardlinks each sidecar next to the dest, renamed, returns languages" do
    dir = "/dl/Movie (2020)"
    src = "#{dir}/Movie (2020).mkv"
    dest = "/lib/Movie (2020)/Movie (2020).mkv"
    sub_src = "#{dir}/Movie (2020).en.srt"
    sub_dest = "/lib/Movie (2020)/Movie (2020).en.srt"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok, [{src, 900}, {sub_src, 10}]}
    end)

    expect(FilesystemMock, :ln, fn ^sub_src, ^sub_dest -> :ok end)

    assert Sidecars.link(src, dest) == ["en"]
  end
end
