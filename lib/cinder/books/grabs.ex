defmodule Cinder.Books.Grabs do
  @moduledoc """
  The write choke-point for `book_grabs` — the in-flight download row of one book target.

  Every mutation of a book grab lives here, mirroring what `Cinder.Catalog.Grabs` does for video
  grabs, so `Cinder.Download.BookPoller` and `Cinder.Download` hold no `Repo` writes of their own
  (AGENTS.md). The rows are transient state, not catalog state, so — unlike a target transition —
  none of these broadcast: the target's own status write is what open views react to.
  """
  import Ecto.Query

  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Repo

  @doc """
  Creates the in-flight grab row for a target.

  Returns `{:error, :book_grab_exists}` when the target already has one — the unique
  `book_target_id` index is what makes a repeated poll tick unable to double-grab, so a conflict
  is an expected outcome to report, not an exception to raise.
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
    if Keyword.has_key?(errors, :book_target_id), do: :book_grab_exists, else: changeset
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

  @doc "Stores the transfer metrics reported by the download client."
  @spec track(BookGrab.t(), map()) :: {:ok, BookGrab.t()} | {:error, Ecto.Changeset.t()}
  def track(%BookGrab{} = grab, attrs) do
    grab
    |> BookGrab.changeset(Map.take(attrs, [:download_progress, :download_speed, :download_eta]))
    |> Repo.update()
  end

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
