defmodule Cinder.Download.BookIntentTest do
  @moduledoc """
  The durable reservation for a book grab: `Download.grab_book_target/2` must be safe to call
  twice, must not let two targets adopt one remote download, and must refuse to submit for a
  target that is no longer eligible.

  These are the `:book_target` clauses of the shared intent machinery, so what is asserted here is
  that a book intent takes the book branch at every dispatch point rather than falling into the
  movie or episode one.
  """
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Acquisition.BookRelease
  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Catalog
  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Repo

  setup :set_mox_global
  setup :verify_on_exit!

  describe "grab_book_target/2" do
    test "reserves, submits, and hands the remote id to a grab" do
      target = monitored_target()

      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "remote-1"} end)

      assert {:ok, %BookGrab{} = grab} = Download.grab_book_target(target, release())

      assert grab.book_target_id == target.id
      assert grab.download_id == "remote-1"
      assert grab.download_protocol == :torrent
      assert grab.release_title == "Le Guin - The Dispossessed (EPUB)"

      # The intent is consumed once its owner row exists: the grab is now the durable record.
      assert Repo.all(Intent) == []
    end

    test "re-grabbing the same release is idempotent, not a second download" do
      target = monitored_target()

      # `add` exactly once across BOTH calls is the assertion. The second call still reserves an
      # intent and asks the client whether that reservation has a job (it has not), then cleans
      # the reservation up — the durable-reservation protocol, same as the movie path — so
      # `find_by_operation_key` is stubbed rather than counted.
      stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, 1, fn _release, _opts -> {:ok, "remote-1"} end)

      assert {:ok, %BookGrab{id: id}} = Download.grab_book_target(target, release())
      assert {:error, :download_intent_busy} = Download.grab_book_target(target, release())

      assert [%BookGrab{id: ^id}] = Repo.all(BookGrab)
      assert Repo.all(Intent) == []
    end

    test "a second, different release for the same target is refused" do
      target = monitored_target()

      stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, 1, fn _release, _opts -> {:ok, "remote-1"} end)

      assert {:ok, _grab} = Download.grab_book_target(target, release())

      other = %BookRelease{release() | title: "Another Edition", download_url: "magnet:?xt=other"}

      assert {:error, :download_intent_busy} = Download.grab_book_target(target, other)
      assert [%BookGrab{download_id: "remote-1"}] = Repo.all(BookGrab)
    end

    test "an unmonitored target is never submitted" do
      target = monitored_target()

      {:ok, target} =
        Books.transition_target(target, %{status: :unmonitored}, expect: :monitored)

      # No client expectations: an ineligible target must not reach the downloader at all.
      assert {:error, reason} = Download.grab_book_target(target, release())
      assert reason in [:stale_target, :stale_entry]

      assert Repo.all(BookGrab) == []
    end

    test "a held target is never submitted" do
      target = monitored_target()

      {:ok, target} =
        Books.transition_target(target, %{status: :held, hold_reason: "identity conflict"},
          expect: :monitored
        )

      assert {:error, _reason} = Download.grab_book_target(target, release())
      assert Repo.all(BookGrab) == []
    end

    test "two targets cannot adopt one remote download" do
      first = monitored_target()
      second = monitored_target()

      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "shared-remote"} end)

      assert {:ok, _grab} = Download.grab_book_target(first, release())

      # The second target's submission resolves to the SAME remote id — the client deduped it.
      # Adopting it would have two targets importing from one payload.
      #
      # No `remove` expectation, deliberately: the refusal must NOT touch the client. That remote
      # job is the first target's live download, and removing it (the client's `remove` deletes
      # files) would destroy a download this intent never owned. An unexpected `remove` call
      # raises here, which is the assertion.
      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "shared-remote"} end)

      assert {:error, :download_intent_busy} = Download.grab_book_target(second, release())

      # The first target keeps its grab, and the losing intent left nothing behind.
      assert [%BookGrab{book_target_id: owner, download_id: "shared-remote"}] = Repo.all(BookGrab)
      assert owner == first.id
      assert Repo.all(Intent) == []
    end

    test "a permanently rejected submission holds the target instead of losing the failure" do
      target = monitored_target()

      # The client parses the release and refuses it outright — a dead magnet, an unparseable
      # .torrent. `abandon_reserved/2` drops the reservation, and for a movie or an episode that
      # is enough because the next search pass re-derives the work. Books have no search pass, so
      # a `:monitored` target with no grab and no intent is indistinguishable from one nobody has
      # picked a release for — and `reconcile_pending_intents/1`, which the poller runs every
      # tick, discards this return value, so the failure would be silent as well as permanent.
      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:error, :bad_torrent} end)

      assert {:error, :bad_torrent} = Download.grab_book_target(target, release())

      target = Repo.reload!(target)
      assert target.status == :held
      assert target.hold_reason == "bad_torrent"

      assert Repo.all(Intent) == []
      assert Repo.all(BookGrab) == []
    end

    test "a permanently rejected submission blocklists its release title" do
      target = monitored_target()

      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:error, :bad_torrent} end)

      assert {:error, :bad_torrent} = Download.grab_book_target(target, release())

      assert Books.blocked_release_titles(target.id) == [release().title]
    end

    test "replace: true is carried onto the created grab" do
      target = monitored_target()

      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "remote-1"} end)

      assert {:ok, %BookGrab{replace: true}} =
               Download.grab_book_target(target, release(), replace: true)
    end

    test "replace: false (the default) is carried onto the created grab" do
      target = monitored_target()

      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
      expect(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "remote-1"} end)

      assert {:ok, %BookGrab{replace: false}} = Download.grab_book_target(target, release())
    end

    test "an audiobook target is refused before any reservation" do
      target = monitored_target()
      {:ok, audiobook} = Books.ensure_target(Books.get_work(target.work_id), :audiobook)

      # No ClientMock expectation: reaching the downloader at all fails this test. Nothing below
      # `grab_book_target/2` is audiobook-aware — `BookSources` accepts `.epub`/`.azw3`/`.mobi`
      # only — so an e-book release here would publish an EPUB into the audiobook root and report
      # the audiobook available.
      assert {:error, :unsupported_media_kind} = Download.grab_book_target(audiobook, release())

      assert Repo.all(Intent) == []
      assert Repo.all(BookGrab) == []
    end
  end

  describe "intent shape" do
    test "a book intent carries no episode ids and no video snapshots" do
      target = monitored_target()

      # Fail submission so the reservation stays inspectable.
      expect(Cinder.Download.ClientMock, :find_by_operation_key, fn _key ->
        {:error, :unreachable}
      end)

      assert {:error, _reason} = Download.grab_book_target(target, release())

      assert [%Intent{} = intent] = Repo.all(Intent)
      assert intent.kind == :book_target
      assert intent.target_id == target.id
      assert intent.episode_ids == []
      assert is_nil(intent.mapping_snapshot)
      assert is_nil(intent.release_policy_snapshot)

      # The URL is encrypted at rest, exactly as a movie/TV reservation's is.
      refute intent.release["download_url"]
      assert is_binary(intent.release["download_url_ciphertext"])
    end

    test "a release with no download URL is refused before any client call" do
      target = monitored_target()

      # No ClientMock expectation: reaching the client at all would fail this test. A book
      # release that survived scoring can still carry a nil URL (an indexer result missing its
      # link), and `reserve_intent/1`'s binary-URL guard is what stops it becoming a reservation.
      urlless = %BookRelease{release() | download_url: nil}

      assert {:error, :unsupported_download_url} = Download.grab_book_target(target, urlless)
      assert Repo.all(Intent) == []
      assert Repo.all(BookGrab) == []
    end
  end

  defp release do
    %BookRelease{
      title: "Le Guin - The Dispossessed (EPUB)",
      download_url: "magnet:?xt=urn:btih:abc",
      protocol: :torrent,
      formats: [:epub]
    }
  end

  defp monitored_target do
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
