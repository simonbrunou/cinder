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

  defp complete_download(release_dir) do
    expect(Cinder.Download.ClientMock, :status, fn "remote-1" ->
      {:ok, %{state: :completed, progress: 1.0, content_path: release_dir}}
    end)
  end

  defp downloading(%{tmp_dir: tmp}, filename) do
    %{downloads: downloads, books: books} = real_book_library(tmp)

    release_dir = Path.join(downloads, "release")
    File.mkdir_p!(release_dir)
    File.write!(Path.join(release_dir, filename), "book bytes")

    {:ok, profile} =
      Catalog.create_profile(%{
        name: "Ebooks #{System.unique_integer([:positive])}",
        kind: :ebook,
        handling: :standard,
        library_path: books
      })

    work = work_fixture("The Dispossessed", "Ursula K. Le Guin")
    {:ok, target} = Books.monitor_target(work, :ebook, profile)
    {:ok, grab} = Books.Grabs.create(target.id, "remote-1", :torrent, "The Dispossessed EPUB")

    %{
      grab: grab,
      target: target,
      work: work,
      books: books,
      downloads: downloads,
      release_dir: release_dir
    }
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
