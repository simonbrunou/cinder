defmodule Cinder.Repo.Migrations.RenameDownloadFailureReasons do
  use Ecto.Migration

  # #755: the download watch's failure reasons got protocol-neutral names, and one name for a
  # completion with no path (`Cinder.Download.Watch`). Rows written before it keep the old words,
  # so they are renamed here: exact strings only, because a book hold reason is free text and a
  # client's detail may contain one of these words.
  #
  # Nothing reads these names by value (blocklist readers match only `stalled` and the upgrade-only
  # reasons; a hold reason is display text), so this gives each renamed concept one name in the
  # database rather than fixing a misread. `download_failed` (the `download_error` concept, not
  # renamed here) and bare client details stay as #733 left them.
  @renames [
    {"blocked_releases", "reason", "torrent_not_found", "download_not_found"},
    {"book_targets", "hold_reason", "torrent_not_found", "download_not_found"},
    {"book_targets", "hold_reason", "download_missing", "download_not_found"},
    {"book_targets", "hold_reason", "missing_content_path", "no_content_path"},
    {"book_blocked_releases", "reason", "torrent_not_found", "download_not_found"},
    {"book_blocked_releases", "reason", "download_missing", "download_not_found"},
    {"book_blocked_releases", "reason", "missing_content_path", "no_content_path"}
  ]

  def up do
    for {table, column, old, new} <- @renames do
      execute("UPDATE #{table} SET #{column} = '#{new}' WHERE #{column} = '#{old}'")
    end
  end

  # Not reversed: a row written under the new names after this migration can't be told apart from
  # a renamed one, and the code before it reads none of these names by value either.
  def down, do: :ok
end
