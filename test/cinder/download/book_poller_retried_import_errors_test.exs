defmodule Cinder.Download.BookPollerRetriedImportErrorsTest do
  @moduledoc """
  `BookPoller.retried_import_errors/0` (#912): the import errors that hold a book target once the
  attempt budget is spent. The list documents them for `CinderWeb.LiveHelpers.book_hold_reason/1`;
  it decides nothing about which errors retry.
  """
  use Cinder.DataCase, async: false

  alias Cinder.Books
  alias Cinder.Download.BookPoller
  alias CinderWeb.LiveHelpers

  test "the list holds every reason the import paths are known to hold on through the budget" do
    required =
      [
        :format_mismatch,
        :unsafe_destination,
        :unsafe_delete,
        :library_not_configured,
        :download_roots_not_configured,
        :traversal_limit,
        :import_stage_busy,
        :import_stage_destination_changed,
        :import_stage_journal_missing,
        :import_stage_file_changed,
        :import_stage_backup_changed,
        :import_stage_restore_changed,
        :import_stage_quarantined,
        :stale_import_stage,
        :enoent,
        :eacces,
        :eperm,
        :enospc,
        :erofs,
        :eio
      ] ++
        for(
          type <- [:directory, :symlink, :device, :other],
          do: {:unexpected_destination_type, type}
        )

    assert required -- BookPoller.retried_import_errors() == []
  end

  test "no listed reason holds at once or skips the budget" do
    listed = BookPoller.retried_import_errors()

    assert Enum.filter(listed, &(&1 in BookPoller.permanent_import_errors())) == []
    refute :stale_status in listed
    refute :timeout in listed
    assert Enum.uniq(listed) == listed
  end

  # The mapping's own tests encode each reason by hand; this holds a target on every one through
  # `Books.hold_target/5`, so a change to how it stores a reason fails here.
  test "every listed reason, held through hold_target/5, reads as a sentence, not as stored" do
    for reason <- BookPoller.retried_import_errors() do
      {:ok, held} = Books.hold_target(ebook_target(), reason, "Release #{inspect(reason)}", true)
      stored = held.hold_reason

      assert stored == if(is_atom(reason), do: Atom.to_string(reason), else: inspect(reason))
      assert LiveHelpers.book_hold_reason(stored) != stored, "#{stored} is shown as stored"
    end
  end

  defp ebook_target do
    id = Integer.to_string(System.unique_integer([:positive]))

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
end
