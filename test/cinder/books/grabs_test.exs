defmodule Cinder.Books.GrabsTest do
  @moduledoc """
  `track/2` and `delete/1` are this module's only broadcasting writes — every other write
  (`create`, `mark_downloaded`, `bump_attempts`) deliberately does not broadcast; see the module
  doc.
  """
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.Books
  alias Cinder.Books.{BookOpsLog, Grabs}
  alias Cinder.Catalog

  setup do
    id = unique_id()

    {:ok, profile} =
      Catalog.create_profile(%{name: "Ebooks #{id}", kind: :ebook, handling: :standard})

    {:ok, work} =
      Books.upsert_work(%{
        title: "Progress Test #{id}",
        identifier: identifier("openlibrary", "work", id)
      })

    {:ok, target} = Books.monitor_target(work, :ebook, profile)
    {:ok, grab} = Grabs.create(target.id, "remote-#{id}", :torrent, "Release #{id}")

    %{grab: grab}
  end

  test "a real progress change writes and broadcasts {:book_grab_updated, grab}", %{grab: grab} do
    Books.subscribe_targets()

    assert {:ok, updated} =
             Grabs.track(grab, %{download_progress: 0.5, download_speed: 1000, download_eta: 60})

    assert updated.download_progress == 0.5

    assert_receive {:book_grab_updated, %Cinder.Books.BookGrab{id: id, download_progress: 0.5}}
    assert id == updated.id
  end

  test "an identical snapshot writes and broadcasts nothing", %{grab: grab} do
    {:ok, first} =
      Grabs.track(grab, %{download_progress: 0.2, download_speed: 500, download_eta: 90})

    Books.subscribe_targets()

    assert {:ok, ^first} =
             Grabs.track(first, %{download_progress: 0.2, download_speed: 500, download_eta: 90})

    refute_receive {:book_grab_updated, _grab}, 50
  end

  test "a partial change (speed only) still broadcasts", %{grab: grab} do
    {:ok, first} = Grabs.track(grab, %{download_progress: 0.2})
    Books.subscribe_targets()

    assert {:ok, updated} = Grabs.track(first, %{download_progress: 0.2, download_speed: 999})
    assert updated.download_speed == 999

    assert_receive {:book_grab_updated, %Cinder.Books.BookGrab{download_speed: 999}}
  end

  test "a grab already marked downloaded refuses the write and broadcasts nothing", %{grab: grab} do
    {:ok, downloaded} = Grabs.mark_downloaded(grab, "/tmp/book-#{grab.id}.epub")
    Books.subscribe_targets()

    assert {:error, :stale_grab} =
             Grabs.track(downloaded, %{download_progress: 0.9, download_speed: 1_000})

    # The write never landed: re-reading confirms nothing about the completed grab changed.
    refute Cinder.Repo.get!(Cinder.Books.BookGrab, grab.id).download_progress == 0.9
    refute_receive {:book_grab_updated, _grab}, 50
  end

  test "a regressed download_progress is dropped, not recorded — the bar never walks backwards",
       %{grab: grab} do
    {:ok, first} = Grabs.track(grab, %{download_progress: 0.7, download_speed: 100})
    Books.subscribe_targets()

    # A single tick that under-reports progress but genuinely changed speed: the regression is
    # dropped from the write while the real change still lands and still broadcasts.
    assert {:ok, updated} = Grabs.track(first, %{download_progress: 0.3, download_speed: 250})

    assert updated.download_progress == 0.7
    assert updated.download_speed == 250

    assert_receive {:book_grab_updated,
                    %Cinder.Books.BookGrab{download_progress: 0.7, download_speed: 250}}
  end

  test "a download_progress-only regression with nothing else changed writes and broadcasts nothing",
       %{grab: grab} do
    {:ok, first} = Grabs.track(grab, %{download_progress: 0.7, download_speed: 100})
    Books.subscribe_targets()

    assert {:ok, ^first} =
             Grabs.track(first, %{download_progress: 0.3, download_speed: 100})

    refute_receive {:book_grab_updated, _grab}, 50
  end

  describe "delete/1" do
    test "broadcasts {:book_grab_deleted, target_id} after the row is gone", %{grab: grab} do
      Books.subscribe_targets()

      assert :ok = Grabs.delete(grab)

      assert_receive {:book_grab_deleted, target_id}
      assert target_id == grab.book_target_id
      refute Grabs.for_target(grab.book_target_id)
    end

    # The trace #403 establishes: a caller's own target-status write and broadcast (e.g.
    # `Cinder.Books.hold_target/2`) commits and fires strictly before this module's delete ever
    # runs, so a subscriber can observe the target's terminal broadcast while the grab it is
    # about to orphan is still readable — proving the ordering deterministically, not by
    # scheduling luck.
    test "the target's own terminal broadcast can be observed before delete/1 ever runs", %{
      grab: grab
    } do
      target = Books.get_target(grab.book_target_id)
      Books.subscribe_targets()

      assert {:ok, held} = Books.hold_target(target, "operator conflict")

      assert_receive {:book_target_updated, ^held}
      assert %Cinder.Books.BookGrab{} = Grabs.for_target(grab.book_target_id)

      # The corrective this issue adds: deleting the now-orphaned grab broadcasts for itself.
      assert :ok = Grabs.delete(grab)
      assert_receive {:book_grab_deleted, target_id}
      assert target_id == grab.book_target_id
    end
  end

  describe "delete_only/1" do
    # #445: `fence_book_cleanup/1` now uses this instead of `delete/1`, so a caller deleting the
    # grab inside its OWN transaction can broadcast only after that transaction commits. Proven
    # here by wrapping it in a transaction that rolls back afterward: if `delete_only/1`
    # broadcast unconditionally the way `delete/1` does, this would leak a
    # `{:book_grab_deleted, _}` message for a deletion the rollback just undid.
    test "inside a transaction that rolls back, leaves no broadcast and the grab intact", %{
      grab: grab
    } do
      Books.subscribe_targets()

      assert {:error, :simulated_failure} =
               Cinder.Repo.transaction(fn ->
                 Grabs.delete_only(grab)
                 Cinder.Repo.rollback(:simulated_failure)
               end)

      refute_receive {:book_grab_deleted, _}, 50
      assert Grabs.for_target(grab.book_target_id)
    end

    test "inside a transaction that commits, the row is gone but nothing broadcasts on its own",
         %{grab: grab} do
      Books.subscribe_targets()

      assert {:ok, :ok} = Cinder.Repo.transaction(fn -> Grabs.delete_only(grab) end)

      refute Grabs.for_target(grab.book_target_id)
      refute_receive {:book_grab_deleted, _}, 50
    end
  end

  describe "duplicate grab refusal — book_ops_log" do
    test "a duplicate grab attempt is refused and logs exactly one book_ops_log row", %{
      grab: grab
    } do
      assert {:error, :book_grab_exists} =
               Grabs.create(
                 grab.book_target_id,
                 "remote-dup-#{grab.id}",
                 :torrent,
                 "Duplicate Release"
               )

      rows = Repo.all(from l in BookOpsLog, where: l.book_target_id == ^grab.book_target_id)
      assert [%BookOpsLog{category: "duplicate_grab_refused"}] = rows
    end

    # `book_ops_log` renamed away (mirroring `book_request_test.exs`'s own raw-SQL DB-failure
    # simulation) forces a genuine, unmocked insert failure — the `catch` clause in
    # `Books.log_duplicate_grab_refused/2`'s `put_ops_log/1`, not a changeset error. Restored
    # before the final assertion so `Repo.aggregate/2` can read the (empty) table again.
    test "a Repo failure logging the duplicate does not affect the refusal it is recording", %{
      grab: grab
    } do
      Repo.query!("ALTER TABLE book_ops_log RENAME TO book_ops_log_disabled")

      log =
        capture_log(fn ->
          assert {:error, :book_grab_exists} =
                   Grabs.create(
                     grab.book_target_id,
                     "remote-dup2-#{grab.id}",
                     :torrent,
                     "Duplicate Release"
                   )
        end)

      Repo.query!("ALTER TABLE book_ops_log_disabled RENAME TO book_ops_log")

      assert log =~ "book ops_log insert raised"
      assert Repo.aggregate(BookOpsLog, :count) == 0
    end
  end

  describe "target_ids_in_progress/0" do
    test "returns the target id of every live grab, and excludes a target with none", %{
      grab: grab
    } do
      id = unique_id()

      {:ok, profile} =
        Catalog.create_profile(%{name: "Ebooks no-grab #{id}", kind: :ebook, handling: :standard})

      {:ok, work} =
        Books.upsert_work(%{
          title: "No Grab #{id}",
          identifier: identifier("openlibrary", "work", id)
        })

      {:ok, idle_target} = Books.monitor_target(work, :ebook, profile)

      in_progress = Grabs.target_ids_in_progress()
      assert grab.book_target_id in in_progress
      refute idle_target.id in in_progress
    end
  end

  defp identifier(provider, kind, foreign_id),
    do: %{provider: provider, kind: kind, foreign_id: foreign_id}

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
