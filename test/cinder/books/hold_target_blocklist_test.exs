defmodule Cinder.Books.HoldTargetBlocklistTest do
  # #773: `/activity` and `/books/:id` re-read a held target's blocklist on its
  # `{:book_target_updated, _}` broadcast to decide whether Clear blocklist shows. The hold's
  # blocked release is written in the hold's own frame, so that broadcast follows a commit that
  # holds it.
  use Cinder.DataCase, async: false

  import Cinder.BooksFixtures
  import ExUnit.CaptureLog

  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Repo

  defp broadcast_waiting? do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.any?(messages, &match?({:book_target_updated, %BookTarget{}}, &1))
  end

  test "the blocked release is written before the hold's broadcast is sent" do
    target = monitored_book_target(:ebook)
    Books.subscribe_targets()
    handler = "hold-target-blocklist-#{System.unique_integer([:positive])}"
    test_pid = self()

    # Runs in this process for every query: at the blocklist insert, says whether the hold's
    # broadcast already sits in this process's mailbox.
    :ok =
      :telemetry.attach(
        handler,
        [:cinder, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and metadata.source == "book_blocked_releases" and
               String.starts_with?(metadata.query, "INSERT"),
             do: send(self(), {:blocklist_insert, broadcast_waiting?()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, _held} = Books.hold_target(target, :download_failed, "Dead Release")

    assert_received {:blocklist_insert, false}
    assert_received {:book_target_updated, %BookTarget{status: :held}}
    assert Books.blocked_release_titles(target.id) == ["Dead Release"]
  end

  test "a blocked release that fails to insert leaves the hold to commit and broadcast" do
    target = monitored_book_target(:audiobook)
    Books.subscribe_targets()

    Repo.query!("""
    CREATE TEMP TRIGGER refuse_book_blocked_release BEFORE INSERT ON book_blocked_releases
    BEGIN SELECT RAISE(ABORT, 'refused by test'); END
    """)

    on_exit(fn -> Repo.query("DROP TRIGGER IF EXISTS refuse_book_blocked_release") end)

    log =
      capture_log(fn ->
        assert {:ok, %BookTarget{status: :held}} =
                 Books.hold_target(target, :download_failed, "Dead Release")
      end)

    assert log =~ "book block_release raised:"
    assert Repo.get!(BookTarget, target.id).status == :held
    assert Books.blocked_release_titles(target.id) == []
    assert_received {:book_target_updated, %BookTarget{status: :held}}
  end

  test "a refused hold writes no blocked release and broadcasts nothing" do
    target = book_target_in(:paused, :ebook)
    Books.subscribe_targets()

    assert Books.hold_target(target, :download_failed, "Dead Release") ==
             {:error, :stale_status}

    assert Repo.get!(BookTarget, target.id).status == :unmonitored
    assert Books.blocked_release_titles(target.id) == []
    refute_received {:book_target_updated, _}
  end
end
