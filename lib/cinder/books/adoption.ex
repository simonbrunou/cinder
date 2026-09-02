defmodule Cinder.Books.Adoption do
  @moduledoc """
  The write choke-point for adopting an already-resolved Bookshelf work into the books catalog —
  the only place B6 (the Readarr migration, `docs/plans/2026-09-01-books-b6-migration-and-cutover.md`
  §B6c) writes anything. Lives in the books domain namespace, mirroring `Cinder.Catalog.Adoption`'s
  own location and its relationship to `Cinder.Library.MigrationAdoption`: adoption of a resolved
  work into the catalog is books business logic triggered by a migration, not migration-namespace
  code of its own.

  ## Adopts in place — structurally, not as a runtime check

  `adopt_work/3` never calls `Cinder.Library.StageEngine` or any filesystem-mutating code at all —
  no hardlink, no copy, no rename, no delete. Every `book_files.path` is inserted exactly as
  Bookshelf reported it. This is what makes the migration's entire rollback plan
  ("re-enable Bookshelf from backup") sound: the source library is byte-identical before and after
  every adopt, because nothing here ever touches a source file's bytes or name.

  ## No nested transaction

  `Cinder.Books.import_resolution/1` is itself a `Repo.transaction` whose call graph reaches
  `Repo.rollback/1` on ordinary failures. Calling it from inside this module's own transaction
  would nest a second transaction/rollback boundary inside the first — exactly the failure
  `Cinder.Books.Files`'s own `arm_target/1` comment warns about ("aborts the ENCLOSING transaction
  too... turns a status mismatch into a poisoned connection rather than a handleable error"). So
  `adopt_work/3` calls the *non-transactional* folds `Books.import_work_in_tx/2` and
  `Books.stamp_identifier_in_tx/3` directly, inside its own transaction, never `import_resolution/1`
  itself.
  """

  import Ecto.Query

  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget, Files}
  alias Cinder.Repo

  @arm_statuses [:unmonitored, :monitored, :available]

  @doc """
  Adopts `files` onto `resolution`'s work's `:ebook` target, in one transaction.

  `resolution` is `Cinder.Books.Identity.resolve/1`'s own resolution shape
  (`%{work: Cinder.Books.Metadata.work(), provider: atom()}`) plus `:bookshelf_foreign_id` — the
  Bookshelf work's own foreign id (`Cinder.Library.MigrationSource.work/0`'s `foreign_id`,
  namespace-distinct from `resolution.work.foreign_id`, which is the *metadata provider's* own
  id). The Bookshelf id is stamped as a `"readarr"` `book_identifiers` row so the next preview's
  local-cache pass (`Cinder.Library.MigrationAdoption.Readarr.plan/2`) can skip this work without
  another network call.

  `files` is one or more `%{path:, size:, format:, edition_id:}` maps — one for the multi-format
  `preferred` choice, several for `all formats`; a plain (non-multi-format) `:ready` candidate
  always adopts exactly one.

  Steps, all inside one `Repo.transaction/2` (`mode: :immediate`, matching
  `Books.import_resolution/1`'s own write-lock-first convention):

  1. `Books.import_work_in_tx/2` then `Books.stamp_identifier_in_tx/3` fold the resolved work
     (and its author/editions) into the catalog and durably stamp the `"readarr"` identifier.
     Idempotent: safe to re-run against an already-imported work.
  2. `Books.ensure_target/2` get-or-creates the `:ebook` target.
  3. Refuses a grab in progress for that target (`{:error, :grab_in_progress}`) — the identical
     race `Cinder.Books.pause_target/1` (B5a) closes for the same reason: overwriting
     `book_targets.status` out from under an in-flight download orphans it.
  4. Refuses a `:held` target outright (`{:error, :target_held}`) — an operator's or the poller's
     more recent decision is never silently overridden.
  5. Inserts each file via `Cinder.Books.Files.insert_or_existing/2` — the same "same target, same
     path ⇒ replay success; a DIFFERENT target's path ⇒ real `{:error, :book_file_exists}`"
     idempotent insert `Files.record_import/3` already uses, reused unchanged rather than
     duplicated.
  6. A guarded status write to `:available`, accepting `#{inspect(@arm_statuses)}` as the starting
     status — deliberately wider than `Files.record_import/3`'s own `arm_target/1`
     (`[:monitored, :available]`): `ensure_target/2` creates a target at the schema default
     `:unmonitored`, which is what the overwhelming majority of migrated works actually are — a
     `[:monitored, :available]` guard would match zero rows and fail nearly every real adoption.
     `:held` is already refused by step 4, so it never reaches this write. Not
     `Books.transition_target/3`: its single-`expect:` `Repo.rollback` semantics do not compose
     with three acceptable starting statuses, and its broadcast would fire inside this transaction
     — the same two reasons `Files.record_import/3`'s own `arm_target/1` stays a module-local
     guarded write instead.
  7. Post-commit: `Books.broadcast/1` sends `{:book_target_updated, target}` — no new topic.

  Ordering note: steps 1–2 run before step 3's grab check, not after, unlike the plan prose's own
  step numbering — both orders are externally identical because the whole thing is one
  transaction (`Repo.rollback/1` on `:grab_in_progress` undoes the import too), and getting the
  target first is what step 3's query needs.
  """
  @spec adopt_work(map(), [map()], keyword()) ::
          {:ok, BookTarget.t()}
          | {:error,
             :grab_in_progress
             | :target_held
             | :book_file_exists
             | :stale_status
             | Ecto.Changeset.t()
             | term()}
  def adopt_work(resolution, files, _opts \\ [])
      when is_map(resolution) and is_list(files) and files != [] do
    Repo.transaction(
      fn ->
        with {:ok, work} <- do_import(resolution),
             {:ok, target} <- Books.ensure_target(work, :ebook),
             :ok <- refuse_grab_in_progress(target),
             :ok <- refuse_held(target),
             :ok <- insert_files(target, files),
             {:ok, armed} <- arm_available(target) do
          armed
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
    |> publish()
  end

  defp do_import(%{work: work, provider: provider, bookshelf_foreign_id: foreign_id}) do
    cinder_work = Books.import_work_in_tx(work, to_string(provider))

    case Books.stamp_identifier_in_tx(cinder_work, "readarr", foreign_id) do
      {:ok, _identifier} -> {:ok, cinder_work}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp refuse_grab_in_progress(%BookTarget{id: id}) do
    if Repo.exists?(from g in BookGrab, where: g.book_target_id == ^id),
      do: {:error, :grab_in_progress},
      else: :ok
  end

  defp refuse_held(%BookTarget{status: :held}), do: {:error, :target_held}
  defp refuse_held(%BookTarget{}), do: :ok

  defp insert_files(target, files) do
    Enum.reduce_while(files, :ok, fn attrs, :ok ->
      case Files.insert_or_existing(target, attrs) do
        {:ok, _file} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp arm_available(%BookTarget{id: id}) do
    now = DateTime.utc_now(:second)

    case Repo.update_all(
           from(t in BookTarget, where: t.id == ^id and t.status in ^@arm_statuses, select: t),
           set: [status: :available, hold_reason: nil, updated_at: now]
         ) do
      {1, [armed]} -> {:ok, armed}
      {0, _none} -> {:error, :stale_status}
    end
  end

  defp publish({:ok, target}) do
    Books.broadcast({:book_target_updated, target})
    {:ok, target}
  end

  defp publish(error), do: error
end
