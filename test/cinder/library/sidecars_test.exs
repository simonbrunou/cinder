defmodule Cinder.Library.SidecarsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
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
    assert Sidecars.language("The.Italian.Job.2003.srt") == "und"
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

  test "srt_files/1 excludes ASS sidecars while retaining matching SRT sidecars" do
    dir = "/dl/Movie (2020)"
    src = "#{dir}/Movie (2020).mkv"
    srt = "#{dir}/Movie (2020).en.srt"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok,
       [
         {src, 900},
         {srt, 10},
         {"#{dir}/Movie (2020).fr.ass", 10}
       ]}
    end)

    assert Sidecars.srt_files(src) == [{srt, "en"}]
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

  test "files/1 requires a separator boundary so an unpadded E10 sidecar isn't matched to E1" do
    dir = "/dl/Show S01"
    src = "#{dir}/Show.S01E1.mkv"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok,
       [
         {"#{dir}/Show.S01E1.mkv", 900},
         {"#{dir}/Show.S01E10.mkv", 900},
         {"#{dir}/Show.S01E1.en.srt", 10},
         {"#{dir}/Show.S01E10.fr.srt", 10}
       ]}
    end)

    assert Sidecars.files(src) == [{"#{dir}/Show.S01E1.en.srt", "en"}]
  end

  test "link/2 dedups reported languages but still hardlinks every distinct sidecar file" do
    dir = "/dl/Movie (2020)"
    src = "#{dir}/Movie (2020).mkv"
    dest = "/lib/Movie (2020)/Movie (2020).mkv"
    sub1_src = "#{dir}/Movie (2020).en.srt"
    sub1_dest = "/lib/Movie (2020)/Movie (2020).en.srt"
    sub2_src = "#{dir}/Movie (2020).en.forced.srt"
    sub2_dest = "/lib/Movie (2020)/Movie (2020).en.forced.srt"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok, [{src, 900}, {sub1_src, 10}, {sub2_src, 10}]}
    end)

    expect(FilesystemMock, :ln, fn ^sub1_src, ^sub1_dest -> :ok end)
    expect(FilesystemMock, :ln, fn ^sub2_src, ^sub2_dest -> :ok end)

    assert Sidecars.link(src, dest) == ["en"]
  end

  describe "real path-policy sinks" do
    setup do
      keys = [:filesystem, :path_policy, :import_roots, :movies_library_path, :tv_library_path]
      saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

      Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
      Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)

      on_exit(fn ->
        Application.delete_env(:cinder, :filesystem_barrier)

        Enum.each(saved, fn
          {key, nil} -> Application.delete_env(:cinder, key)
          {key, value} -> Application.put_env(:cinder, key, value)
        end)
      end)

      :ok
    end

    @tag :tmp_dir
    test "recursive sidecar discovery skips a directory symlink outside allowed roots", %{
      tmp_dir: tmp
    } do
      %{release: release} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      outside = Path.join(tmp, "outside")
      File.write!(video, "video")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "Movie.en.srt"), "secret")
      File.ln_s!(outside, Path.join(release, "escaped"))

      assert Sidecars.files(video) == []
    end

    @tag :tmp_dir
    test "sidecar hardlink rejects a source replaced by a symlink after traversal", %{
      tmp_dir: tmp
    } do
      %{release: release, movies: movies} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      sidecar = Path.join(release, "Movie.en.srt")
      database = Path.join(tmp, "cinder.db")
      dest = Path.join(movies, "Movie/Movie.mkv")
      sidecar_dest = Path.rootname(dest) <> ".en.srt"
      File.write!(video, "video")
      File.write!(sidecar, "subtitle")
      File.write!(database, "database")
      File.mkdir_p!(Path.dirname(dest))

      barrier(:find_files, release)
      task = Task.async(fn -> Sidecars.link(video, dest) end)
      {pid, ref, _path} = await_barrier(:find_files)
      File.rm!(sidecar)
      File.ln_s!(database, sidecar)
      send(pid, {ref, :continue})

      assert Task.await(task) == []
      refute File.exists?(sidecar_dest)
    end

    @tag :tmp_dir
    test "sidecar hardlink rejects a destination parent replaced after traversal", %{tmp_dir: tmp} do
      %{release: release, movies: movies} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      sidecar = Path.join(release, "Movie.en.srt")
      dest = Path.join(movies, "Movie/Movie.mkv")
      parent = Path.dirname(dest)
      outside = Path.join(tmp, "outside")
      File.write!(video, "video")
      File.write!(sidecar, "subtitle")
      File.mkdir_p!(parent)
      File.mkdir_p!(outside)

      barrier(:find_files, release)
      task = Task.async(fn -> Sidecars.link(video, dest) end)
      {pid, ref, _path} = await_barrier(:find_files)
      File.rename!(parent, parent <> ".old")
      File.ln_s!(outside, parent)
      send(pid, {ref, :continue})

      log = capture_log(fn -> assert Task.await(task) == [] end)

      assert log =~ "sidecar link rejected: :unsafe_destination"
      refute File.exists?(Path.join(outside, "Movie.en.srt"))
    end
  end

  defp configure_real_roots(tmp) do
    downloads = Path.join(tmp, "downloads")
    release = Path.join(downloads, "release")
    movies = Path.join(tmp, "movies")
    tv = Path.join(tmp, "tv")
    Enum.each([release, movies, tv], &File.mkdir_p!/1)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :movies_library_path, movies)
    Application.put_env(:cinder, :tv_library_path, tv)
    %{release: release, movies: movies}
  end

  defp barrier(operation, contains) do
    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: operation,
      contains: contains
    })
  end

  defp await_barrier(operation) do
    assert_receive {:filesystem_barrier, pid, ref, ^operation, path}, 1_000
    {pid, ref, path}
  end
end
