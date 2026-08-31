defmodule Cinder.Download.BookPollerTest do
  @moduledoc """
  The B4b vertical slice: an approved book target with an in-flight grab is tracked to completion,
  validated, published, and shown as available — and the races that could double-grab or
  double-import it are fenced.

  Real filesystem and real `PathPolicy` on purpose: publication is a filesystem effect, and the
  guarantees worth testing (the file lands under the library root, an existing file is never
  overwritten, a rejected payload leaves nothing behind) are only meaningful against real disk.
  """
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Books
  alias Cinder.Books.{BookFile, BookGrab}
  alias Cinder.Catalog
  alias Cinder.Download.BookPoller
  alias Cinder.Repo

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  describe "advance_downloading" do
    test "a completed download is published and the target goes available", ctx do
      %{grab: grab, target: target, books: books, release_dir: release_dir} =
        downloading(ctx, "The Dispossessed.epub")

      complete_download(release_dir)

      poll!()

      target = Repo.reload!(target)
      assert target.status == :available

      file = Repo.get_by!(BookFile, book_target_id: target.id)

      expected =
        Path.join([books, "Ursula K. Le Guin", "The Dispossessed", "The Dispossessed.epub"])

      assert file.path == expected
      assert file.format == :epub
      assert File.read!(expected) == "book bytes"

      # The grab is the transient row: it exists only while a download is in flight.
      refute Repo.get(BookGrab, grab.id)
    end

    test "progress is recorded while the download is still running", ctx do
      %{grab: grab, target: target} = downloading(ctx, "book.epub")

      expect(Cinder.Download.ClientMock, :status, fn "remote-1" ->
        {:ok, %{state: :downloading, progress: 0.42, speed: 1_000, eta: 60}}
      end)

      poll!()

      grab = Repo.reload!(grab)
      assert grab.download_progress == 0.42
      assert is_nil(grab.content_path)
      # Still monitored, not available: nothing has been imported.
      assert Repo.reload!(target).status == :monitored
    end

    test "a dead download parks the target as held with the client's reason", ctx do
      %{target: target, grab: grab} = downloading(ctx, "book.epub")

      expect(Cinder.Download.ClientMock, :status, fn "remote-1" ->
        {:ok, %{state: :error, progress: 0.1, reason: "unpacking failed"}}
      end)

      expect(Cinder.Download.ClientMock, :remove, fn "remote-1", _opts -> :ok end)

      capture_log(fn -> poll!() end)

      target = Repo.reload!(target)
      assert target.status == :held
      assert target.hold_reason =~ "unpacking failed"
      refute Repo.get(BookGrab, grab.id)
    end

    test "a transient status error leaves the grab alone to retry", ctx do
      %{grab: grab, target: target} = downloading(ctx, "book.epub")

      expect(Cinder.Download.ClientMock, :status, fn "remote-1" -> {:error, :timeout} end)

      capture_log(fn -> poll!() end)

      # No park, no import: an unreachable client is not evidence about the download.
      assert Repo.reload!(target).status == :monitored
      assert Repo.get(BookGrab, grab.id)
    end
  end

  describe "validation refusals" do
    test "an ambiguous multi-book payload holds instead of guessing", ctx do
      %{target: target, release_dir: release_dir, books: books} =
        downloading(ctx, "Book One.epub")

      dir = release_dir
      File.write!(Path.join(dir, "Book Two.epub"), "a different book")

      complete_download(release_dir)
      capture_log(fn -> poll!() end)

      target = Repo.reload!(target)
      assert target.status == :held
      assert target.hold_reason =~ "ambiguous_book_files"

      # Nothing was published: a guess is exactly what the contract forbids.
      assert Repo.all(BookFile) == []
      assert File.ls!(books) == []
    end

    test "an archive-only payload holds rather than being expanded", ctx do
      %{target: target, release_dir: release_dir} = downloading(ctx, "book.epub")
      dir = release_dir
      File.rm!(Path.join(dir, "book.epub"))
      File.write!(Path.join(dir, "book.rar"), "archive")

      complete_download(release_dir)
      capture_log(fn -> poll!() end)

      assert Repo.reload!(target).status == :held
      assert Repo.reload!(target).hold_reason =~ "unsupported_archive"
      assert Repo.all(BookFile) == []
    end

    test "a completed download with no content path holds", ctx do
      %{target: target} = downloading(ctx, "book.epub")

      expect(Cinder.Download.ClientMock, :status, fn "remote-1" ->
        {:ok, %{state: :completed, progress: 1.0, content_path: nil}}
      end)

      capture_log(fn -> poll!() end)

      assert Repo.reload!(target).status == :held
    end
  end

  describe "idempotency" do
    test "repeated ticks cannot double-import", ctx do
      %{target: target, books: books, release_dir: release_dir} =
        downloading(ctx, "The Dispossessed.epub")

      complete_download(release_dir)

      poll!()

      # Second tick: the grab is gone, so there is nothing left to advance and no client call.
      poll!()

      assert [%BookFile{}] = Repo.all(BookFile)
      assert Repo.reload!(target).status == :available

      dir = Path.join([books, "Ursula K. Le Guin", "The Dispossessed"])
      assert File.ls!(dir) == ["The Dispossessed.epub"]
    end

    test "an existing file at the destination is kept, never overwritten", ctx do
      %{target: target, books: books, release_dir: release_dir} =
        downloading(ctx, "The Dispossessed.epub")

      dest_dir = Path.join([books, "Ursula K. Le Guin", "The Dispossessed"])
      File.mkdir_p!(dest_dir)
      dest = Path.join(dest_dir, "The Dispossessed.epub")
      File.write!(dest, "the operator's own copy")

      complete_download(release_dir)

      poll!()

      # Automatic upgrades and conversion are parked for the first release: the existing bytes win.
      assert File.read!(dest) == "the operator's own copy"
      assert Repo.reload!(target).status == :available
      assert Repo.get_by!(BookFile, book_target_id: target.id).path == dest
    end

    test "a path another target already claims is refused without destroying the file", ctx do
      # Two distinct works whose author/title fold to the SAME destination path. The second
      # import must lose the `book_files.path` unique index and roll its stage back — and that
      # rollback must not delete the first target's published file.
      %{target: first, books: books, release_dir: first_dir} =
        downloading(ctx, "The Dispossessed.epub")

      complete_download(first_dir)
      poll!()

      dest =
        Path.join([books, "Ursula K. Le Guin", "The Dispossessed", "The Dispossessed.epub"])

      assert File.read!(dest) == "book bytes"
      assert Repo.reload!(first).status == :available

      # A second target for an identically-named work by the same author.
      %{target: second, release_dir: second_dir} =
        downloading(ctx, "The Dispossessed.epub", "remote-2")

      File.write!(Path.join(second_dir, "The Dispossessed.epub"), "a different edition")
      complete_download(second_dir, "remote-2")
      poll!()

      # The first target's file is untouched, and still the only row for that path.
      assert File.read!(dest) == "book bytes"
      assert [%BookFile{book_target_id: owner}] = Repo.all(BookFile)
      assert owner == first.id

      # The second target parked visibly rather than silently reporting success.
      second = Repo.reload!(second)
      assert second.status == :held
      assert second.hold_reason == "book_file_exists"
    end
  end

  describe "grab uniqueness" do
    test "a target cannot hold two grabs at once", ctx do
      %{target: target} = downloading(ctx, "book.epub")

      # The DB fence, asserted directly: the poller's own double-grab protection is this index.
      assert {:error, :book_grab_exists} =
               Books.Grabs.create(target.id, "remote-2", :torrent, "Another Release")
    end
  end

  # --- fixtures ---

  defp poll! do
    start_supervised!({BookPoller, interval: 60_000})
    assert :ok = BookPoller.poll()
    stop_supervised!(BookPoller)
  end

  defp complete_download(release_dir, remote_id \\ "remote-1") do
    expect(Cinder.Download.ClientMock, :status, fn ^remote_id ->
      {:ok, %{state: :completed, progress: 1.0, content_path: release_dir}}
    end)
  end

  defp downloading(ctx, filename, remote_id \\ "remote-1")

  defp downloading(%{tmp_dir: tmp} = ctx, filename, "remote-1") do
    build_target(real_book_library(tmp), ctx, filename, "remote-1")
  end

  # A second target in an ALREADY-configured library: `real_book_library/1` rewrites the app env
  # and registers its own `on_exit`, so calling it twice in one test would stack restores. The
  # roots are re-derived from the same tmp_dir, and the existing profile is reused — a library
  # path is unique across profiles, and two targets sharing one root is the case under test.
  defp downloading(%{tmp_dir: tmp} = ctx, filename, remote_id) do
    roots = %{downloads: Path.join(tmp, "downloads"), books: Path.join(tmp, "books")}
    build_target(roots, ctx, filename, remote_id)
  end

  defp build_target(%{downloads: downloads, books: books}, _ctx, filename, remote_id) do
    release_dir = Path.join(downloads, "release-#{remote_id}")
    File.mkdir_p!(release_dir)
    File.write!(Path.join(release_dir, filename), "book bytes")

    profile = ebook_profile(books)

    work = work_fixture("The Dispossessed", "Ursula K. Le Guin")
    {:ok, target} = Books.monitor_target(work, :ebook, profile)
    {:ok, grab} = Books.Grabs.create(target.id, remote_id, :torrent, "The Dispossessed EPUB")

    %{
      grab: grab,
      target: target,
      work: work,
      books: books,
      downloads: downloads,
      release_dir: release_dir
    }
  end

  # One `:ebook` profile per library root: `media_profiles.library_path` is unique, so a second
  # target in the same test reuses the first profile rather than creating a colliding one.
  defp ebook_profile(books) do
    case Enum.find(Catalog.list_profiles(:ebook), &(&1.library_path == books)) do
      %Catalog.Profile{} = existing ->
        existing

      nil ->
        {:ok, profile} =
          Catalog.create_profile(%{
            name: "Ebooks #{System.unique_integer([:positive])}",
            kind: :ebook,
            handling: :standard,
            library_path: books
          })

        profile
    end
  end

  defp real_book_library(tmp) do
    downloads = Path.join(tmp, "downloads")
    books = Path.join(tmp, "books")
    File.mkdir_p!(downloads)
    File.mkdir_p!(books)

    keys = [
      :filesystem,
      :path_policy,
      :import_roots,
      :explicit_import_roots,
      :books_library_path,
      :move_on_import
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :explicit_import_roots, [downloads])
    Application.put_env(:cinder, :books_library_path, books)
    Application.put_env(:cinder, :move_on_import, false)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    %{downloads: downloads, books: books}
  end

  defp work_fixture(title, author_name) do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, work} =
      Books.upsert_work(%{
        title: title,
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, author} =
      Books.upsert_author(%{
        name: author_name,
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: "a#{id}"}
      })

    {:ok, _credit} = Books.put_credit(work, %{author_id: author.id, role: "author", position: 0})

    Books.get_work(work.id)
  end
end
