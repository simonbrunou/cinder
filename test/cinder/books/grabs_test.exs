defmodule Cinder.Books.GrabsTest do
  @moduledoc """
  `track/2` and `delete/1` are this module's only broadcasting writes — every other write
  (`create`, `mark_downloaded`, `bump_attempts`) deliberately does not broadcast; see the module
  doc.
  """
  use Cinder.DataCase, async: false

  alias Cinder.Books
  alias Cinder.Books.Grabs
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

  defp identifier(provider, kind, foreign_id),
    do: %{provider: provider, kind: kind, foreign_id: foreign_id}

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
