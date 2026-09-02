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

  @doc """
  Records an imported asset and moves its target to `:available` in one transaction.

  The target write is guarded on it still being `:monitored`, so a target an operator unmonitored
  or held mid-import does not get silently re-armed by a late-landing import; the caller gets
  `{:error, :stale_status}` and the placement is rolled back by its own `ImportStage` journal.

  `opts[:replace]` (default `false`) is a confirmed "Find a better match" import: before the new
  file is inserted, every OTHER `book_files` row already on the target is deleted so the target
  ends up with exactly one current file, and the return becomes `{:ok, file, superseded_paths}`
  so the caller can best-effort unlink the old bytes from disk, post-commit.

  Replay-safe by construction: when the incoming `path` is already one of the target's own rows
  (a crash/replay re-running an already-committed replace), nothing is deleted — the row stays,
  and `insert_or_existing/2` hits the same unique-path conflict `insert_conflict/3` already treats
  as a no-op success. Only a GENUINELY different existing row is ever removed.
  """
  @spec record_import(BookTarget.t(), map(), keyword()) ::
          {:ok, BookFile.t()}
          | {:ok, BookFile.t(), [String.t()]}
          | {:error, :stale_status | :book_file_exists | Ecto.Changeset.t()}
  def record_import(%BookTarget{} = target, attrs, opts \\ []) do
    stage_ids = Keyword.get(opts, :import_stage_ids, [])
    replace? = Keyword.get(opts, :replace, false)

    Repo.transaction(fn ->
      with {:ok, superseded} <- maybe_supersede(target, attrs, replace?),
           {:ok, file} <- insert_or_existing(target, attrs),
           {:ok, _armed} <- arm_target(target) do
        # Inside the transaction, and last: `mark_committed!/1` rolls back on a stage that is no
        # longer `:prepared`, so a journal another process already reconciled aborts the catalog
        # write instead of leaving a file row pointing at bytes that got rolled back.
        ImportStage.mark_committed!(stage_ids)
        {file, superseded}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> publish(target, replace?)
  end

  defp maybe_supersede(_target, _attrs, false), do: {:ok, []}

  defp maybe_supersede(%BookTarget{id: id}, %{path: path}, true) do
    existing = Repo.all(from f in BookFile, where: f.book_target_id == ^id)

    if Enum.any?(existing, &(&1.path == path)) do
      # The incoming file is already this target's own row — a replay of an already-completed
      # replace. Deleting nothing here means `insert_file/2` below hits the same unique-path
      # conflict `insert_conflict/3` already treats as a no-op success, converging exactly like
      # a plain (non-replace) replay does today.
      {:ok, []}
    else
      Repo.delete_all(from f in BookFile, where: f.book_target_id == ^id)
      {:ok, Enum.map(existing, & &1.path)}
    end
  end

  @doc false
  # Shared with `Cinder.Books.Adoption.adopt_work/3` (B6c) — a duplicate `book_files.path` is
  # only a conflict when the row belongs to a DIFFERENT target; when it is the SAME target's own
  # row (a retried adopt, or a crash/replay), the write already succeeded and this call is
  # replaying it. See `insert_conflict/3` below for exactly which case is which. Public and
  # `@doc false` (not private) so B6c's own transaction can reuse this unchanged rather than
  # duplicating it — the plan's own explicit instruction.
  @spec insert_or_existing(BookTarget.t(), map()) :: {:ok, BookFile.t()} | {:error, term()}
  def insert_or_existing(%BookTarget{} = target, attrs) do
    %BookFile{}
    |> BookFile.changeset(Map.put(attrs, :book_target_id, target.id))
    |> Repo.insert()
    |> case do
      {:ok, file} -> {:ok, file}
      {:error, changeset} -> insert_conflict(target, attrs, changeset)
    end
  end

  # A duplicate `book_files.path` is only a conflict when the row belongs to a DIFFERENT target.
  #
  # When it is this target's own row, the import already succeeded and is being replayed — a
  # crash or a swallowed error between the commit and the grab delete leaves the grab with its
  # `content_path`, and the next tick re-imports the same source to the same destination.
  # Returning `:book_file_exists` there parked a target that is genuinely `:available`, with its
  # file on disk and in the catalog, at `:held`. Treating the replay as success is what makes the
  # import idempotent one layer above `StageEngine`'s same-inode branch.
  defp insert_conflict(target, attrs, changeset) do
    with true <- Keyword.has_key?(changeset.errors, :path),
         %BookFile{book_target_id: owner} = existing <- Repo.get_by(BookFile, path: attrs.path),
         true <- owner == target.id do
      {:ok, existing}
    else
      _different_owner_or_other_error -> {:error, insert_reason(changeset)}
    end
  end

  defp insert_reason(%Ecto.Changeset{errors: errors} = changeset) do
    if Keyword.has_key?(errors, :path), do: :book_file_exists, else: changeset
  end

  # The guarded target write, inline rather than through `Books.transition_target/3`.
  #
  # Two reasons, and the second is load-bearing. First, that function broadcasts on success, and a
  # broadcast inside this transaction would announce a state a rollback can still undo —
  # `publish/2` below sends it once, after commit. Second, and why `publish: false` is not enough:
  # `BookTargetTransition.guarded/4` implements its guard with `Repo.rollback(:stale_status)`
  # inside its own `Repo.transaction`, which aborts the ENCLOSING transaction too (its own
  # comments say exactly this — "the only safe response to this error is to roll that transaction
  # back"). Calling it here turns a status mismatch into a poisoned connection rather than a
  # handleable error, and this function must be able to accept a second status.
  #
  # `:available` is accepted alongside `:monitored` so an import REPLAY (see `insert_conflict/3`)
  # converges: the target is already in the state this write wants, and demanding `:monitored`
  # there is what turned a replay into a `:held` demotion. An unmonitored or held target still
  # refuses — those are an operator's more recent decision.
  #
  # The `book_targets_profile_integrity` trigger cannot fire here: it guards `profile_id` and
  # `media_kind`, and neither is in the `set`.
  defp arm_target(%BookTarget{id: id}) do
    now = DateTime.utc_now(:second)

    case Repo.update_all(
           from(t in BookTarget,
             where: t.id == ^id and t.status in [:monitored, :available],
             select: t
           ),
           set: [status: :available, hold_reason: nil, updated_at: now]
         ) do
      {1, [armed]} -> {:ok, armed}
      {0, _none} -> {:error, :stale_status}
    end
  end

  defp publish({:ok, {file, superseded}}, %BookTarget{id: id}, replace?) do
    case Repo.get(BookTarget, id) do
      nil -> :ok
      armed -> Books.broadcast({:book_target_updated, armed})
    end

    if replace?, do: {:ok, file, superseded}, else: {:ok, file}
  end

  defp publish({:error, reason}, _target, _replace?), do: {:error, reason}
end
