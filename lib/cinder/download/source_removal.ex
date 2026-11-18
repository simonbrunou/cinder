defmodule Cinder.Download.SourceRemoval do
  @moduledoc """
  Removes a download's source once Cinder is done with it: the client's job, through the
  download client, and the delivered payload on disk, through
  `Cinder.Library.delete_download_source/1`.

  - `remove_after_import/4` runs after a movie or episode import committed, and after a movie or
    TV release was rejected, a TV grab parked or a movie upgrade reverted. It removes nothing unless
    `move_on_import_removal?/1` says the `move_on_import` setting applies.
  - `release_imported_book_grab/1` runs after a book import committed. It always drops the grab,
    and removes the client job and payload only when `move_on_import_removal?/1` allows it.
  - `retire_book_grab/1` drops a book grab whose client job is done with, after an import or a
    failed download.
  - `fallback_remove/3`, `best_effort_remove/2` and `best_effort_delete_source/1` are the
    one-shot removals the others end in. `Cinder.Download.Cleaner` also calls
    `best_effort_remove/2`.

  A caller that passes a fence (`remove_after_import/4`'s `:fence`, and every
  `retire_book_grab/1`) gets its client removal fenced first: `Cinder.Download` records a
  `:cleanup_pending` intent (`fence_movie_cleanup/2`, `fence_episode_cleanup/3`,
  `fence_book_cleanup/1`) and `Cinder.Download.cleanup_intents/1` then makes the removal, so a
  transient failure stays retryable. When a newer intent already claims the target, the fence
  returns `:mismatch` and the removal falls back to `fallback_remove/3`'s one-shot attempt, with
  no intent recorded for it.

  A failed one-shot client removal or source delete is logged and returns `:ok`. A failed fenced
  client removal stays on its intent for `Cinder.Download.reconcile_pending_intents/1` to retry.
  A raise from a fence's own database write is not caught.
  """

  require Logger

  alias Cinder.{Books, Download, Library}
  alias Cinder.Books.BookGrab

  @doc """
  After a successful import, or once a downloaded release was rejected, parked or reverted,
  removes the source download when the `move_on_import` setting is on. Usenet-only (an
  allowlist, so a nil/unknown protocol no-ops) — torrents are never auto-removed so seeding
  survives. Two independent best-effort removals:

  1. Asks the client to drop its tracked job (only when a `download_id` is present) — cleans up
     history/queue metadata when the client still has it.
  2. Deletes `content_path` directly via `Cinder.Library.delete_download_source/1` — the whole
     per-operation directory or lone file the download client delivered. This is authoritative
     regardless of whether the client's history entry still exists: a client (e.g. SABnzbd with a
     short history retention) that has already evicted the job silently no-ops on its own remove,
     so on-disk cleanup can't depend on that history surviving (issue #115).

  `opts[:fence]` (issue #415) durably records the client-remove attempt before making it, so a
  transient failure (client restarting, an API timeout) survives as a retryable
  `download_intents` `:cleanup_pending` row instead of being silently discarded — the same
  fence-then-`Cinder.Download.cleanup_intents/1` pair `Cinder.Catalog`/`Cinder.Catalog.Grabs`
  already use for delete/cancel/reap, just called AFTER this tick's import already committed
  rather than inside its transaction. That ordering is safe here specifically because the durable
  owner survives the import: a movie row is never deleted by import, and the movie fence reads
  the `download_id` of the caller's `movie` struct, so a write that has since cleared the row's
  `download_id` does not change what it records; an episode's grab is captured by the caller
  BEFORE `Catalog.Grabs` deletes it — a retry can never fire against a payload the import is still reading, because the
  fenced intent does not exist until the import already has. Accepted values: `{:movie, movie}`
  (`Cinder.Download.fence_movie_cleanup/2`) or `{:episode, episode_ids, spec}`
  (`Cinder.Download.fence_episode_cleanup/3`, `spec` from `Catalog.grab_cleanup_spec/2`).
  Omitted (`nil`, the default) keeps today's one-shot best-effort removal — the shape used where
  the caller has nothing durable left to fence (`Cinder.Download.TvPoller`'s release-policy
  reject, whose `download_id` is always `nil` here regardless of any fence).

  A failed source delete or one-shot client removal is logged; a failed fenced client removal
  stays on its intent for retry. Returns `:ok` unless a fence's own database write raises.
  """
  def remove_after_import(protocol, download_id, content_path, opts \\ []) do
    if move_on_import_removal?(protocol) do
      maybe_remove_client(protocol, download_id, Keyword.get(opts, :fence))
      best_effort_delete_source(content_path)
    end

    :ok
  end

  @doc "Whether `remove_after_import/4` will attempt anything for `protocol` right now."
  def move_on_import_removal?(protocol),
    do: protocol == :usenet and Application.get_env(:cinder, :move_on_import, false)

  defp maybe_remove_client(_protocol, download_id, _fence) when download_id in [nil, ""], do: :ok

  defp maybe_remove_client(protocol, download_id, {:movie, movie}) do
    case Download.fence_movie_cleanup(movie, expect_remote_id: download_id) do
      :mismatch -> fallback_remove(protocol, download_id, "movie #{movie.id}")
      intent_ids -> Download.cleanup_intents(intent_ids)
    end
  end

  defp maybe_remove_client(protocol, download_id, {:episode, episode_ids, spec}) do
    case Download.fence_episode_cleanup(episode_ids, [spec], expect_remote_id: download_id) do
      :mismatch -> fallback_remove(protocol, download_id, "episodes #{inspect(episode_ids)}")
      intent_ids -> Download.cleanup_intents(intent_ids)
    end
  end

  defp maybe_remove_client(protocol, download_id, nil), do: fallback_remove(protocol, download_id)

  # A conflicting intent (a concurrent re-grab reserved this target/episode between the tick's
  # commit and this fence — see `Download.fence_movie_cleanup/2`'s `expect_remote_id` doc, and
  # `Download.fence_book_cleanup/1`'s unconditional version of the same guard) degrades to today's
  # pre-#415 one-shot removal instead of corrupting the new intent: no durable record for THIS
  # attempt, but nothing hijacked either. A logged `context` names what raced; the legacy
  # unfenced callers (`nil`, no durable owner to begin with) pass none. Public (not `defp`), though
  # only this module calls it today.
  @doc false
  def fallback_remove(protocol, download_id, context \\ nil) do
    if context do
      Logger.warning(
        "#{context}: a newer download intent already claims this target; falling back to a " <>
          "one-shot client removal for #{inspect(download_id)}"
      )
    end

    case Download.client_for(protocol) do
      {:ok, client} -> best_effort_remove(client, download_id)
      :error -> :ok
    end
  end

  @doc """
  Drops a book grab whose client job is done with: fences a durable `:cleanup_pending` intent
  and deletes the grab in one transaction (`Cinder.Download.fence_book_cleanup/1`), then makes
  the immediate best-effort removal. A transient removal failure survives as that intent for
  `Cinder.Download.reconcile_pending_intents/1`'s bounded retry (#398, #415).

  `:mismatch` (#536) means a concurrent grab already reserved a new intent for the same target,
  and fencing would hijack it: this degrades to a plain grab delete plus `fallback_remove/3`'s
  one-shot, undurable removal, so the race winner's intent is never touched. Returns `:ok` unless
  the fence's own database write raises.
  """
  @spec retire_book_grab(BookGrab.t()) :: :ok
  def retire_book_grab(%BookGrab{} = grab) do
    case Download.fence_book_cleanup(grab) do
      {:ok, intent_ids} ->
        Download.cleanup_intents(intent_ids)

      :mismatch ->
        Books.Grabs.delete(grab)

        fallback_remove(
          grab.download_protocol,
          grab.download_id,
          "book target #{grab.book_target_id}"
        )
    end

    :ok
  end

  @doc """
  Releases a book grab after its import committed. When `move_on_import` will remove anything
  (`move_on_import_removal?/1`), the grab is retired (`retire_book_grab/1`) and its download
  source deleted; otherwise it is deleted plain. The grab goes first either way: a crash between a
  content-path delete and the grab delete would leave a surviving grab whose payload is gone,
  which the next tick re-imports into `:enoent` until it holds a target that is genuinely
  available. Returns `:ok` unless a database write raises.
  """
  @spec release_imported_book_grab(BookGrab.t()) :: :ok
  def release_imported_book_grab(%BookGrab{} = grab) do
    if move_on_import_removal?(grab.download_protocol) do
      retire_book_grab(grab)
      best_effort_delete_source(grab.content_path)
    else
      Books.Grabs.delete(grab)
    end

    :ok
  end

  @doc "Deletes `content_path` best-effort. Shared by `remove_after_import/4` and the book path."
  def best_effort_delete_source(content_path) do
    case Library.delete_download_source(content_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "download source delete failed for #{inspect(content_path)}: #{inspect(reason)}"
        )

        :ok
    end
  catch
    kind, value ->
      Logger.warning(
        "download source delete raised for #{inspect(content_path)}: #{inspect({kind, value})}"
      )

      :ok
  end

  @doc """
  Removes a tracked client download best-effort: logs (and swallows) an `{:error,_}`
  return OR a raised/thrown client failure, always returning `:ok` so a misconfigured
  client can never block a removal or unwind a poller. Shared by `fallback_remove/3` and
  `Cinder.Download.Cleaner`.
  """
  def best_effort_remove(client, id) do
    case client.remove(id, delete_files: true) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("client remove failed for download #{inspect(id)}: #{inspect(reason)}")
        :ok
    end
  catch
    kind, value ->
      Logger.warning(
        "client remove raised for download #{inspect(id)}: #{inspect({kind, value})}"
      )

      :ok
  end
end
