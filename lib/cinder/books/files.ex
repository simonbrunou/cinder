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
           {:ok, file} <- insert_or_existing(target, attrs, replace?),
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

  @doc """
  Records N imported assets — a multi-track audiobook set — for one target and moves it to
  `:available` in one transaction. The multi-file generalization of `record_import/3`; see its
  own moduledoc for the shared "record and arm together, broadcast once after commit" invariants,
  which this function reuses unchanged (`publish/2` below is the SAME private function
  `record_import/3` already calls — it is generic over one file or a list of them).

  `opts[:replace]` (default `false`) is a confirmed "Find a better match" import, generalized to
  `maybe_supersede_set/3` below — see its own docs for the exact multi-file algorithm this is not
  a naive "run `maybe_supersede/3` once against the whole incoming path set".
  """
  @spec record_import_set(BookTarget.t(), [map()], keyword()) ::
          {:ok, [BookFile.t()]}
          | {:ok, [BookFile.t()], [String.t()]}
          | {:error, :stale_status | :book_file_exists | Ecto.Changeset.t()}
  def record_import_set(%BookTarget{} = target, attrs_list, opts \\ []) do
    stage_ids = Keyword.get(opts, :import_stage_ids, [])
    replace? = Keyword.get(opts, :replace, false)

    Repo.transaction(fn ->
      with {:ok, superseded} <- maybe_supersede_set(target, attrs_list, replace?),
           {:ok, files} <- insert_all_or_existing(target, attrs_list),
           {:ok, _armed} <- arm_target(target) do
        # Same ordering reason `record_import/3` documents: inside the transaction, and last.
        ImportStage.mark_committed!(stage_ids)
        {files, superseded}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> publish(target, replace?)
  end

  defp insert_all_or_existing(target, attrs_list) do
    attrs_list
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      case insert_or_existing(target, attrs) do
        {:ok, file} -> {:cont, {:ok, [file | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_supersede_set(_target, _attrs_list, false), do: {:ok, []}

  defp maybe_supersede_set(%BookTarget{id: id}, attrs_list, true) do
    existing = Repo.all(from f in BookFile, where: f.book_target_id == ^id)
    existing_paths = MapSet.new(existing, & &1.path)
    incoming_paths = MapSet.new(attrs_list, & &1.path)

    if MapSet.equal?(existing_paths, incoming_paths) do
      # Every incoming path is already this target's own current row, and the target has no path
      # the incoming set lacks — a full replay of an already-completed replace (the staging step
      # already found each track's destination hardlinked to itself and made no filesystem
      # change). Delete nothing; `insert_or_existing/2` per track below hits the same unique-path
      # conflict `insert_conflict/3` already treats as a no-op success, N times.
      {:ok, []}
    else
      # ANY difference — disjoint, subset, superset, or partial overlap — deletes every existing
      # row unconditionally, including one whose path IS reused by the incoming set: that row's
      # bytes were already overwritten in place by the staging layer's backup-swap, so its OLD
      # row (size, format, duration, track/disc metadata) would otherwise describe bytes that no
      # longer exist at that path. Deleting it and letting the insert step recreate it fresh keeps
      # metadata correct for reused paths, not merely "not wrong".
      #
      # Only paths NOT present in the incoming set are returned as `superseded_paths` for
      # post-commit disk unlink — a REUSED path's disk bytes are already the new content (landed
      # by the backup-swap); unlinking it would delete the file this same import just staged. An
      # orphaned path (an old track whose slot the new release doesn't reuse — e.g. the new
      # release has fewer tracks) has no landed replacement and is the only case whose bytes must
      # actually be removed from disk.
      Repo.delete_all(from f in BookFile, where: f.book_target_id == ^id)
      {:ok, MapSet.difference(existing_paths, incoming_paths) |> MapSet.to_list()}
    end
  end

  @doc false
  # Shared with `Cinder.Books.Adoption.adopt_work/3` (B6c) — a duplicate `book_files.path` is
  # only a conflict when the row belongs to a DIFFERENT target; when it is the SAME target's own
  # row (a retried adopt, or a crash/replay), the write already succeeded and this call is
  # replaying it. See `insert_conflict/4` below for exactly which case is which. Public and
  # `@doc false` (not private) so B6c's own transaction can reuse this unchanged rather than
  # duplicating it — the plan's own explicit instruction. B6c never confirms a replacement, so it
  # relies on the `replace?` default (`false`) and gets today's unchanged "return the existing
  # row" behavior.
  @spec insert_or_existing(BookTarget.t(), map(), boolean()) ::
          {:ok, BookFile.t()} | {:error, term()}
  def insert_or_existing(%BookTarget{} = target, attrs, replace? \\ false) do
    %BookFile{}
    |> BookFile.changeset(Map.put(attrs, :book_target_id, target.id))
    |> Repo.insert()
    |> case do
      {:ok, file} -> {:ok, file}
      {:error, changeset} -> insert_conflict(target, attrs, changeset, replace?)
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
  #
  # `replace?` decides whether the existing row is returned as-is or updated with `attrs`. Path
  # equality alone cannot tell a true replay (the file at this path never changed) from a
  # confirmed "Find a better match" replacement that happens to land on the same basename
  # (`StageEngine.stage_book_place/4`'s backup-swap already overwrote the bytes at this exact
  # path — issue #500): the caller already knows which one this is (it is the same `replace?`
  # that told `StageEngine` whether to perform the swap), so it is threaded straight through
  # rather than re-derived from a fresh `File.stat/1` here. `attrs` already carries the truth of
  # what is currently on disk either way (`BookImport.recorded_size/3` re-stats the actual
  # destination when nothing was staged), so updating on every confirmed-replace conflict is safe
  # for a genuine replay too — the update just writes back the same values.
  defp insert_conflict(target, attrs, changeset, replace?) do
    with true <- Keyword.has_key?(changeset.errors, :path),
         %BookFile{book_target_id: owner} = existing <- Repo.get_by(BookFile, path: attrs.path),
         true <- owner == target.id do
      if replace?, do: update_existing(existing, attrs), else: {:ok, existing}
    else
      _different_owner_or_other_error -> {:error, insert_reason(changeset)}
    end
  end

  defp update_existing(%BookFile{} = existing, attrs) do
    existing
    |> BookFile.changeset(attrs)
    |> Repo.update()
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
  #
  # `audiobookshelf_scanned_at` is reset to `nil` on every fresh `:available`-transition of an
  # AUDIOBOOK target only (B7c) — the signal "this target's on-disk content changed and
  # Audiobookshelf has not been told." This covers both a first import (already nil, so this is a
  # no-op) and a REPLACE (content genuinely changed under an existing path, so a stale "already
  # scanned" timestamp must not survive it). An e-book target's `media_kind` never matches, so
  # its (unused) column stays exactly as it already was — nil forever, nothing to reset.
  defp arm_target(%BookTarget{id: id, media_kind: media_kind}) do
    now = DateTime.utc_now(:second)

    scan_reset =
      if media_kind == :audiobook, do: [audiobookshelf_scanned_at: nil], else: []

    case Repo.update_all(
           from(t in BookTarget,
             where: t.id == ^id and t.status in [:monitored, :available],
             select: t
           ),
           set: [status: :available, hold_reason: nil, updated_at: now] ++ scan_reset
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
