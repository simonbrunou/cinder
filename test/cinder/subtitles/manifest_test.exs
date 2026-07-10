defmodule Cinder.Subtitles.ManifestTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Subtitles.Manifest

  setup :verify_on_exit!

  test "path/1 uses a hidden adjacent manifest" do
    assert Manifest.path("/lib/M/M.mkv") == "/lib/M/.M.mkv.cinder-subtitles.json"
  end

  test "read/1 falls back when the manifest is missing" do
    expect(Cinder.Library.FilesystemMock, :read, fn "/lib/M/.M.mkv.cinder-subtitles.json" ->
      {:error, :enoent}
    end)

    assert Manifest.read("/lib/M/M.mkv") == %{video_moviehash: nil, tracks: %{}}
  end

  test "read/1 falls back and warns when the manifest is corrupt" do
    expect(Cinder.Library.FilesystemMock, :read, fn "/lib/M/.M.mkv.cinder-subtitles.json" ->
      {:ok, "not json"}
    end)

    log =
      capture_log(fn ->
        assert Manifest.read("/lib/M/M.mkv") == %{video_moviehash: nil, tracks: %{}}
      end)

    assert log =~ "subtitle manifest"
  end

  test "stable?/3 needs a current hash and provisional?/3 invalidates an old hash" do
    state = %{video_moviehash: "old", tracks: %{"fr" => %{origin: "opensubtitles_hash"}}}

    assert Manifest.stable?(state, "old", "fr")
    refute Manifest.stable?(state, "new", "fr")
    assert Manifest.provisional?(state, "new", "fr")
  end

  test "put/4 writes a temporary manifest before renaming it into place" do
    manifest = "/lib/M/.M.mkv.cinder-subtitles.json"

    expect(Cinder.Library.FilesystemMock, :read, fn ^manifest -> {:error, :enoent} end)

    expect(Cinder.Library.FilesystemMock, :write, fn temporary, json ->
      assert Path.dirname(temporary) == "/lib/M"
      assert String.contains?(temporary, ".cinder-subtitle-manifest-")

      assert %{"video_moviehash" => "hash", "tracks" => %{"fr" => %{"origin" => "embedded"}}} =
               Jason.decode!(json)

      :ok
    end)

    expect(Cinder.Library.FilesystemMock, :rename, fn temporary, ^manifest ->
      assert String.contains?(temporary, ".cinder-subtitle-manifest-")
      :ok
    end)

    assert :ok = Manifest.put("/lib/M/M.mkv", "hash", "fr", "embedded")
  end
end
