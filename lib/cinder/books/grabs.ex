defmodule Cinder.Books.Grabs do
  @moduledoc """
  The write choke-point for `book_grabs` — the in-flight download row of one book target.

  Every mutation of a book grab lives here, mirroring what `Cinder.Catalog.Grabs` does for video
  grabs, so `Cinder.Download.BookPoller` and `Cinder.Download` hold no `Repo` writes of their own
  (AGENTS.md). `create`, `mark_downloaded`, and `bump_attempts` are transient state changes with
  no broadcast of their own: each sits alongside a `book_targets` status write elsewhere in the
  same pipeline step, and it is that target broadcast an open view reacts to. `track/2` and
  `delete/1` both broadcast for themselves: a progress tick has no accompanying status change to
  piggyback on, and a delete can trail its target's own terminal broadcast by enough to lose the
  race — an open `/books/:id` that already re-read the grab before the delete committed would
  otherwise never learn it is gone; see each function's own doc.
  """
  import Ecto.Query

  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Repo

  @doc """
  Creates the in-flight grab row for a target.

  Returns `{:error, :book_grab_exists}` when the target already has one, or when the remote
  download is already owned by another target's grab — the two unique indexes are what make a
  repeated poll tick unable to double-grab and two targets unable to adopt one remote job, so a
  conflict is an expected outcome to report, not an exception to raise.

  `opts[:replace]` (default `false`) marks this grab as a confirmed "Find a better match"
  replace rather than a fresh acquisition — `BookPoller` reads it back off the grab at import
  time to decide whether the target's existing file should be superseded.
  """
  @spec create(integer(), String.t(), atom(), String.t() | nil, keyword()) ::
          {:ok, BookGrab.t()} | {:error, :book_grab_exists | Ecto.Changeset.t()}
  def create(book_target_id, download_id, protocol, release_title, opts \\ []) do
    %BookGrab{}
    |> BookGrab.changeset(%{
      book_target_id: book_target_id,
      download_id: download_id,
      download_protocol: protocol,
      release_title: release_title,
      replace: Keyword.get(opts, :replace, false)
    })
    |> Repo.insert()
    |> case do
      {:ok, grab} -> {:ok, grab}
      {:error, changeset} -> {:error, conflict_reason(changeset)}
    end
    |> log_duplicate(book_target_id, download_id, protocol, release_title)
  rescue
    Ecto.ConstraintError ->
      log_duplicate(
        {:error, :book_grab_exists},
        book_target_id,
        download_id,
        protocol,
        release_title
      )
  end

  defp conflict_reason(%Ecto.Changeset{errors: errors} = changeset) do
    if Keyword.has_key?(errors, :book_target_id) or Keyword.has_key?(errors, :download_id),
      do: :book_grab_exists,
      else: changeset
  end

  # Best-effort, additive only — the refusal itself is unchanged by this log.
  defp log_duplicate(
         {:error, :book_grab_exists} = error,
         book_target_id,
         download_id,
         protocol,
         release_title
       ) do
    Books.log_duplicate_grab_refused(
      book_target_id,
      duplicate_detail(download_id, protocol, release_title)
    )

    error
  end

  defp log_duplicate(result, _book_target_id, _download_id, _protocol, _release_title), do: result

  defp duplicate_detail(download_id, protocol, nil), do: "#{protocol} download #{download_id}"

  defp duplicate_detail(_download_id, protocol, release_title),
    do: "#{release_title} (#{protocol})"

  @doc "The grab for a target, or nil."
  @spec for_target(integer()) :: BookGrab.t() | nil
  def for_target(book_target_id), do: Repo.get_by(BookGrab, book_target_id: book_target_id)

  @doc """
  `book_target_id`s with a live grab, as a `MapSet` — the `/library` books tab's Pause-button
  gate, batched into one query instead of one `for_target/1` call per rendered row.
  """
  @spec target_ids_in_progress() :: MapSet.t(integer())
  def target_ids_in_progress,
    do: Repo.all(from g in BookGrab, select: g.book_target_id) |> MapSet.new()

  @doc "The grab carrying `download_id` on `protocol`, or nil."
  @spec by_download(String.t(), atom()) :: BookGrab.t() | nil
  def by_download(download_id, protocol),
    do: Repo.get_by(BookGrab, download_id: download_id, download_protocol: protocol)

  @doc "Grabs still downloading (no `content_path`), with their targets preloaded."
  @spec list_downloading() :: [BookGrab.t()]
  def list_downloading do
    Repo.all(
      from g in BookGrab,
        where: is_nil(g.content_path),
        order_by: [asc: g.id],
        preload: [book_target: ^target_preload()]
    )
  end

  @doc "Grabs whose download completed and whose payload is ready to import."
  @spec list_downloaded() :: [BookGrab.t()]
  def list_downloaded do
    Repo.all(
      from g in BookGrab,
        where: not is_nil(g.content_path),
        order_by: [asc: g.id],
        preload: [book_target: ^target_preload()]
    )
  end

  # The importer names the destination from the catalog, never from the release, so the work and
  # its author credits have to travel with the grab.
  defp target_preload,
    do: from(t in BookTarget, preload: [work: [credits: :author]])

  @doc """
  Records a completed download's `content_path`.

  Guarded on the path still being unset so two ticks racing on one grab produce one write; the
  loser gets `{:error, :stale_book_grab}` and re-derives next tick.
  """
  @spec mark_downloaded(BookGrab.t(), String.t()) ::
          {:ok, BookGrab.t()} | {:error, :stale_book_grab}
  def mark_downloaded(%BookGrab{id: id}, content_path) when is_binary(content_path) do
    now = DateTime.utc_now(:second)

    case Repo.update_all(
           from(g in BookGrab, where: g.id == ^id and is_nil(g.content_path), select: g),
           set: [
             content_path: content_path,
             import_attempts: 0,
             download_progress_at: now,
             updated_at: now
           ]
         ) do
      {1, [grab]} -> {:ok, grab}
      {0, _none} -> {:error, :stale_book_grab}
    end
  end

  @doc """
  Stores the transfer metrics reported by the download client, and broadcasts `{:book_grab_updated,
  grab}` when they actually changed.

  Guarded the same way `Cinder.Catalog.Grabs.update_grab_download_metrics/2` guards its own write
  and broadcast:

    * the write only lands while `content_path` is still unset — a metrics report for a grab the
      import phase already claimed (`mark_downloaded/2` beat this tick to it) is stale and
      refused with `{:error, :stale_grab}`, never landed on a completed download;
    * a regressed `download_progress` is dropped from the write, not recorded — a client that
      briefly under-reports must never walk the operator-visible bar backwards;
    * `download_progress_at` advances only on real forward motion, so a poller tick that
      re-reports an identical snapshot writes and broadcasts nothing, and an open `/books/:id` is
      not re-rendered on a no-op. (The completion edge — `content_path` going from unset to
      set — is `mark_downloaded/2`'s to advance, not this function's: `track/2`'s own
      `is_nil(content_path)` guard above means it never runs again once a grab is downloaded.)
  """
  @spec track(BookGrab.t(), map()) :: {:ok, BookGrab.t()} | {:error, :stale_grab}
  def track(%BookGrab{} = grab, attrs) do
    changes = metric_changes(grab, attrs)

    if changes == %{} do
      if Repo.exists?(from(g in BookGrab, where: g.id == ^grab.id and is_nil(g.content_path))) do
        {:ok, grab}
      else
        {:error, :stale_grab}
      end
    else
      now = DateTime.utc_now(:second)

      changes =
        if progress_advanced?(grab.download_progress, Map.get(changes, :download_progress)),
          do: Map.put(changes, :download_progress_at, now),
          else: changes

      case Repo.update_all(
             from(g in BookGrab,
               where: g.id == ^grab.id and is_nil(g.content_path),
               select: g
             ),
             set: Map.to_list(changes) ++ [updated_at: now]
           ) do
        {1, [updated]} ->
          Books.broadcast({:book_grab_updated, updated})
          {:ok, updated}

        {0, _none} ->
          {:error, :stale_grab}
      end
    end
  end

  defp metric_changes(grab, attrs) do
    attrs
    |> Map.take([:download_progress, :download_speed, :download_eta])
    |> keep_progress_high_water(grab.download_progress)
    |> Enum.reject(fn {field, value} -> Map.get(grab, field) == value end)
    |> Map.new()
  end

  defp keep_progress_high_water(%{download_progress: progress} = attrs, previous)
       when is_number(progress) and (is_nil(previous) or progress >= previous),
       do: attrs

  defp keep_progress_high_water(attrs, _previous), do: Map.delete(attrs, :download_progress)

  defp progress_advanced?(previous, current) when is_number(current),
    do: current > (previous || 0)

  defp progress_advanced?(_previous, _current), do: false

  @doc "Bumps the shared download-phase failure budget."
  @spec bump_attempts(BookGrab.t(), non_neg_integer()) ::
          {:ok, BookGrab.t()} | {:error, Ecto.Changeset.t()}
  def bump_attempts(%BookGrab{} = grab, attempts) do
    grab
    |> BookGrab.changeset(%{
      import_attempts: attempts,
      download_speed: nil,
      download_eta: nil
    })
    |> Repo.update()
  end

  @doc """
  Deletes a grab, then broadcasts `{:book_grab_deleted, book_target_id}`. Idempotent: an
  already-deleted row is `:ok`.

  Every call site here writes its target's terminal status (`:available` or `:held`) and
  broadcasts `{:book_target_updated, target}` *before* calling this — `Cinder.Books.Files.record_import/3`
  and `Cinder.Books.hold_target/2` each commit and publish on their own. An open `/books/:id` is a
  different process with no serialization against this subsequent write, so it can re-read
  `Cinder.Books.Grabs.for_target/1` between that broadcast and this delete and repopulate its
  in-flight badge with a grab that is about to vanish, with no further poller tick ever coming to
  correct it. This broadcast is the correction: it fires after the row is gone, so a view that
  lost the earlier race still gets a second, authoritative message telling it to drop the grab.

  For a caller with NO enclosing transaction (every call site above), the row is already durably
  gone by the time this function's own `Repo.delete_all` returns, so broadcasting immediately
  after is already "after commit." A caller that DOES own an enclosing transaction must use
  `delete_only/1` instead and broadcast itself once that outer transaction commits — see its doc.
  """
  @spec delete(BookGrab.t()) :: :ok
  def delete(%BookGrab{book_target_id: book_target_id} = grab) do
    delete_only(grab)
    Books.broadcast({:book_grab_deleted, book_target_id})
    :ok
  end

  @doc """
  Deletes a grab WITHOUT broadcasting — for `Cinder.Download.fence_book_cleanup/1`, the one
  caller that deletes the grab inside its OWN enclosing `Repo.transaction` (alongside the
  durable cleanup fence). Broadcasting here would announce the grab gone before that outer
  transaction commits — a rolled-back fence would still have told every `/books/:id` the grab
  was deleted, and even a committed one risks a subscriber re-reading `Cinder.Books.Grabs.for_target/1`
  in the still-open window and seeing pre-delete state with no correction ever following (AGENTS.md:
  "one transition, one broadcast, emitted after commit"). The caller broadcasts
  `{:book_grab_deleted, book_target_id}` itself once `Repo.transaction/1` returns `{:ok, _}`.
  """
  @spec delete_only(BookGrab.t()) :: :ok
  def delete_only(%BookGrab{id: id}) do
    Repo.delete_all(from g in BookGrab, where: g.id == ^id)
    :ok
  end
end
