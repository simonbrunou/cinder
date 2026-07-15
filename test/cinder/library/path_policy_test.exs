defmodule Cinder.Library.PathPolicyTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Catalog.{Episode, Movie, Season, Series}
  alias Cinder.Library
  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Library.PathPolicy
  alias Cinder.Settings

  @tag :tmp_dir
  test "source_file accepts regular files and hardlinks inside an import root", %{tmp_dir: tmp} do
    root = Path.join(tmp, "downloads")
    nested = Path.join(root, "release/feature.mkv")
    hardlink = Path.join(root, "release/feature-copy.mkv")
    File.mkdir_p!(Path.dirname(nested))
    File.write!(nested, "video")
    File.ln!(nested, hardlink)

    assert {:ok, ^nested} = PathPolicy.source_file(nested, [root], [".mkv"])
    assert {:ok, ^hardlink} = PathPolicy.source_file(hardlink, [root], [".mkv"])
  end

  @tag :tmp_dir
  test "source_file rejects symlink leaves, symlinked parents, and sibling-prefix paths", %{
    tmp_dir: tmp
  } do
    root = Path.join(tmp, "downloads")
    sibling = Path.join(tmp, "downloads-old")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(sibling)
    File.mkdir_p!(outside)

    database = Path.join(outside, "cinder.db")
    leaf_link = Path.join(root, "database.mkv")
    escaped = Path.join(root, "escaped")
    escaped_file = Path.join(escaped, "secret.mkv")
    sibling_file = Path.join(sibling, "feature.mkv")
    File.write!(database, "database")
    File.write!(Path.join(outside, "secret.mkv"), "secret")
    File.write!(sibling_file, "video")
    File.ln_s!(database, leaf_link)
    File.ln_s!(outside, escaped)

    assert {:error, :unsafe_source} = PathPolicy.source_file(leaf_link, [root], [".mkv"])
    assert {:error, :unsafe_source} = PathPolicy.source_file(escaped_file, [root], [".mkv"])
    assert {:error, :unsafe_source} = PathPolicy.source_file(sibling_file, [root], [".mkv"])
  end

  @tag :tmp_dir
  test "walk skips outside and cyclic directory symlinks while collecting nested regular files",
       %{
         tmp_dir: tmp
       } do
    root = Path.join(tmp, "downloads")
    a = Path.join(root, "a")
    b = Path.join(root, "b")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(a)
    File.mkdir_p!(b)
    File.mkdir_p!(outside)

    first = Path.join(a, "first.mkv")
    second = Path.join(b, "second.mkv")
    File.write!(first, "one")
    File.write!(second, "two")
    File.write!(Path.join(outside, "secret.mkv"), "secret")
    File.ln_s!(b, Path.join(a, "to-b"))
    File.ln_s!(a, Path.join(b, "to-a"))
    File.ln_s!(outside, Path.join(root, "escaped"))

    assert {:ok, files} = PathPolicy.walk(root)
    assert Enum.sort(files) == Enum.sort([{first, 3}, {second, 3}])
  end

  @tag :tmp_dir
  test "walk enforces depth and entry limits", %{tmp_dir: tmp} do
    root = Path.join(tmp, "downloads")
    File.mkdir_p!(Path.join(root, "one/two"))
    File.write!(Path.join(root, "one/two/feature.mkv"), "video")

    assert {:error, :traversal_limit} = PathPolicy.walk(root, max_depth: 1)
    assert {:error, :traversal_limit} = PathPolicy.walk(root, max_entries: 1)
  end

  @tag :tmp_dir
  test "destination rejects sibling-prefix paths and symlinked existing parents", %{tmp_dir: tmp} do
    root = Path.join(tmp, "movies")
    outside = Path.join(tmp, "outside")
    sibling = Path.join(tmp, "movies-old")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.mkdir_p!(sibling)
    File.ln_s!(outside, Path.join(root, "escaped"))

    safe = Path.join(root, "Movie (2020)/Movie (2020).mkv")
    escaped = Path.join(root, "escaped/Movie.mkv")
    sibling_path = Path.join(sibling, "Movie.mkv")

    assert {:ok, ^safe} = PathPolicy.destination(safe, root)
    assert {:error, :unsafe_destination} = PathPolicy.destination(escaped, root)
    assert {:error, :unsafe_destination} = PathPolicy.destination(sibling_path, root)
  end

  @tag :tmp_dir
  test "deletable_file allows regular library files but rejects symlinks and outside paths", %{
    tmp_dir: tmp
  } do
    movie_root = Path.join(tmp, "movies")
    tv_root = Path.join(tmp, "tv")
    outside = Path.join(tmp, "cinder.db")
    movie = Path.join(movie_root, "Movie/Movie.mkv")
    link = Path.join(movie_root, "Movie/database.mkv")
    File.mkdir_p!(Path.dirname(movie))
    File.mkdir_p!(tv_root)
    File.write!(movie, "video")
    File.write!(outside, "database")
    File.ln_s!(outside, link)

    assert :ok = PathPolicy.deletable_file(movie, [movie_root, tv_root])
    assert {:error, :unsafe_delete} = PathPolicy.deletable_file(link, [movie_root, tv_root])
    assert {:error, :unsafe_delete} = PathPolicy.deletable_file(outside, [movie_root, tv_root])
  end

  @tag :tmp_dir
  test "deletable_source allows a regular file, a whole per-operation directory, or a missing path, but rejects symlinks and outside paths",
       %{tmp_dir: tmp} do
    downloads = Path.join(tmp, "downloads")
    outside = Path.join(tmp, "cinder.db")
    file = Path.join(downloads, "cinder-abc/movie.mkv")
    dir = Path.join(downloads, "cinder-def")
    missing = Path.join(downloads, "cinder-ghost")
    link = Path.join(downloads, "cinder-abc/database.mkv")
    File.mkdir_p!(Path.dirname(file))
    File.mkdir_p!(dir)
    File.write!(file, "video")
    File.write!(outside, "database")
    File.ln_s!(outside, link)

    assert :ok = PathPolicy.deletable_source(file, [downloads])
    assert :ok = PathPolicy.deletable_source(dir, [downloads])
    assert :ok = PathPolicy.deletable_source(missing, [downloads])
    assert {:error, :unsafe_delete} = PathPolicy.deletable_source(link, [downloads])
    assert {:error, :unsafe_delete} = PathPolicy.deletable_source(outside, [downloads])
  end

  @tag :tmp_dir
  test "deletable_source rejects the import root itself — a misreported content_path equal to the root must never rm_rf the whole downloads dir",
       %{tmp_dir: tmp} do
    downloads = Path.join(tmp, "downloads")
    File.mkdir_p!(downloads)

    assert {:error, :unsafe_delete} = PathPolicy.deletable_source(downloads, [downloads])
    # Trailing-slash / unnormalized spellings of the same root are still the root.
    assert {:error, :unsafe_delete} = PathPolicy.deletable_source(downloads <> "/", [downloads])
    assert {:error, :unsafe_delete} = PathPolicy.deletable_source(downloads, [downloads <> "/"])

    # Strictness only excludes the root itself, not its children.
    child = Path.join(downloads, "cinder-abc")
    File.mkdir_p!(child)
    assert :ok = PathPolicy.deletable_source(child, [downloads])
  end

  test "Library defaults to the real policy when no test override is configured" do
    saved = Application.get_env(:cinder, :path_policy)
    Application.delete_env(:cinder, :path_policy)
    on_exit(fn -> Application.put_env(:cinder, :path_policy, saved) end)

    assert Library.path_policy() == PathPolicy
  end

  describe "Library integration" do
    setup do
      saved =
        Map.new(
          [
            :filesystem,
            :path_policy,
            :movies_library_path,
            :tv_library_path,
            :import_roots,
            :explicit_import_roots
          ],
          fn key ->
            {key, Application.get_env(:cinder, key)}
          end
        )

      Application.put_env(:cinder, :filesystem, Disk)
      Application.put_env(:cinder, :path_policy, PathPolicy)
      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

      on_exit(fn ->
        Enum.each(saved, fn
          {key, nil} -> Application.delete_env(:cinder, key)
          {key, value} -> Application.put_env(:cinder, key, value)
        end)
      end)

      :ok
    end

    @tag :tmp_dir
    test "import_movie rejects a symlinked source before any library write", %{tmp_dir: tmp} do
      %{downloads: downloads, movies: movies} = configure_roots(tmp)
      database = Path.join(tmp, "cinder.db")
      source = Path.join(downloads, "database.mkv")
      File.write!(database, "database")
      File.ln_s!(database, source)

      movie = %Movie{title: "Movie", year: 2024, tmdb_id: 42, file_path: source}

      assert {:error, :unsafe_source} = Library.import_movie(movie)
      assert File.ls!(movies) == []
    end

    @tag :tmp_dir
    test "import_episodes imports nested regular files but skips a symlinked outside directory",
         %{
           tmp_dir: tmp
         } do
      %{downloads: downloads, tv: tv} = configure_roots(tmp)
      grab = Path.join(downloads, "Show.S01")
      nested = Path.join(grab, "nested")
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(nested)
      File.mkdir_p!(outside)
      File.write!(Path.join(nested, "Show.S01E01.mkv"), "episode one")
      File.write!(Path.join(outside, "Show.S01E02.mkv"), "episode two")
      File.ln_s!(outside, Path.join(grab, "escaped"))

      assert {:ok, [{1, dest, _quality}], []} =
               Library.import_episodes(grab, [episode(1, 1), episode(2, 2)])

      assert String.starts_with?(dest, tv <> "/")
      assert File.read!(dest) == "episode one"
      refute File.exists?(Path.join(Path.dirname(dest), "Show (2024) - S01E02.mkv"))
    end

    @tag :tmp_dir
    test "import_movie rejects a symlinked destination parent", %{tmp_dir: tmp} do
      %{downloads: downloads, movies: movies} = configure_roots(tmp)
      source = Path.join(downloads, "Movie.2024.mkv")
      outside = Path.join(tmp, "outside")
      dest_parent = Path.join(movies, "Movie (2024) {tmdb-42}")
      File.write!(source, "video")
      File.mkdir_p!(outside)
      File.ln_s!(outside, dest_parent)

      movie = %Movie{title: "Movie", year: 2024, tmdb_id: 42, file_path: source}

      assert {:error, :unsafe_destination} = Library.import_movie(movie)
      assert File.ls!(outside) == []
    end

    @tag :tmp_dir
    test "delete_file rejects outside files and deletes regular in-root files", %{tmp_dir: tmp} do
      %{movies: movies} = configure_roots(tmp)
      outside = Path.join(tmp, "outside.mkv")
      inside = Path.join(movies, "Movie/Movie.mkv")
      File.write!(outside, "outside")
      File.mkdir_p!(Path.dirname(inside))
      File.write!(inside, "inside")

      assert {:error, :unsafe_delete} = Library.delete_file(outside)
      assert File.exists?(outside)
      assert :ok = Library.delete_file(inside)
      refute File.exists?(inside)
    end

    @tag :tmp_dir
    test "regular movie imports remain idempotent when the destination is already a hardlink", %{
      tmp_dir: tmp
    } do
      %{downloads: downloads} = configure_roots(tmp)
      source = Path.join(downloads, "Movie.2024.mkv")
      File.write!(source, "video")
      movie = %Movie{title: "Movie", year: 2024, tmdb_id: 42, file_path: source}

      assert {:ok, dest, _quality} = Library.import_movie(movie)
      assert {:ok, ^dest, _quality} = Library.import_movie(movie)
      assert File.stat!(source).inode == File.stat!(dest).inode
    end

    @tag :tmp_dir
    test "EXDEV still falls back to an atomic byte copy inside the validated destination", %{
      tmp_dir: tmp
    } do
      Application.put_env(:cinder, :filesystem, Cinder.Test.ExdevFilesystem)
      %{downloads: downloads} = configure_roots(tmp)
      source = Path.join(downloads, "Movie.2024.mkv")
      File.write!(source, "video")
      movie = %Movie{title: "Movie", year: 2024, tmdb_id: 42, file_path: source}

      assert {:ok, dest, _quality} = Library.import_movie(movie)
      assert File.read!(dest) == "video"
      assert File.stat!(source).inode != File.stat!(dest).inode
    end

    @tag :tmp_dir
    test "imports hold when no safe download root is configured", %{tmp_dir: tmp} do
      %{downloads: downloads} = configure_roots(tmp)
      source = Path.join(downloads, "Movie.2024.mkv")
      File.write!(source, "video")
      Application.put_env(:cinder, :import_roots, [])

      movie = %Movie{title: "Movie", year: 2024, tmdb_id: 42, file_path: source}
      assert {:error, :download_roots_not_configured} = Library.import_movie(movie)
    end

    @tag :tmp_dir
    test "empty-parent pruning rejects an ancestor replaced after the file unlink", %{
      tmp_dir: tmp
    } do
      %{tv: tv} = configure_roots(tmp)
      show = Path.join(tv, "Show")
      season = Path.join(show, "Season 01")
      file = Path.join(season, "Show - S01E01.mkv")
      outside_show = Path.join(tmp, "outside-show")
      outside_season = Path.join(outside_show, "Season 01")
      File.mkdir_p!(season)
      File.mkdir_p!(outside_season)
      File.write!(file, "episode")
      Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :rm,
        contains: Path.basename(file)
      })

      task = Task.async(fn -> Library.delete_file(file) end)
      assert_receive {:filesystem_barrier, pid, ref, :rm, ^file}, 1_000
      File.rename!(show, show <> ".old")
      File.ln_s!(outside_show, show)
      send(pid, {ref, :continue})

      assert Task.await(task) == :ok
      assert File.dir?(outside_season)
    end
  end

  defp configure_roots(tmp) do
    downloads = Path.join(tmp, "downloads")
    movies = Path.join(tmp, "movies")
    tv = Path.join(tmp, "tv")
    Enum.each([downloads, movies, tv], &File.mkdir_p!/1)
    Settings.put("import_roots", downloads)
    Application.put_env(:cinder, :movies_library_path, movies)
    Application.put_env(:cinder, :tv_library_path, tv)
    %{downloads: downloads, movies: movies, tv: tv}
  end

  defp episode(id, number) do
    series = %Series{title: "Show", year: 2024, tmdb_id: 7}
    season = %Season{season_number: 1, series: series}
    %Episode{id: id, episode_number: number, season: season}
  end
end
