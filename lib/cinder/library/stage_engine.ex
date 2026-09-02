defmodule Cinder.Library.StageEngine do
  @moduledoc """
  The durable two-phase-commit filesystem staging engine `Cinder.Library` places
  every movie/episode file through: place a candidate (link-or-copy), land it at
  the destination, journal the operation (`Cinder.Library.ImportStage`) so a
  process crash mid-placement is recoverable, then commit or roll back. Carved
  out of `Cinder.Library` as plain code motion — every entry point below is
  called from `Cinder.Library` unchanged; the journal semantics, lock ordering,
  and identity checks are byte-for-byte what they were before the split.
  """
  require Logger

  alias Cinder.Library
  alias Cinder.Library.{BookSources, ImportStage}

  require Library

  # link(2) errnos that mean "this dest can't be hardlinked to" — fall back to an atomic byte copy
  # rather than parking. `:exdev` = source and dest on different mounts. `:eperm`/`:eopnotsupp`/
  # `:enotsup` = a single mount whose filesystem has no hardlink support at all (FAT/exFAT on USB
  # drives, SMB/CIFS without Unix extensions, some FUSE), where `link()` fails without `:exdev` ever
  # firing (issue #59). `:eperm` can also be a genuine permission error, but then the copy fails the
  # same way (`cp` can't open the dest) and the item still parks — a wasted copy attempt, not a
  # wrong import. Every other errno (`:enoent`, `:enospc`, …) is a real failure and propagates.
  @exclusive_copy_fallback_errnos [:eperm, :eopnotsupp, :enotsup]
  @video_exts ~w(.mkv .mp4 .avi .m4v .mov .wmv .ts)

  # Place source at dest; resolve a same-item collision (tmdb-unique folder => same record) by the
  # caller's `upgrade_fun` decision or a forced `replace?`. Shared by movie and episode imports.
  # `upgrade_fun` is a thunk so the (config-reading) upgrade comparison runs only on an actual
  # collision, not every import. `replace?` bypasses the upgrade gate entirely. Public (not
  # private): called from `Cinder.Library.place_episode_file/5`.
  @doc false
  def place(source, dest, root, {si, sdev}, record, new_q, replace?, upgrade_fun) do
    with {:ok, source} <- safe_source_file(source),
         {:ok, dest} <- safe_destination(dest, root),
         :ok <- normalize_import_directories(dest, root) do
      do_place(source, dest, root, {si, sdev}, record, new_q, replace?, upgrade_fun)
    end
  end

  defp do_place(source, dest, root, {si, sdev}, record, new_q, replace?, upgrade_fun) do
    case fs().ln(source, dest) do
      :ok ->
        {:ok, new_q, true}

      {:error, errno} when Library.copy_fallback_errno?(errno) ->
        # Fresh placement onto a filesystem that can't hardlink this source (cross-mount `:exdev`, or a
        # no-hardlink-support mount → `:eperm`/`:eopnotsupp`/`:enotsup`): copy the bytes in atomically
        # via replace/2 (link-or-copy into a unique temp on the dest fs, then rename). This is the
        # *fresh* case because on Linux (the deployment target) link(2) reports EEXIST before EXDEV/EPERM
        # (filename_create checks EEXIST before vfs_link), so a collision with an existing dest surfaces
        # as :eexist below and still runs the upgrade/keep gate — never an unconditional overwrite here.
        # The copy logs
        # at :info from link_or_copy/2 — the one choke-point both copy paths hit.
        with :ok <- Library.replace(source, dest, root), do: {:ok, new_q, true}

      {:error, :eexist} ->
        with {:ok, ^dest} <- safe_destination(dest, root),
             {:ok, %{inode: di, major_device: ddev}} <- fs().lstat(dest) do
          # Inode numbers are unique only within one filesystem, so an idempotency short-circuit must
          # also match the device — across filesystems two inodes can collide and would otherwise skip
          # a genuine upgrade. Same-fs hardlink fast path (sdev == ddev) is unchanged.
          same_inode? = si == di and sdev == ddev

          do_resolve(
            source,
            dest,
            same_inode?,
            replace? or upgrade_fun.(),
            record,
            new_q,
            replace?,
            root
          )
        end

      {:error, _} = err ->
        err
    end
  end

  # Same inode: the file is already in place (idempotent). Normally keep the recorded quality, but a
  # forced replace (e.g. manual re-import after a crash) must record the NEW quality. `placed?` is
  # false either way — no fresh bytes landed, so maybe_link_sidecars never re-scans; a fresh
  # (never-imported) record adopting an already-present file gets its sidecars scanned in
  # existing_quality/3 instead (issue #128).
  defp do_resolve(_source, dest, true, _upgrade, movie, new_q, replace?, _root),
    do: {:ok, if(replace?, do: new_q, else: Library.existing_quality(movie, new_q, dest)), false}

  defp do_resolve(source, dest, false, true, _movie, new_q, _replace?, root) do
    with :ok <- Library.replace(source, dest, root), do: {:ok, new_q, true}
  end

  defp do_resolve(_source, dest, false, false, movie, new_q, _replace?, _root),
    do: Library.keep(dest, movie, new_q)

  @doc """
  Stages a book file, using the same journal as `stage_place/8` with none of its quality logic.

  Separate from `stage_place/8` rather than a flag on it: that function's source gate is the
  video extension list, and its collision branches all resolve through `Library.existing_quality/3`
  and `Library.keep/3`, which read `imported_resolution`-style columns a book target does not
  have. A book collision needs no comparison at all when `opts[:replace]` is falsy — the parity
  contract parks automatic upgrades and format conversion for the first release, so an existing
  file at the destination is always kept.

  `opts`:
  - `:extensions` — the source/link-or-copy extension allow-list, default
    `BookSources.accepted_extensions()` (e-book). `Cinder.Library.AudiobookImport` passes
    `Cinder.Library.AudiobookSources.accepted_extensions()`; this is what makes the SAME staging
    function safe for both media kinds without a widened, e-book-only gate.
  - `:replace` — default `false` (today's actual behavior, byte-for-byte unchanged: a destination
    collision keeps the existing file). `true` is a confirmed "Find a better match" import: a
    destination collision performs a real, durable, backup-then-atomic-swap replacement — the
    SAME machinery `stage_replacement/4` already uses for a confirmed movie upgrade
    (`prepare_durable_stage/7` with `backup_source: dest`), not new code. A same-inode collision
    (the new bytes are already hardlinked at `dest` — a replay of an already-completed replace) is
    still the idempotent no-op either way: never a second backup-swap over content already
    swapped once.

  Returns `{:ok, rollback, placed?}`. `placed?` is false when the destination already held a
  file and nothing changed, so the caller can tell a fresh publication (or a real replace) from
  an adoption/replay.
  """
  @spec stage_book_place(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map(), boolean()} | {:error, term()}
  def stage_book_place(source, dest, root, opts \\ []) do
    extensions = Keyword.get(opts, :extensions, BookSources.accepted_extensions())
    replace? = Keyword.get(opts, :replace, false)

    with {:ok, source} <- safe_source_file(source, extensions),
         {:ok, dest} <- safe_destination(dest, root),
         :ok <- normalize_import_directories(dest, root) do
      ImportStage.with_destination_lock(dest, fn ->
        stage_book_place_locked(source, dest, root, extensions, replace?)
      end)
    end
  end

  defp stage_book_place_locked(source, dest, root, extensions, replace?) do
    case fs().lstat(dest) do
      {:error, :enoent} ->
        with {:ok, _quality, rollback, placed?} <-
               stage_new(source, dest, root, %{}, extensions),
             do: {:ok, rollback, placed?}

      # A REGULAR FILE already occupies the destination.
      #
      # - same inode+device ⇒ this exact file is already published (a re-run after a crash
      #   between placement and the catalog write, OR a replay of an already-completed replace),
      #   so the import is idempotent either way — never a second backup-swap over content
      #   already swapped once.
      # - a different file, `replace?: false` ⇒ the contract parks automatic upgrades and format
      #   conversion for the first release, so an operator's existing copy is never overwritten on
      #   the strength of a release name.
      # - a different file, `replace?: true` ⇒ a confirmed "Find a better match": real,
      #   backup-then-atomic-swap replacement below.
      #
      # Every branch but the real replacement journals a no-op so the caller's commit/rollback
      # path is uniform and reports `placed?: false` — no fresh bytes landed.
      {:ok, %File.Stat{type: :regular} = dest_stat} ->
        stage_book_collision(source, dest, root, dest_stat, extensions, replace?)

      # Anything else at the destination — a directory, a symlink, a device node — is not a book
      # this import can adopt. Recording it would put a `book_files` row (and an `:available`
      # target) behind a path that is not a readable book, and the consumer would find a
      # directory where the catalog promised a file. Refuse and let the target hold.
      {:ok, %File.Stat{type: type}} ->
        {:error, {:unexpected_destination_type, type}}

      {:error, _reason} = error ->
        error
    end
  end

  defp stage_book_collision(source, dest, root, dest_stat, extensions, replace?) do
    with {:ok, source_stat} <- fs().lstat(source) do
      if replace? and not same_file?(source_stat, dest_stat),
        do: stage_book_replace(source, dest, root, dest_stat, extensions),
        else: stage_book_keep(dest, root)
    end
  end

  defp stage_book_replace(source, dest, root, dest_stat, extensions) do
    with {:ok, _quality, rollback, placed?} <-
           prepare_durable_stage(source, dest, root, dest, dest_stat, %{}, extensions),
         do: {:ok, rollback, placed?}
  end

  defp stage_book_keep(dest, root) do
    with {:ok, _quality, rollback, placed?} <- stage_noop(dest, root, %{}),
         do: {:ok, rollback, placed?}
  end

  defp same_file?(%{inode: inode, major_device: device}, %{inode: inode, major_device: device}),
    do: true

  defp same_file?(_source_stat, _dest_stat), do: false

  @doc false
  def stage_place(source, dest, root, {si, sdev}, record, new_q, replace?, upgrade_fun) do
    with {:ok, source} <- safe_source_file(source),
         {:ok, dest} <- safe_destination(dest, root),
         :ok <- normalize_import_directories(dest, root) do
      # Lock ordering is always destination -> operation -> DB claim. The stable destination lock
      # serializes local staging decisions; the unique DB index extends exclusion across nodes.
      ImportStage.with_destination_lock(dest, fn ->
        stage_place_locked(
          source,
          dest,
          root,
          {si, sdev},
          record,
          new_q,
          replace?,
          upgrade_fun
        )
      end)
    end
  end

  defp normalize_import_directories(dest, root),
    do: normalize_directory_permissions(Path.dirname(dest), Path.expand(root))

  defp normalize_directory_permissions(root, root), do: :ok

  defp normalize_directory_permissions(path, root) do
    with :ok <- fs().chmod(path, 0o755),
         do: normalize_directory_permissions(Path.dirname(path), root)
  end

  defp stage_place_locked(source, dest, root, {si, sdev}, record, new_q, replace?, upgrade_fun) do
    case fs().lstat(dest) do
      {:error, :enoent} ->
        stage_new(source, dest, root, new_q)

      {:ok, %{inode: ^si, major_device: ^sdev}} ->
        quality = existing_quality_for_stage(record, new_q, replace?, dest)
        stage_noop(dest, root, quality)

      {:ok, stat} ->
        stage_existing(source, dest, root, stat, record, new_q, replace?, upgrade_fun)

      {:error, _} = error ->
        error
    end
  end

  defp stage_existing(source, dest, root, stat, record, new_q, replace?, upgrade_fun) do
    if replace? or upgrade_fun.() do
      stage_replacement(source, dest, root, stat, new_q)
    else
      {:ok, quality, false} = Library.keep(dest, record, new_q)
      stage_noop(dest, root, quality)
    end
  end

  defp existing_quality_for_stage(_record, new_q, true, _dest), do: new_q

  defp existing_quality_for_stage(record, new_q, false, dest),
    do: Library.existing_quality(record, new_q, dest)

  defp stage_new(source, dest, root, quality, extensions \\ @video_exts),
    do: prepare_durable_stage(source, dest, root, nil, nil, quality, extensions)

  defp stage_replacement(source, dest, root, original_stat, quality),
    do: prepare_durable_stage(source, dest, root, dest, original_stat, quality, @video_exts)

  defp stage_noop(dest, root, quality) do
    operation_key = Ecto.UUID.generate()

    ImportStage.with_lock(operation_key, fn ->
      case create_stage(%{
             operation_key: operation_key,
             state: :prepared,
             kind: :noop,
             next_attempt_at: ImportStage.handoff_deadline(),
             root: root,
             dest: dest,
             candidate: dest
           }) do
        {:ok, stage} -> {:ok, quality, durable_rollback(stage), false}
        {:error, _} = error -> error
      end
    end)
  end

  defp prepare_durable_stage(source, dest, root, backup_source, backup_stat, quality, extensions) do
    operation_key = Ecto.UUID.generate()
    candidate = stage_path(dest, operation_key)
    backup = if backup_source, do: rollback_path(dest, operation_key)

    ImportStage.with_lock(operation_key, fn ->
      attrs =
        Map.merge(
          %{
            operation_key: operation_key,
            root: root,
            dest: dest,
            candidate: candidate,
            backup: backup
          },
          identity_attrs(:backup, backup_stat)
        )

      case create_stage(attrs) do
        {:ok, stage} ->
          prepare_created_stage(stage, source, backup_source, quality, extensions)

        {:error, _} = error ->
          error
      end
    end)
  end

  defp prepare_created_stage(stage, source, backup_source, quality, extensions) do
    case do_prepare_stage(stage, source, backup_source, extensions) do
      {:ok, prepared} ->
        {:ok, quality, durable_rollback(prepared), true}

      {:error, reason} = error ->
        record_stage_error(stage.id, reason)
        error
    end
  end

  defp create_stage(attrs) do
    case ImportStage.create(attrs) do
      {:ok, stage} -> {:ok, stage}
      {:error, _changeset} -> {:error, :import_stage_busy}
    end
  end

  defp do_prepare_stage(stage, source, backup_source, extensions) do
    candidate = stage.candidate

    with :ok <- Library.link_or_copy(source, candidate, stage.root, extensions),
         {:ok, candidate_stat} <- fs().lstat(candidate),
         stage <- ImportStage.update!(stage, identity_attrs(:candidate, candidate_stat)),
         {:ok, stage} <- maybe_move_backup(stage, backup_source),
         {:ok, landed_stat} <- land_candidate(stage, candidate_stat) do
      {:ok,
       ImportStage.update!(
         stage,
         Map.merge(
           %{
             state: :prepared,
             next_attempt_at: ImportStage.handoff_deadline(),
             last_error: nil
           },
           identity_attrs(:staged, landed_stat)
         )
       )}
    end
  end

  defp maybe_move_backup(stage, nil), do: {:ok, stage}

  defp maybe_move_backup(stage, source) do
    backup = stage.backup

    with {:ok, current} <- fs().lstat(source),
         true <-
           identity_matches?(current, backup_identity(stage)) ||
             {:error, :import_stage_destination_changed},
         {:ok, ^source} <- safe_destination(source, stage.root),
         {:ok, ^backup} <- safe_destination(backup, stage.root),
         :ok <- fs().rename(source, backup) do
      {:ok, stage}
    end
  end

  # `link(2)` is the no-replace primitive: a file appearing at dest while a long copy builds the
  # candidate yields EEXIST and is preserved. For replacement, the immediately preceding identity
  # recheck minimizes the unavoidable same-host lstat->rename TOCTOU window established in Task 3.
  defp land_candidate(stage, candidate_stat) do
    candidate = stage.candidate
    dest = stage.dest

    with {:ok, ^candidate} <- safe_destination(candidate, stage.root),
         {:ok, ^dest} <- safe_destination(dest, stage.root) do
      case fs().ln(candidate, dest) do
        :ok ->
          finish_candidate_land(stage, candidate_stat)

        {:error, errno} when errno in @exclusive_copy_fallback_errnos ->
          exclusive_copy_candidate(stage, candidate_stat)

        {:error, _} = error ->
          error
      end
    end
  end

  defp finish_candidate_land(stage, candidate_stat) do
    case remove_owned(stage.candidate, identity(candidate_stat), stage.root) do
      :ok -> {:ok, candidate_stat}
      {:error, _} = error -> error
    end
  end

  defp exclusive_copy_candidate(stage, candidate_stat) do
    on_create = fn stat -> persist_partial_destination_identity(stage, stat) end

    with :ok <- fs().cp_exclusive(stage.candidate, stage.dest, on_create),
         {:ok, landed_stat} <- fs().lstat(stage.dest),
         :ok <- verify_opened_destination(stage.id, landed_stat),
         _stage <- ImportStage.update!(stage, identity_attrs(:staged, landed_stat)),
         :ok <- remove_owned(stage.candidate, identity(candidate_stat), stage.root) do
      {:ok, landed_stat}
    end
  end

  defp verify_opened_destination(stage_id, landed_stat) do
    case ImportStage.get(stage_id) do
      %ImportStage{} = stage ->
        if staged_identity_matches?(landed_stat, stage),
          do: :ok,
          else: {:error, :import_stage_destination_changed}

      nil ->
        {:error, :import_stage_journal_missing}
    end
  end

  defp persist_partial_destination_identity(stage, stat) do
    ImportStage.update!(stage, %{
      staged_inode: stat.inode,
      staged_device: stat.major_device,
      staged_size: nil
    })

    :ok
  end

  defp durable_rollback(stage),
    do: %{state: :durable, stage_id: stage.id, operation_key: stage.operation_key}

  defp stage_path(dest, operation_key),
    do: Path.join(Path.dirname(dest), ".cinder-stage-#{operation_key}")

  defp rollback_path(dest, operation_key),
    do: Path.join(Path.dirname(dest), ".cinder-rollback-#{operation_key}")

  defp identity_attrs(_prefix, nil), do: %{}

  defp identity_attrs(:candidate, stat),
    do: %{
      candidate_inode: stat.inode,
      candidate_device: stat.major_device,
      candidate_size: stat.size
    }

  defp identity_attrs(:staged, stat),
    do: %{staged_inode: stat.inode, staged_device: stat.major_device, staged_size: stat.size}

  defp identity_attrs(:backup, stat),
    do: %{backup_inode: stat.inode, backup_device: stat.major_device, backup_size: stat.size}

  defp identity(stat), do: {stat.inode, stat.major_device, stat.size}

  # Public (not private): called from `Cinder.Library.rollback_stage/1`.
  @doc false
  def rollback(%{state: :durable, stage_id: id}), do: reconcile_stage(id, :rollback)

  # Public (not private): called from `Cinder.Library.commit_stage/1`.
  @doc false
  def commit(%{state: :durable, stage_id: id}), do: reconcile_stage(id, :commit)

  # Public (not private): called from `Cinder.Library.commit_stage/1`.
  @doc false
  def claim_post_commit_effects(%{state: :durable, stage_id: id}),
    do: match?({:claimed, _stage}, ImportStage.claim_effects(id))

  def claim_post_commit_effects(_rollback), do: false

  # Public (not private): called from `Cinder.Library.reconcile_stages/0`.
  @doc false
  def reconcile_stage(id, mode) do
    case ImportStage.get(id) do
      nil ->
        :ok

      stage ->
        # Every path observes destination -> operation lock ordering. Correctness across Catalog
        # transactions comes from the conditional DB claims below, not from these process locks.
        reconcile_stage_with_locks(stage, mode)
    end
  end

  defp reconcile_stage_with_locks(stage, mode) do
    ImportStage.with_destination_lock(stage.dest, fn ->
      ImportStage.with_lock(stage.operation_key, fn ->
        stage.id
        |> ImportStage.get()
        |> reconcile_stage_state(mode)
      end)
    end)
  end

  defp reconcile_stage_state(nil, _mode), do: :ok

  defp reconcile_stage_state(%ImportStage{state: state}, :commit)
       when state in [:preparing, :prepared, :rolling_back],
       do: {:error, :import_stage_not_committed}

  defp reconcile_stage_state(%ImportStage{state: state} = stage, :auto)
       when state in [:preparing, :prepared],
       do: claim_stage_due(stage, [:preparing, :prepared], :rolling_back, :rollback)

  defp reconcile_stage_state(%ImportStage{state: state} = stage, _mode)
       when state in [:preparing, :prepared],
       do: claim_stage(stage, [:preparing, :prepared], :rolling_back, :rollback)

  defp reconcile_stage_state(%ImportStage{state: :committed} = stage, :auto),
    do: claim_stage_due(stage, [:committed], :cleaning, :cleanup)

  defp reconcile_stage_state(%ImportStage{state: :committed} = stage, _mode),
    do: claim_stage(stage, [:committed], :cleaning, :cleanup)

  defp reconcile_stage_state(%ImportStage{state: state} = stage, _mode)
       when state in [:rolling_back, :cleaning],
       do: retry_stage(stage)

  defp reconcile_stage_state(%ImportStage{state: :quarantined}, :auto), do: :ok

  defp reconcile_stage_state(%ImportStage{state: :quarantined}, _mode),
    do: {:error, :import_stage_quarantined}

  defp claim_stage(stage, from_states, state, action) do
    case ImportStage.claim(stage.id, from_states, state, action) do
      {:claimed, claimed} -> reconcile_claimed_stage(claimed)
      :not_claimed -> stage.id |> ImportStage.get() |> reconcile_stage_state(:auto)
    end
  end

  defp claim_stage_due(stage, from_states, state, action) do
    case ImportStage.claim_due(stage.id, from_states, state, action) do
      {:claimed, claimed} -> reconcile_claimed_stage(claimed)
      :not_claimed -> :ok
    end
  end

  defp retry_stage(stage) do
    case ImportStage.claim_retry(stage.id, stage.state) do
      {:claimed, claimed} -> reconcile_claimed_stage(claimed)
      :not_claimed -> :ok
    end
  end

  defp reconcile_claimed_stage(%ImportStage{kind: :noop} = stage), do: delete_stage(stage)

  defp reconcile_claimed_stage(%ImportStage{recovery_action: :cleanup} = stage),
    do: stage |> cleanup_committed_stage() |> finish_stage_reconciliation(stage)

  defp reconcile_claimed_stage(%ImportStage{recovery_action: :rollback} = stage),
    do: stage |> rollback_uncommitted_stage() |> finish_stage_reconciliation(stage)

  defp cleanup_committed_stage(stage) do
    with :ok <- remove_owned(stage.backup, backup_identity(stage), stage.root),
         do: delete_stage(stage)
  end

  defp rollback_uncommitted_stage(stage) do
    with :ok <- remove_owned_destination(stage),
         :ok <- restore_owned_backup(stage),
         :ok <- remove_unlanded_candidate(stage),
         do: delete_stage(stage)
  end

  defp remove_unlanded_candidate(%ImportStage{candidate_inode: nil} = stage),
    do: remove_unique_candidate(stage)

  defp remove_unlanded_candidate(%ImportStage{} = stage),
    do: remove_owned(stage.candidate, candidate_identity(stage), stage.root)

  # The UUID candidate path belongs exclusively to its journal row. A crash can land between the
  # link/copy and its first lstat; in that narrow window there is no identity to persist, but the
  # unique path is still durable ownership evidence and must remain recoverable.
  defp remove_unique_candidate(stage) do
    case fs().lstat(stage.candidate) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> safe_remove(stage.candidate, [stage.root])
      {:error, _} = error -> error
    end
  end

  defp remove_owned_destination(stage) do
    case fs().lstat(stage.dest) do
      {:error, :enoent} ->
        :ok

      {:ok, stat} ->
        remove_or_preserve_destination(stage, stat)

      {:error, _} = error ->
        error
    end
  end

  defp remove_or_preserve_destination(stage, stat) do
    if staged_identity_matches?(stat, stage) or
         identity_matches?(stat, candidate_identity(stage)) do
      safe_remove(stage.dest, [stage.root])
    else
      fail_if_backup_waits(stage)
    end
  end

  defp fail_if_backup_waits(%ImportStage{backup: nil}),
    do: {:error, :import_stage_destination_changed}

  defp fail_if_backup_waits(stage) do
    case fs().lstat(stage.backup) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :import_stage_destination_changed}
      {:error, _} = error -> error
    end
  end

  defp restore_owned_backup(%ImportStage{backup: nil}), do: :ok

  defp restore_owned_backup(stage) do
    case fs().lstat(stage.backup) do
      {:error, :enoent} ->
        :ok

      {:ok, stat} ->
        restore_matching_backup(stage, stat)

      {:error, _} = error ->
        error
    end
  end

  defp restore_matching_backup(stage, stat) do
    if identity_matches?(stat, backup_identity(stage)) do
      backup = stage.backup
      dest = stage.dest

      with {:error, :enoent} <- fs().lstat(dest),
           {:ok, ^backup} <- safe_destination(backup, stage.root),
           {:ok, ^dest} <- safe_destination(dest, stage.root),
           :ok <- fs().rename(backup, dest),
           {:ok, restored} <- fs().lstat(dest),
           true <-
             identity_matches?(restored, backup_identity(stage)) ||
               {:error, :import_stage_restore_changed} do
        :ok
      else
        {:ok, _occupant} -> {:error, :import_stage_destination_changed}
        {:error, _} = error -> error
      end
    else
      {:error, :import_stage_backup_changed}
    end
  end

  defp remove_owned(nil, _identity, _root), do: :ok

  defp remove_owned(path, identity, root) do
    case fs().lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, stat} ->
        if identity_matches?(stat, identity),
          do: safe_remove(path, [root]),
          else: {:error, :import_stage_file_changed}

      {:error, _} = error ->
        error
    end
  end

  defp candidate_identity(stage),
    do: {stage.candidate_inode, stage.candidate_device, stage.candidate_size}

  defp staged_identity(stage), do: {stage.staged_inode, stage.staged_device, stage.staged_size}
  defp backup_identity(stage), do: {stage.backup_inode, stage.backup_device, stage.backup_size}

  defp identity_matches?(_stat, {nil, _device, _size}), do: false
  defp identity_matches?(_stat, {_inode, nil, _size}), do: false
  defp identity_matches?(_stat, {_inode, _device, nil}), do: false

  defp identity_matches?(stat, {inode, device, size}),
    do: stat.inode == inode and stat.major_device == device and stat.size == size

  defp staged_identity_matches?(stat, %{
         staged_inode: inode,
         staged_device: device,
         staged_size: nil
       })
       when not is_nil(inode) and not is_nil(device),
       do: stat.inode == inode and stat.major_device == device

  defp staged_identity_matches?(stat, stage), do: identity_matches?(stat, staged_identity(stage))

  defp delete_stage(stage) do
    case ImportStage.delete(stage) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp finish_stage_reconciliation(:ok, _stage), do: :ok

  defp finish_stage_reconciliation({:error, reason} = error, stage) do
    persist_cleanup_failure(stage, reason)
    error
  end

  @max_cleanup_attempts 8
  @cleanup_backoff_base 30
  @cleanup_backoff_cap 1_800
  @permanent_cleanup_errors [
    :import_stage_destination_changed,
    :import_stage_backup_changed,
    :import_stage_file_changed,
    :import_stage_restore_changed
  ]

  defp persist_cleanup_failure(stage, reason) do
    attempt = stage.attempt_count + 1
    error = stage_error(reason)
    quarantine? = reason in @permanent_cleanup_errors or attempt >= @max_cleanup_attempts

    attrs =
      if quarantine? do
        %{state: :quarantined, attempt_count: attempt, next_attempt_at: nil, last_error: error}
      else
        %{
          attempt_count: attempt,
          next_attempt_at: DateTime.add(DateTime.utc_now(:second), cleanup_backoff(attempt)),
          last_error: error
        }
      end

    if quarantine? do
      Logger.error(
        "import stage #{stage.id} quarantined after #{attempt} cleanup attempt(s): #{error}"
      )
    else
      Logger.warning("import stage #{stage.id} cleanup pending: #{error}")
    end

    ImportStage.update(stage, attrs)
    :ok
  end

  defp cleanup_backoff(attempt),
    do: min(@cleanup_backoff_base * Integer.pow(2, attempt - 1), @cleanup_backoff_cap)

  defp record_stage_error(id, reason) do
    case ImportStage.get(id) do
      nil ->
        :ok

      stage ->
        error = stage_error(reason)

        if stage.last_error != error do
          Logger.warning("import stage #{stage.id} cleanup pending: #{error}")
          ImportStage.update(stage, %{last_error: error})
        end

        :ok
    end
  end

  defp stage_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp stage_error({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp stage_error(_reason), do: "filesystem_error"

  # Duplicated from `Cinder.Library`'s own copies — tiny, side-effect-free config/PathPolicy
  # accessors — kept as independent copies rather than shared for it.
  defp fs, do: Application.fetch_env!(:cinder, :filesystem)

  defp safe_source_file(path, extensions \\ @video_exts) do
    case Cinder.Settings.import_roots() do
      [] -> {:error, :download_roots_not_configured}
      roots -> Library.path_policy().source_file(path, roots, extensions, filesystem: fs())
    end
  end

  defp safe_destination(path, root),
    do: Library.path_policy().destination(path, root, filesystem: fs())

  defp safe_remove(path, roots) do
    with :ok <- Library.path_policy().deletable_file(path, roots, filesystem: fs()),
         do: fs().rm(path)
  end
end
