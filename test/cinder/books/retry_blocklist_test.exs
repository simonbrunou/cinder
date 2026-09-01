defmodule Cinder.Books.RetryBlocklistTest do
  @moduledoc """
  `hold_target/4`'s blocklist write, `retry_target/1`, and `pause_target/1`'s grab-in-progress
  race guard — B5a's context-level surface.
  """
  use Cinder.DataCase, async: false

  alias Cinder.Books
  alias Cinder.Books.{BookBlockedRelease, BookTarget}

  test "hold_target/4 with a release title writes exactly one blocklist row per hold" do
    target = ebook_target()

    assert {:ok, %BookTarget{status: :held}} =
             Books.hold_target(target, :download_failed, "Bad Release (epub)", true)

    assert Books.blocked_release_titles(target.id) == ["Bad Release (epub)"]

    rows = Repo.all(from b in BookBlockedRelease, where: b.book_target_id == ^target.id)
    assert length(rows) == 1
  end

  test "opts[:replace] widens the guard to :available, since a replace grab's target stays
        :available for its whole cycle" do
    target = ebook_target()

    {:ok, _file} =
      Books.Files.record_import(target, %{
        path: "/tmp/replace-guard-#{target.id}.epub",
        size: 1000,
        format: :epub
      })

    available = Books.get_target(target.id)
    assert available.status == :available

    # The plausible bug this defends against: without the `replace:` opt, EVERY failure path for
    # a replace grab (the target never leaves :available for its whole download/import cycle)
    # would hit this exact guard and lose the hold entirely.
    assert {:error, :stale_status} =
             Books.hold_target(available, :no_book_file, "Worse Release", false)

    assert {:ok, %BookTarget{status: :held, hold_reason: "no_book_file"}} =
             Books.hold_target(available, :no_book_file, "Worse Release", false, replace: true)

    assert Books.blocked_release_titles(target.id) == ["Worse Release"]
  end

  test "a second hold on an already-held target writes no blocklist row" do
    target = ebook_target()
    {:ok, held} = Books.hold_target(target, :download_failed, "First Bad Release", true)

    # The guarded :monitored precondition already failed for the target's CURRENT state.
    assert {:error, _reason} =
             Books.hold_target(held, :download_failed, "Second Bad Release", true)

    assert Books.blocked_release_titles(target.id) == ["First Bad Release"]
  end

  test "hold_target/4 with no release title writes no blocklist row" do
    target = ebook_target()
    {:ok, _held} = Books.hold_target(target, :some_reason)

    assert Books.blocked_release_titles(target.id) == []
  end

  test "clearing a blocklist removes only that target's rows, leaving a different target's intact" do
    target_a = ebook_target()
    target_b = ebook_target()

    {:ok, _} = Books.hold_target(target_a, :download_failed, "Release A", true)
    {:ok, _} = Books.hold_target(target_b, :download_failed, "Release B", true)

    Books.clear_blocklist(target_a.id)

    assert Books.blocked_release_titles(target_a.id) == []
    assert Books.blocked_release_titles(target_b.id) == ["Release B"]
  end

  test "retry_target/1 returns a held target to :monitored without clearing its blocklist" do
    target = ebook_target()
    {:ok, held} = Books.hold_target(target, :download_failed, "Dead Release", true)

    assert {:ok, %BookTarget{status: :monitored, hold_reason: nil}} =
             Books.retry_target(held)

    assert Books.blocked_release_titles(target.id) == ["Dead Release"]
  end

  test "retry_target/1 on a target that already left :held returns {:error, :stale_status}" do
    target = ebook_target()
    {:ok, held} = Books.hold_target(target, :download_failed, nil, true)

    # A concurrent import raced this decision and already made the target :available.
    {:ok, _available} =
      Books.transition_target(held, %{status: :available}, expect: :held)

    assert {:error, :stale_status} = Books.retry_target(held)
  end

  describe "pause_target/1" do
    test "pauses a :monitored target to :unmonitored and broadcasts" do
      target = ebook_target()
      Books.subscribe_targets()

      assert {:ok, %BookTarget{status: :unmonitored} = paused} = Books.pause_target(target)
      assert_receive {:book_target_updated, ^paused}
    end

    test "refuses with {:error, :grab_in_progress} when a grab exists for the target, leaving
          status untouched" do
      target = ebook_target()
      {:ok, _grab} = Books.Grabs.create(target.id, "remote-1", :torrent, "In Flight Release")

      assert {:error, :grab_in_progress} = Books.pause_target(target)
      assert Repo.get!(BookTarget, target.id).status == :monitored
    end

    test "refuses with {:error, :stale_status} on a non-:monitored target" do
      target = ebook_target()
      {:ok, held} = Books.hold_target(target, :some_reason)

      assert {:error, :stale_status} = Books.pause_target(held)
    end
  end

  test "resume_target/1 returns an :unmonitored target to :monitored, leaving profile_id" do
    target = ebook_target()
    {:ok, paused} = Books.pause_target(target)

    assert {:ok, %BookTarget{status: :monitored, profile_id: profile_id}} =
             Books.resume_target(paused)

    assert profile_id == target.profile_id
  end

  defp ebook_target do
    id = unique_id()

    {:ok, profile} =
      Cinder.Catalog.create_profile(%{name: "Ebooks #{id}", kind: :ebook, handling: :standard})

    {:ok, work} =
      Books.upsert_work(%{
        title: "Work #{id}",
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    {:ok, target} = Books.monitor_target(work, :ebook, profile)
    target
  end

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
