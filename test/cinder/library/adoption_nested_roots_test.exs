defmodule Cinder.Library.AdoptionNestedRootsTest do
  # #1185: a library root's adoption walk skips every configured destination strictly inside it,
  # of any kind, so a nested destination's files are listed by its own walk alone, and a wedged
  # nested destination leaves one stuck walk, not two.
  use Cinder.DataCase, async: false

  import Cinder.BoundedWalkHelpers
  import Cinder.ConfigCase
  import Mox

  alias Cinder.Catalog
  alias Cinder.Library.{Adoption, BoundedWalk}
  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Test.WedgedFilesystem

  setup :verify_on_exit!

  @movie_dir "Dune (2021) {tmdb-438631}"

  # One scan walks the wedged nested root, meant to time out, and the healthy movies root, meant
  # to finish, so only the wedged root gets the shrunk deadline (docs/agents/testing.md). The
  # movies root's 10 s is a deadline a loaded runner cannot miss, and it ends the scan in seconds
  # should that walk read into the wedged root.
  for {nested_key, nested_kind} <- [movies_anime_library_path: :movie, tv_library_path: :series] do
    @tag :tmp_dir
    @tag :capture_log
    @tag timeout: 30_000
    @tag nested_key: nested_key
    @tag nested_kind: nested_kind
    test "a wedged #{nested_key} inside the movies root leaves one stuck walk, and the movies " <>
           "root still lists its own movie on this scan and the next",
         %{tmp_dir: tmp, nested_key: nested_key, nested_kind: nested_kind} do
      movies = Path.join(tmp, "movies")
      wedged = Path.join(movies, "wedged")
      movie_dir = Path.join(movies, @movie_dir)
      movie = Path.join(movie_dir, "#{@movie_dir}.mkv")
      Enum.each([wedged, movie_dir], &File.mkdir_p!/1)
      File.write!(movie, "video")

      [
        filesystem: WedgedFilesystem,
        movies_library_path: movies,
        movies_anime_library_path: nil,
        tv_library_path: nil,
        tv_anime_library_path: nil,
        wedged_filesystem_test: self(),
        adoption_scan_timeout_ms: %{wedged => 300, movies => 10_000}
      ]
      |> Keyword.put(nested_key, wedged)
      |> put_env()

      candidates = Adoption.scan()
      assert_receive {:walking, walk}
      release_walk_on_exit(walk)
      refute_received {:walking, _second_walk}

      assert [
               %{
                 kind: :movie,
                 directory: ^movie_dir,
                 paths: [^movie],
                 status: :auto_matched,
                 media_profile: :auto,
                 library_root: ^movies
               },
               %{kind: ^nested_kind, directory: ^wedged, reason: {:scan_failed, :timeout}}
             ] = candidates

      assert Map.values(:sys.get_state(BoundedWalk).stuck) == [wedged]

      other = Path.join(tmp, "other")
      assert BoundedWalk.run(other, fn -> :walked end, timeout_ms: 10_000) == :walked

      # Every root now gets a deadline a loaded runner cannot miss, so a scan that came back well
      # under it refused the wedged root at once.
      put_env(:adoption_scan_timeout_ms, 10_000)
      {elapsed, candidates} = :timer.tc(&Adoption.scan/0, :millisecond)
      assert elapsed < 5_000
      refute_received {:walking, _refused_walk}

      assert [
               %{kind: :movie, directory: ^movie_dir, paths: [^movie], status: :auto_matched},
               %{kind: ^nested_kind, directory: ^wedged, reason: {:scan_failed, :timeout}}
             ] = candidates

      assert Map.values(:sys.get_state(BoundedWalk).stuck) == [wedged]
    end
  end

  @tag :tmp_dir
  test "a healthy TV root inside the movies root lists each episode once, as a series",
       %{tmp_dir: tmp} do
    media = Path.join(tmp, "media")
    tv = Path.join(media, "tv")
    show = Path.join(tv, "Test Show (2001)")
    episodes = Enum.map(["Test.Show.S01E01.mkv", "Test.Show.S01E02.mkv"], &Path.join(show, &1))
    movie_dir = Path.join(media, @movie_dir)
    movie = Path.join(movie_dir, "#{@movie_dir}.mkv")
    Enum.each([show, movie_dir], &File.mkdir_p!/1)
    Enum.each([movie | episodes], &File.write!(&1, "video"))

    put_env(
      filesystem: WedgedFilesystem,
      movies_library_path: media,
      movies_anime_library_path: nil,
      tv_library_path: tv,
      tv_anime_library_path: nil
    )

    # Answers a search for a movie read from the TV root, so a regression fails on the candidates.
    stub(Cinder.Catalog.TMDBMock, :search, fn _title, "en" -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn "Test Show", "en" -> {:ok, []} end)

    assert [
             %{kind: :movie, directory: ^movie_dir, paths: [^movie]},
             %{kind: :series, directory: ^show, paths: ^episodes, library_root: ^tv} = series
           ] = Adoption.scan()

    assert series.files |> Enum.map(& &1.path) |> Enum.sort() == episodes
  end

  @tag :tmp_dir
  test "the movies root still walks a sibling whose name only extends a nested root's name",
       %{tmp_dir: tmp} do
    movies = Path.join(tmp, "movies")
    anime = Path.join(movies, "anime")
    anime_dir = Path.join(anime, "Akira (1988) {tmdb-149}")
    anime_movie = Path.join(anime_dir, "Akira (1988) {tmdb-149}.mkv")
    sibling = Path.join(movies, "anime2")
    sibling_movie = Path.join(sibling, "Dune (2021).mkv")
    Enum.each([anime_dir, sibling], &File.mkdir_p!/1)
    Enum.each([anime_movie, sibling_movie], &File.write!(&1, "video"))

    put_env(
      filesystem: WedgedFilesystem,
      movies_library_path: movies,
      movies_anime_library_path: anime,
      tv_library_path: nil,
      tv_anime_library_path: nil
    )

    stub(Cinder.Catalog.TMDBMock, :search, fn _title, "en" -> {:ok, []} end)

    assert [
             %{
               kind: :movie,
               directory: ^anime_dir,
               paths: [^anime_movie],
               media_profile: :anime,
               library_root: ^anime
             },
             %{
               kind: :movie,
               directory: ^sibling,
               paths: [^sibling_movie],
               media_profile: :auto,
               library_root: ^movies
             }
           ] = Adoption.scan()

    # The disk walk skips the nested root only when asked to: `find_files/1`, the walk
    # `Sidecars.files/1` runs, still reads into it.
    assert {:ok, [{^sibling_movie, 5}]} = Disk.find_files(movies, skip: [anime])
    assert {:ok, files} = Disk.find_files(movies)
    assert Enum.sort(files) == Enum.sort([{anime_movie, 5}, {sibling_movie, 5}])
  end

  test "the movies root skips every profile's library path inside it, books included, and a " <>
         "movies profile's path is walked on its own, with that profile" do
    nested = "/tmp/cinder-test-library/family"
    path = "#{nested}/Paddington (2014) {tmdb-30}/Paddington (2014) {tmdb-30}.mkv"
    books = Enum.map([:ebook, :audiobook], &"/tmp/cinder-test-library/#{&1}")

    assert {:ok, profile} =
             Catalog.create_profile(%{
               name: "Family",
               kind: :movies,
               handling: :standard,
               library_path: nested
             })

    for {kind, library_path} <- Enum.zip([:ebook, :audiobook], books) do
      assert {:ok, _profile} =
               Catalog.create_profile(%{
                 name: "Nested #{kind}",
                 kind: kind,
                 handling: :standard,
                 library_path: library_path
               })
    end

    expect(Cinder.Library.FilesystemMock, :find_files, 2, fn
      ^nested -> {:ok, [{path, 10}]}
      "/tmp/cinder-test-tv-library" -> {:ok, []}
    end)

    test = self()

    expect(Cinder.Library.FilesystemMock, :find_files, fn "/tmp/cinder-test-library", opts ->
      send(test, {:skip, Keyword.fetch!(opts, :skip)})
      {:ok, []}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn ^path ->
      {:ok, %File.Stat{type: :regular, size: 10, major_device: 1, inode: 1}}
    end)

    assert [%{kind: :movie, paths: [^path], library_root: ^nested, profile_id: profile_id}] =
             Adoption.scan()

    assert profile_id == profile.id
    assert_received {:skip, skip}
    assert Enum.sort(skip) == Enum.sort([nested | books])
  end

  test "a root and a nested destination configured with a trailing slash still nest" do
    put_env(
      movies_library_path: "/tmp/cinder-test-library/",
      movies_anime_library_path: "/tmp/cinder-test-library/anime/",
      tv_library_path: nil,
      tv_anime_library_path: nil
    )

    expect(Cinder.Library.FilesystemMock, :find_files, fn "/tmp/cinder-test-library/anime/" ->
      {:ok, []}
    end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn
      "/tmp/cinder-test-library/", [skip: ["/tmp/cinder-test-library/anime"]] -> {:ok, []}
    end)

    assert Adoption.scan() == []
  end

  test "a destination at the root's own path, or one whose path only extends the root's name, " <>
         "is walked with no skip" do
    root = "/tmp/cinder-shared-library"
    beside = "/tmp/cinder-shared-library2"

    assert {:ok, _profile} =
             Catalog.create_profile(%{
               name: "Beside",
               kind: :movies,
               handling: :standard,
               library_path: beside
             })

    put_env(
      movies_library_path: root,
      movies_anime_library_path: nil,
      tv_library_path: root,
      tv_anime_library_path: nil
    )

    # A walk with a skip list calls `find_files/2`, which has no expectation here.
    expect(Cinder.Library.FilesystemMock, :find_files, 3, fn
      ^root -> {:ok, []}
      ^beside -> {:ok, []}
    end)

    assert Adoption.scan() == []
  end
end
