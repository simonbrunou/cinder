defmodule Cinder.Download.OrphanFoldersTest do
  # async: false — flips process-global Application env (filesystem, import roots).
  use Cinder.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Cinder.Books
  alias Cinder.Books.BookGrab
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, Movie}
  alias Cinder.Download.{ClientMock, Intent, OrphanFolders, SabnzbdClientMock}
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  @moduletag :tmp_dir
  @moduletag :capture_log

  # A moviehash needs 128 KiB; same size + different seed = a different hash.
  @video_size 200_000

  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    downloads = Path.join(tmp, "downloads")
    library = Path.join(tmp, "library")
    File.mkdir_p!(downloads)
    File.mkdir_p!(library)

    keys = [:filesystem, :path_policy, :import_roots, :explicit_import_roots]
    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :explicit_import_roots, [downloads])

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    stub(ClientMock, :health, fn -> :ok end)
    stub(SabnzbdClientMock, :health, fn -> :ok end)
    stub(ClientMock, :list_managed, fn -> {:ok, []} end)
    stub(SabnzbdClientMock, :list_managed, fn -> {:ok, []} end)

    %{downloads: downloads, library: library}
  end

  describe "scan/0 classification" do
    test "reports empty, library_copy and unmatched folders with their sizes", ctx do
      empty = job_folder(ctx.downloads)
      copy = job_folder(ctx.downloads)
      other = job_folder(ctx.downloads)

      write_aged(Path.join(copy.path, "Show.S01E01.mkv"), video(1))
      library_movie(ctx.library, "Movie (2000)", video(1))

      write_aged(Path.join(other.path, "Other.mkv"), video(2))

      assert {:ok, %{folders: folders, referenced: 0}} = OrphanFolders.scan()

      assert %{class: :empty, size: 0} = by_key(folders, empty.key)
      assert %{class: :library_copy, size: @video_size} = by_key(folders, copy.key)
      assert %{class: :unmatched, size: @video_size} = by_key(folders, other.key)
    end

    test "sorts the safe classes before unmatched, biggest first", ctx do
      unmatched = job_folder(ctx.downloads, "A")
      empty = job_folder(ctx.downloads, "Z")
      write_aged(Path.join(unmatched.path, "a.mkv"), video(2))

      assert {:ok, %{folders: [first, second]}} = OrphanFolders.scan()
      assert {first.key, second.key} == {empty.key, unmatched.key}
    end

    test "a folder with only non-video files is unmatched, not empty", ctx do
      folder = job_folder(ctx.downloads)
      write_aged(Path.join(folder.path, "readme.nfo"), "notes")

      assert {:ok, %{folders: [%{class: :unmatched, size: 5}]}} = OrphanFolders.scan()
    end

    test "extras beside a library-identical video do not stop it being a library_copy", ctx do
      folder = job_folder(ctx.downloads)
      write_aged(Path.join(folder.path, "Movie.mkv"), video(1))
      write_aged(Path.join(folder.path, "Movie.nfo"), "info")
      library_movie(ctx.library, "Movie (2000)", video(1))

      assert {:ok, %{folders: [%{class: :library_copy}]}} = OrphanFolders.scan()
    end

    test "every video must match: one that matches no library file makes it unmatched", ctx do
      folder = job_folder(ctx.downloads)
      write_aged(Path.join(folder.path, "A.mkv"), video(1))
      write_aged(Path.join(folder.path, "B.mkv"), video(2))
      library_movie(ctx.library, "A (2000)", video(1))

      assert {:ok, %{folders: [%{class: :unmatched}]}} = OrphanFolders.scan()
    end

    test "same size but a different moviehash is not a match", ctx do
      folder = job_folder(ctx.downloads)
      write_aged(Path.join(folder.path, "A.mkv"), video(1))
      library_movie(ctx.library, "A (2000)", video(2))

      assert {:ok, %{folders: [%{class: :unmatched}]}} = OrphanFolders.scan()
    end

    test "a video too small to hash is never a match", ctx do
      folder = job_folder(ctx.downloads)
      write_aged(Path.join(folder.path, "sample.mkv"), "tiny")
      library_movie(ctx.library, "Tiny (2000)", "tiny")

      assert {:ok, %{folders: [%{class: :unmatched}]}} = OrphanFolders.scan()
    end

    test "matches a library episode file and a multi-part movie file", ctx do
      series = series_fixture()
      season = season_fixture(series)
      episode = episode_fixture(season)
      episode_file = library_file(ctx.library, "Show/S01E01.mkv", video(3))

      Repo.update_all(from(e in Episode, where: e.id == ^episode.id),
        set: [part_file_paths: [episode_file]]
      )

      movie = movie_fixture()
      part_file = library_file(ctx.library, "Movie/cd1.mkv", video(4))

      Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
        set: [file_path: part_file, part_file_paths: [part_file]]
      )

      season_pack = job_folder(ctx.downloads, "Pack")
      write_aged(Path.join(season_pack.path, "S01E01.mkv"), video(3))
      movie_copy = job_folder(ctx.downloads, "Film")
      write_aged(Path.join(movie_copy.path, "Film.mkv"), video(4))

      assert {:ok, %{folders: folders}} = OrphanFolders.scan()
      assert %{class: :library_copy} = by_key(folders, season_pack.key)
      assert %{class: :library_copy} = by_key(folders, movie_copy.key)
    end

    test "classifies nested files and ignores names that are not Cinder job folders", ctx do
      folder = job_folder(ctx.downloads)
      nested = Path.join(folder.path, "Season 1")
      write_aged(Path.join(nested, "e.mkv"), video(5))
      age(nested)

      File.mkdir_p!(Path.join(ctx.downloads, "Show"))
      File.mkdir_p!(Path.join(ctx.downloads, "Show.cinder-123"))
      File.mkdir_p!(Path.join([ctx.downloads, "tv-sonarr", "Show.cinder-#{key()}"]))
      File.write!(Path.join(ctx.downloads, "Show.cinder-#{key()}"), "a file, not a folder")

      assert {:ok, %{folders: [%{key: key, class: :unmatched}], referenced: 0}} =
               OrphanFolders.scan()

      assert key == folder.key
    end
  end

  describe "scan/0 holds" do
    test "a file modified within the last hour holds the folder", ctx do
      folder = job_folder(ctx.downloads)
      File.write!(Path.join(folder.path, "fresh.mkv"), video(1))

      assert {:ok, %{folders: [%{hold: :recent, class: nil}]}} = OrphanFolders.scan()
    end

    test "a future-dated file holds the folder too", ctx do
      folder = job_folder(ctx.downloads)
      file = Path.join(folder.path, "future.mkv")
      File.write!(file, video(1))
      File.touch!(file, {{2097, 12, 31}, {0, 0, 0}})

      assert {:ok, %{folders: [%{hold: :recent}]}} = OrphanFolders.scan()
    end

    test "a symlink anywhere inside holds the folder", ctx do
      folder = job_folder(ctx.downloads)
      outside = Path.join(Path.dirname(ctx.downloads), "outside.mkv")
      File.write!(outside, video(1))
      File.ln_s!(outside, Path.join(folder.path, "link.mkv"))

      assert {:ok, %{folders: [%{hold: :symlink, class: nil}]}} = OrphanFolders.scan()
    end

    test "a symlinked job folder is not listed at all", ctx do
      target = Path.join(Path.dirname(ctx.downloads), "elsewhere")
      File.mkdir_p!(target)
      File.ln_s!(target, Path.join(ctx.downloads, "Show.cinder-#{key()}"))

      assert {:ok, %{folders: [], referenced: 0}} = OrphanFolders.scan()
    end
  end

  describe "scan/0 references" do
    test "a download client listing the key keeps the folder (each protocol)", ctx do
      usenet = job_folder(ctx.downloads, "Usenet")
      torrent = job_folder(ctx.downloads, "Torrent")
      free = job_folder(ctx.downloads, "Free")

      expect(SabnzbdClientMock, :list_managed, fn ->
        {:ok, [%{id: "nzo-1", operation_key: usenet.key, state: :completed}]}
      end)

      expect(ClientMock, :list_managed, fn ->
        {:ok, [%{id: "hash", operation_key: String.upcase(torrent.key), state: :completed}]}
      end)

      assert {:ok, %{folders: [only], referenced: 2}} = OrphanFolders.scan()
      assert only.key == free.key
    end

    test "a download_intents row with the key keeps the folder", ctx do
      folder = job_folder(ctx.downloads)

      Repo.insert!(%Intent{
        operation_key: folder.key,
        kind: :movie,
        target_id: 1,
        protocol: :usenet,
        release: %{"title" => "R"},
        status: :submitted
      })

      assert {:ok, %{folders: [], referenced: 1}} = OrphanFolders.scan()
    end

    test "a grab content_path inside the folder keeps it", ctx do
      folder = job_folder(ctx.downloads)

      Repo.insert!(%Grab{
        download_id: "nzo-1",
        download_protocol: :usenet,
        content_path: Path.join(folder.path, "Show.S01E01.mkv")
      })

      assert {:ok, %{folders: [], referenced: 1}} = OrphanFolders.scan()
    end

    test "a movie content_path inside the folder keeps it", ctx do
      folder = job_folder(ctx.downloads)
      movie = movie_fixture()

      Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
        set: [content_path: folder.path]
      )

      assert {:ok, %{folders: [], referenced: 1}} = OrphanFolders.scan()
    end

    test "a book grab content_path inside the folder keeps it", ctx do
      folder = job_folder(ctx.downloads)
      target = book_target()

      Repo.insert!(%BookGrab{
        book_target_id: target.id,
        download_id: "nzb-1",
        download_protocol: :usenet,
        content_path: Path.join(folder.path, "book.epub")
      })

      assert {:ok, %{folders: [], referenced: 1}} = OrphanFolders.scan()
    end

    test "a library file path inside the folder keeps it", ctx do
      folder = job_folder(ctx.downloads)
      movie = movie_fixture()

      Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
        set: [file_path: Path.join(folder.path, "Movie.mkv")]
      )

      assert {:ok, %{folders: [], referenced: 1}} = OrphanFolders.scan()
    end

    test "a failing client listing fails closed: no listing, an error naming the protocol", ctx do
      job_folder(ctx.downloads)
      expect(SabnzbdClientMock, :list_managed, fn -> {:error, :econnrefused} end)

      assert {:error, {:client_list_failed, :usenet, :econnrefused}} = OrphanFolders.scan()
    end

    test "a client that raises while listing fails closed too", ctx do
      job_folder(ctx.downloads)
      expect(ClientMock, :list_managed, fn -> raise "client down" end)

      assert {:error, {:client_list_failed, :torrent, {:raised, "client down"}}} =
               OrphanFolders.scan()
    end
  end

  describe "scan/0 without usable import roots" do
    test "unset or empty explicit roots refuse to scan", ctx do
      job_folder(ctx.downloads)

      Application.delete_env(:cinder, :explicit_import_roots)
      assert {:error, :import_roots_not_explicit} = OrphanFolders.scan()

      Application.put_env(:cinder, :explicit_import_roots, [])
      assert {:error, :import_roots_not_explicit} = OrphanFolders.scan()
    end

    test "an unreadable root is reported, not skipped", ctx do
      Application.put_env(:cinder, :explicit_import_roots, [Path.join(ctx.downloads, "missing")])

      assert {:error, {:root_unreadable, _root, :enoent}} = OrphanFolders.scan()
    end
  end

  describe "clear/2" do
    test "removes empty and library_copy folders and leaves everything else", ctx do
      empty = job_folder(ctx.downloads, "E")
      copy = job_folder(ctx.downloads, "C")
      unmatched = job_folder(ctx.downloads, "U")
      write_aged(Path.join(copy.path, "m.mkv"), video(1))
      write_aged(Path.join(unmatched.path, "u.mkv"), video(2))
      library_movie(ctx.library, "Movie (2000)", video(1))

      assert {:ok, %{cleared: cleared, skipped: skipped}} =
               OrphanFolders.clear(
                 [empty.path, copy.path, unmatched.path],
                 OrphanFolders.safe_classes(),
                 nil
               )

      assert Enum.sort(cleared) == Enum.sort([empty.path, copy.path])
      assert skipped == [{unmatched.path, {:class, :unmatched}}]
      refute File.exists?(empty.path)
      refute File.exists?(copy.path)
      assert File.exists?(Path.join(unmatched.path, "u.mkv"))
      assert File.exists?(Path.join(ctx.library, "Movie (2000)/Movie (2000).mkv"))
      assert File.dir?(ctx.downloads)
    end

    test "an unmatched folder is removed only when :unmatched is allowed", ctx do
      folder = job_folder(ctx.downloads)
      write_aged(Path.join(folder.path, "u.mkv"), video(2))

      assert {:ok, %{cleared: [], skipped: [{_, {:class, :unmatched}}]}} =
               OrphanFolders.clear([folder.path], OrphanFolders.safe_classes(), nil)

      assert File.exists?(folder.path)

      assert {:ok, %{cleared: [cleared], skipped: []}} =
               OrphanFolders.clear([folder.path], [:unmatched], nil)

      assert cleared == folder.path
      refute File.exists?(folder.path)
    end

    test "re-checks references at delete time: a folder claimed after the scan is kept", ctx do
      folder = job_folder(ctx.downloads)
      assert {:ok, %{folders: [%{class: :empty}]}} = OrphanFolders.scan()

      Repo.insert!(%Intent{
        operation_key: folder.key,
        kind: :movie,
        target_id: 1,
        protocol: :usenet,
        release: %{"title" => "R"},
        status: :reserved
      })

      assert {:ok, %{cleared: [], skipped: [{_, :referenced}]}} =
               OrphanFolders.clear([folder.path], OrphanFolders.safe_classes(), nil)

      assert File.dir?(folder.path)
    end

    test "re-checks the client at call time: a job listed since the scan keeps the folder", ctx do
      folder = job_folder(ctx.downloads)

      expect(SabnzbdClientMock, :list_managed, fn ->
        {:ok, [%{id: "nzo-1", operation_key: folder.key, state: :downloading}]}
      end)

      assert {:ok, %{cleared: [], skipped: [{_, :referenced}]}} =
               OrphanFolders.clear([folder.path], OrphanFolders.safe_classes(), nil)

      assert File.dir?(folder.path)
    end

    test "re-checks the class at delete time: a folder that gained a video is kept", ctx do
      folder = job_folder(ctx.downloads)
      assert {:ok, %{folders: [%{class: :empty}]}} = OrphanFolders.scan()

      write_aged(Path.join(folder.path, "late.mkv"), video(2))

      assert {:ok, %{cleared: [], skipped: [{_, {:class, :unmatched}}]}} =
               OrphanFolders.clear([folder.path], OrphanFolders.safe_classes(), nil)

      assert File.exists?(Path.join(folder.path, "late.mkv"))
    end

    test "re-checks recency at delete time: a file written since the scan holds the folder",
         ctx do
      folder = job_folder(ctx.downloads)
      assert {:ok, %{folders: [%{class: :empty}]}} = OrphanFolders.scan()

      File.write!(Path.join(folder.path, "writing.mkv"), "partial")

      assert {:ok, %{cleared: [], skipped: [{_, {:held, :recent}}]}} =
               OrphanFolders.clear([folder.path], OrphanFolders.safe_classes(), nil)

      assert File.exists?(Path.join(folder.path, "writing.mkv"))
    end

    test "a failing client listing deletes nothing", ctx do
      folder = job_folder(ctx.downloads)
      expect(SabnzbdClientMock, :list_managed, fn -> {:error, :timeout} end)

      assert {:error, {:client_list_failed, :usenet, :timeout}} =
               OrphanFolders.clear([folder.path], OrphanFolders.safe_classes(), nil)

      assert File.dir?(folder.path)
    end

    test "a client failing its health check fails closed even if it lists nothing", ctx do
      folder = job_folder(ctx.downloads)
      stub(SabnzbdClientMock, :health, fn -> {:error, :bad_api_key} end)
      test_pid = self()

      stub(SabnzbdClientMock, :list_managed, fn ->
        send(test_pid, :listed)
        {:ok, []}
      end)

      assert {:error, {:client_list_failed, :usenet, {:unhealthy, :bad_api_key}}} =
               OrphanFolders.scan()

      assert {:error, {:client_list_failed, :usenet, {:unhealthy, :bad_api_key}}} =
               OrphanFolders.clear([folder.path], OrphanFolders.safe_classes(), nil)

      assert File.dir?(folder.path)
      refute_received :listed
    end

    test "a health warning does not block the listing", ctx do
      job_folder(ctx.downloads)
      stub(SabnzbdClientMock, :health, fn -> {:warning, :slow} end)

      assert {:ok, %{folders: [_]}} = OrphanFolders.scan()
    end

    test "writes one audit row per cleared folder with the actor, none for skipped ones", ctx do
      admin = Cinder.AccountsFixtures.admin_fixture()
      empty = job_folder(ctx.downloads, "E")
      unmatched = job_folder(ctx.downloads, "U")
      write_aged(Path.join(unmatched.path, "u.mkv"), video(2))

      assert {:ok, %{cleared: [cleared], skipped: [{_, {:class, :unmatched}}]}} =
               OrphanFolders.clear(
                 [empty.path, unmatched.path],
                 OrphanFolders.safe_classes(),
                 admin
               )

      assert cleared == empty.path

      assert [row] =
               Repo.all(
                 from a in Cinder.Audit.AdminAudit, where: a.entity_type == "DownloadFolder"
               )

      assert row.action == "clear_download_folder"
      assert row.actor_id == admin.id
      assert row.entity_id == nil

      assert row.detail == %{
               "path" => empty.path,
               "key" => empty.key,
               "class" => "empty",
               "size" => 0
             }
    end

    test "a failed delete is logged and leaves no audit row", ctx do
      folder = job_folder(ctx.downloads)
      # A permission bit cannot make the delete fail when the suite runs as root (CI does), so
      # fail it at the filesystem behaviour; everything else stays the real disk.
      Application.put_env(:cinder, :filesystem, Cinder.Library.FilesystemMock)
      stub_with(Cinder.Library.FilesystemMock, Cinder.Library.Filesystem.Disk)
      stub(Cinder.Library.FilesystemMock, :rm_rf, fn path -> {:error, :eacces, path} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{cleared: [], skipped: [{_, {:delete_failed, _}}]}} =
                   OrphanFolders.clear([folder.path], OrphanFolders.safe_classes(), nil)
        end)

      assert log =~ "orphan download folder not deleted: #{folder.path}"

      assert Repo.all(from a in Cinder.Audit.AdminAudit, where: a.entity_type == "DownloadFolder") ==
               []
    end

    test "refuses anything that is not a direct Cinder job folder of an explicit root", ctx do
      outside_root = Path.join(Path.dirname(ctx.downloads), "elsewhere")
      outside = Path.join(outside_root, "Show.cinder-#{key()}")
      File.mkdir_p!(outside)

      nested = Path.join([ctx.downloads, "tv", "Show.cinder-#{key()}"])
      File.mkdir_p!(nested)

      plain = Path.join(ctx.downloads, "Plain")
      File.mkdir_p!(plain)

      symlinked = Path.join(ctx.downloads, "Link.cinder-#{key()}")
      File.ln_s!(outside, symlinked)

      paths = [outside, nested, plain, symlinked, ctx.downloads, "relative", nil]

      assert {:ok, %{cleared: [], skipped: skipped}} =
               OrphanFolders.clear(paths, [:empty, :library_copy, :unmatched], nil)

      assert Enum.all?(skipped, fn {_path, reason} -> reason == :not_a_job_folder end)
      assert length(skipped) == length(paths)
      assert Enum.all?([outside, nested, plain, symlinked, ctx.downloads], &File.exists?/1)
    end

    test "a folder that is already gone is reported, not an error", ctx do
      folder = job_folder(ctx.downloads)
      File.rm_rf!(folder.path)

      assert {:ok, %{cleared: [], skipped: [{_, :gone}]}} =
               OrphanFolders.clear([folder.path], OrphanFolders.safe_classes(), nil)
    end

    test "refuses with only an inferred import root", ctx do
      folder = job_folder(ctx.downloads)
      Application.delete_env(:cinder, :explicit_import_roots)

      assert {:error, :import_roots_not_explicit} =
               OrphanFolders.clear([folder.path], OrphanFolders.safe_classes(), nil)

      assert File.dir?(folder.path)
    end
  end

  # --- fixtures ---------------------------------------------------------------------------

  defp key, do: Ecto.UUID.generate()

  # An empty `<title>.cinder-<key>` folder under `downloads`.
  defp job_folder(downloads, title \\ "Show") do
    key = key()
    path = Path.join(downloads, "#{title}.cinder-#{key}")
    File.mkdir_p!(path)
    %{key: key, path: path}
  end

  defp by_key(folders, key), do: Enum.find(folders, &(&1.key == key))

  defp video(seed), do: :binary.copy(<<seed>>, @video_size)

  defp write_aged(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    age(path)
  end

  defp age(path), do: File.touch!(path, {{2020, 1, 1}, {0, 0, 0}})

  defp library_file(library, relative, contents) do
    path = Path.join(library, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  # A movie whose library file is `contents`.
  defp library_movie(library, name, contents) do
    path = library_file(library, "#{name}/#{name}.mkv", contents)
    movie = movie_fixture()

    Repo.update_all(from(m in Movie, where: m.id == ^movie.id), set: [file_path: path])
    movie
  end

  defp book_target do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, profile} =
      Catalog.create_profile(%{
        name: "Ebooks #{id}",
        kind: :ebook,
        handling: :standard,
        library_path: "/tmp/cinder-books-#{id}"
      })

    {:ok, work} =
      Books.upsert_work(%{
        title: "Book #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, target} = Books.monitor_target(work, :ebook, profile)
    target
  end
end
