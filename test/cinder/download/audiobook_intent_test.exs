defmodule Cinder.Download.AudiobookIntentTest do
  @moduledoc """
  The `:audiobook` clause of `Download.grab_book_target/3` — the `Cinder.Download.BookIntentTest`
  sibling. What is asserted here is that an audiobook intent takes the SAME durable
  reserve/reconcile scaffolding the e-book clause already has, and that the type-matched dispatch
  guard genuinely refuses a release struct built for the wrong media kind in both directions.
  """
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Acquisition.{AudiobookRelease, BookRelease}
  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Catalog
  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Repo

  setup :set_mox_global
  setup :verify_on_exit!

  describe "grab_book_target/3 — :audiobook" do
    test "reserves, submits, and hands the remote id to a grab" do
      target = monitored_audiobook_target()

      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "remote-1"} end)

      assert {:ok, %BookGrab{} = grab} = Download.grab_book_target(target, audiobook_release())

      assert grab.book_target_id == target.id
      assert grab.download_id == "remote-1"
      assert grab.download_protocol == :torrent
      assert Repo.all(Intent) == []
    end

    test "re-grabbing the same release is idempotent, not a second download" do
      target = monitored_audiobook_target()

      stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, 1, fn _release, _opts -> {:ok, "remote-1"} end)

      assert {:ok, %BookGrab{id: id}} = Download.grab_book_target(target, audiobook_release())

      assert {:error, :download_intent_busy} =
               Download.grab_book_target(target, audiobook_release())

      assert [%BookGrab{id: ^id}] = Repo.all(BookGrab)
    end

    test "a permanently rejected submission holds the target with the exact reason" do
      target = monitored_audiobook_target()

      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:error, :bad_torrent} end)

      assert {:error, :bad_torrent} = Download.grab_book_target(target, audiobook_release())

      target = Repo.reload!(target)
      assert target.status == :held
      assert target.hold_reason == "bad_torrent"
      assert Repo.all(BookGrab) == []
    end

    test "replace: true is carried onto the created grab" do
      target = monitored_audiobook_target()

      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "remote-1"} end)

      assert {:ok, %BookGrab{replace: true}} =
               Download.grab_book_target(target, audiobook_release(), replace: true)
    end

    # Regression: the type-matched dispatch guard, exercised in BOTH directions now that two live
    # kinds exist. No ClientMock expectation on either — reaching the downloader at all fails the
    # test, since nothing downstream is built to handle the wrong release shape for that kind.
    test "an ebook target is refused an AudiobookRelease before any reservation" do
      target = monitored_ebook_target()

      assert {:error, :unsupported_media_kind} =
               Download.grab_book_target(target, audiobook_release())

      assert Repo.all(Intent) == []
      assert Repo.all(BookGrab) == []
    end

    test "an audiobook target is refused a BookRelease before any reservation" do
      target = monitored_audiobook_target()

      assert {:error, :unsupported_media_kind} =
               Download.grab_book_target(target, %BookRelease{
                 title: "Le Guin - The Dispossessed (EPUB)",
                 download_url: "magnet:?xt=urn:btih:abc",
                 protocol: :torrent,
                 formats: [:epub]
               })

      assert Repo.all(Intent) == []
      assert Repo.all(BookGrab) == []
    end
  end

  defp audiobook_release do
    %AudiobookRelease{
      title: "Le Guin - The Dispossessed (M4B)",
      download_url: "magnet:?xt=urn:btih:def",
      protocol: :torrent,
      formats: [:m4b]
    }
  end

  defp monitored_audiobook_target do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, profile} =
      Catalog.create_profile(%{
        name: "Audiobooks #{id}",
        kind: :audiobook,
        handling: :standard,
        library_path: "/tmp/cinder-audiobooks-#{id}"
      })

    {:ok, work} =
      Books.upsert_work(%{
        title: "The Dispossessed #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, %BookTarget{} = target} = Books.monitor_target(work, :audiobook, profile)
    target
  end

  defp monitored_ebook_target do
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
        title: "The Dispossessed #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, %BookTarget{} = target} = Books.monitor_target(work, :ebook, profile)
    target
  end
end
