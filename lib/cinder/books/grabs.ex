defmodule Cinder.Books.Grabs do
  @moduledoc """
  The write choke-point for `book_grabs` — the in-flight download row of one book target.

  Every mutation of a book grab lives here, mirroring what `Cinder.Catalog.Grabs` does for video
  grabs, so `Cinder.Download.BookPoller` and `Cinder.Download` hold no `Repo` writes of their own
  (AGENTS.md). Most of these are transient state changes with no broadcast of their own: `create`,
  `mark_downloaded`, `bump_attempts`, and `delete` all sit alongside a `book_targets` status write
  elsewhere in the same pipeline step, and it is that target broadcast an open view reacts to.
  `track/2` is the one exception — a progress tick has no accompanying status change to piggyback
  on, so it broadcasts for itself; see its own doc.
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
  """
  @spec create(integer(), String.t(), atom(), String.t() | nil) ::
          {:ok, BookGrab.t()} | {:error, :book_grab_exists | Ecto.Changeset.t()}
  def create(book_target_id, download_id, protocol, release_title) do
    %BookGrab{}
    |> BookGrab.changeset(%{
      book_target_id: book_target_id,
      download_id: download_id,
      download_protocol: protocol,
      release_title: release_title
    })
    |> Repo.insert()
    |> case do
      {:ok, grab} -> {:ok, grab}
      {:error, changeset} -> {:error, conflict_reason(changeset)}
    end
  rescue
    Ecto.ConstraintError -> {:error, :book_grab_exists}
  end

  defp conflict_reason(%Ecto.Changeset{errors: errors} = changeset) do
    if Keyword.has_key?(errors, :book_target_id) or Keyword.has_key?(errors, :download_id),
      do: :book_grab_exists,
      else: changeset
  end

  @doc "The grab for a target, or nil."
  @spec for_target(integer()) :: BookGrab.t() | nil
  def for_target(book_target_id), do: Repo.get_by(BookGrab, book_target_id: book_target_id)

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

  @doc "Deletes a grab. Idempotent: an already-deleted row is `:ok`."
  @spec delete(BookGrab.t()) :: :ok
  def delete(%BookGrab{id: id}) do
    Repo.delete_all(from g in BookGrab, where: g.id == ^id)
    :ok
  end
end
