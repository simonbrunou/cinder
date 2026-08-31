defmodule Cinder.Books.Files do
  @moduledoc """
  The write choke-point for `book_files` — the imported assets of a book target.

  Recording the file and arming the target are one transaction: a committed file whose target
  stayed `:monitored` would be re-grabbed on the next sweep, and an `:available` target with no
  file row would report a library it does not have. The target broadcast is sent **after** the
  commit, never inside it (AGENTS.md), so no open view can observe a write a rollback could still
  undo.
  """
  import Ecto.Query

  alias Cinder.Books
  alias Cinder.Books.{BookFile, BookTarget}
  alias Cinder.Library.ImportStage
  alias Cinder.Repo

  @doc "The recorded files of a target, oldest first."
  @spec for_target(integer()) :: [BookFile.t()]
  def for_target(book_target_id),
    do: Repo.all(from f in BookFile, where: f.book_target_id == ^book_target_id, order_by: f.id)

  @doc """
  Records an imported asset and moves its target to `:available` in one transaction.

  The target write is guarded on it still being `:monitored`, so a target an operator unmonitored
  or held mid-import does not get silently re-armed by a late-landing import; the caller gets
  `{:error, :stale_status}` and the placement is rolled back by its own `ImportStage` journal.
  """
  @spec record_import(BookTarget.t(), map(), keyword()) ::
          {:ok, BookFile.t()} | {:error, :stale_status | :book_file_exists | Ecto.Changeset.t()}
  def record_import(%BookTarget{} = target, attrs, opts \\ []) do
    stage_ids = Keyword.get(opts, :import_stage_ids, [])

    Repo.transaction(fn ->
      with {:ok, file} <- insert_file(target, attrs),
           {:ok, _armed} <- arm_target(target) do
        # Inside the transaction, and last: `mark_committed!/1` rolls back on a stage that is no
        # longer `:prepared`, so a journal another process already reconciled aborts the catalog
        # write instead of leaving a file row pointing at bytes that got rolled back.
        ImportStage.mark_committed!(stage_ids)
        file
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> publish(target)
  end

  defp insert_file(target, attrs) do
    %BookFile{}
    |> BookFile.changeset(Map.put(attrs, :book_target_id, target.id))
    |> Repo.insert()
    |> case do
      {:ok, file} -> {:ok, file}
      {:error, changeset} -> {:error, insert_reason(changeset)}
    end
  end

  defp insert_reason(%Ecto.Changeset{errors: errors} = changeset) do
    if Keyword.has_key?(errors, :path), do: :book_file_exists, else: changeset
  end

  # The guarded target write, inline rather than through `Books.transition_target/3`: that
  # function broadcasts on success, and a broadcast inside this transaction would announce a state
  # a rollback can still undo. `publish/2` below sends it once, after commit.
  defp arm_target(%BookTarget{id: id}) do
    now = DateTime.utc_now(:second)

    case Repo.update_all(
           from(t in BookTarget,
             where: t.id == ^id and t.status == :monitored,
             select: t
           ),
           set: [status: :available, hold_reason: nil, updated_at: now]
         ) do
      {1, [armed]} -> {:ok, armed}
      {0, _none} -> {:error, :stale_status}
    end
  end

  defp publish({:ok, file}, %BookTarget{id: id}) do
    case Repo.get(BookTarget, id) do
      nil -> :ok
      armed -> Books.broadcast({:book_target_updated, armed})
    end

    {:ok, file}
  end

  defp publish({:error, reason}, _target), do: {:error, reason}
end
