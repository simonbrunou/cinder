defmodule Cinder.Library do
  @moduledoc """
  Import: hardlink a completed download into the Plex library, renamed to
  `Title (Year) {tmdb-<id>}/Title (Year) {tmdb-<id>}.ext` (or bare `Title {tmdb-<id>}`
  when the year is unknown, or `tmdb-<id>` when the title has no usable characters),
  then trigger a scan.

  Filesystem ops and the media server are reached only through behaviours
  (`Cinder.Library.Filesystem`, `Cinder.Library.MediaServer`), resolved from
  config at runtime so tests use Mox mocks and never touch disk or the network.
  Owns filesystem + Plex only — `Catalog` remains the status choke-point.
  """

  require Logger

  alias Cinder.Acquisition.{Language, Parser}
  alias Cinder.Catalog.{Episode, Movie, Series}
  alias Cinder.Library.{ImportStage, PathPolicy, Sidecars, Upgrade}
  alias Cinder.Settings

  @video_exts ~w(.mkv .mp4 .avi .m4v .mov .wmv .ts)
  @illegal ~r/[\/\\:*?"<>|]/

  # link(2) errnos that mean "this dest can't be hardlinked to" — fall back to an atomic byte copy
  # rather than parking. `:exdev` = source and dest on different mounts. `:eperm`/`:eopnotsupp`/
  # `:enotsup` = a single mount whose filesystem has no hardlink support at all (FAT/exFAT on USB
  # drives, SMB/CIFS without Unix extensions, some FUSE), where `link()` fails without `:exdev` ever
  # firing (issue #59). `:eperm` can also be a genuine permission error, but then the copy fails the
  # same way (`cp` can't open the dest) and the item still parks — a wasted copy attempt, not a
  # wrong import. Every other errno (`:enoent`, `:enospc`, …) is a real failure and propagates.
  @copy_fallback_errnos [:exdev, :eperm, :eopnotsupp, :enotsup]

  # The library kinds Cinder manages. The single source of truth — config keys
  # (`:"#{kind}_library_path"`, the per-kind Plex section, the size band), the
  # settings UI, health checks, and the media-server scan all derive from it, so a
  # new media type (e.g. `:books`) is one entry here, not a fork. Pure literal:
  # read at boot and at config-eval time, so it must not touch Application env or Repo.
  @kinds [:movies, :tv]

  @doc "The library kinds Cinder manages (e.g. `:movies`, `:tv`)."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Hardlinks `movie`'s downloaded file into the library and triggers a scan.
  Returns `{:ok, dest_path, quality}` or `{:error, reason}`. Idempotent: a dest
  that already exists (`:eexist`) is treated as success when it is the same
  hardlink (same inode). On a collision with a different file, the existing
  release is kept or replaced based on an upgrade score comparison.
  The scan is best-effort — once the file is hardlinked the import has
  succeeded, so a failing scan is logged but does not turn into `{:error, _}`.

  When a language is wanted and `:media_info` is configured, the file's actual audio tracks are
  probed first: a confirmed mismatch returns `{:error, :wrong_audio_language}` so the wrong-language
  file is never imported (the poller parks it). Missing/unverifiable audio data imports as before.
  """
  @spec import_movie(Movie.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def import_movie(%Movie{} = movie), do: import_movie(movie, [])

  @spec import_movie(Movie.t(), keyword()) :: {:ok, String.t(), map()} | {:error, term()}
  def import_movie(%Movie{file_path: path}, _opts) when path in [nil, ""],
    do: {:error, :no_file_path}

  def import_movie(%Movie{} = movie, opts) do
    replace? = Keyword.get(opts, :replace, false)

    with {:ok, root} <- root(:movies),
         {:ok, source, folder?} <- resolve_source(movie.file_path),
         :ok <-
           verify_audio(
             source,
             Language.target(movie.preferred_language, movie.original_language)
           ),
         {:ok, %{size: size, inode: si, major_device: sdev}} <- fs().lstat(source),
         parsed = Parser.parse(Path.basename(movie.file_path)),
         new_q =
           new_quality(parsed, size)
           |> Map.merge(capture_media(source))
           |> Map.put_new(:sidecar_subtitles, []),
         dest = build_dest(movie, source, root),
         {:ok, dest} <- safe_destination(dest, root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, quality, placed?} <-
           place(source, dest, root, {si, sdev}, movie, new_q, replace?, fn ->
             upgrade?(movie, new_q)
           end) do
      quality = maybe_link_sidecars(quality, placed?, folder?, source, dest)
      refresh(:movies, dest)

      fetch_subtitles(
        fn -> Cinder.Subtitles.movie_criteria(movie) end,
        dest,
        :movies,
        quality.sidecar_subtitles
      )

      {:ok, dest, quality}
    end
  end

  @doc "Stages a movie import with rollback material for a guarded Catalog transition."
  @spec stage_movie(Movie.t(), keyword()) ::
          {:ok, %{dest: String.t(), rollback: map(), quality: map()}} | {:error, term()}
  def stage_movie(movie, opts \\ [])

  def stage_movie(%Movie{file_path: path}, _opts) when path in [nil, ""],
    do: {:error, :no_file_path}

  def stage_movie(%Movie{} = movie, opts) do
    replace? = Keyword.get(opts, :replace, false)

    with {:ok, root} <- root(:movies),
         {:ok, source, folder?} <- resolve_source(movie.file_path),
         :ok <-
           verify_audio(
             source,
             Language.target(movie.preferred_language, movie.original_language)
           ),
         {:ok, %{size: size, inode: si, major_device: sdev}} <- fs().lstat(source),
         parsed = Parser.parse(Path.basename(movie.file_path)),
         new_q =
           new_quality(parsed, size)
           |> Map.merge(capture_media(source))
           |> Map.put_new(:sidecar_subtitles, []),
         dest = build_dest(movie, source, root),
         {:ok, dest} <- safe_destination(dest, root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, quality, rollback, placed?} <-
           stage_place(source, dest, root, {si, sdev}, movie, new_q, replace?, fn ->
             upgrade?(movie, new_q)
           end) do
      quality = staged_sidecar_quality(quality, placed?, folder?, source)

      {:ok,
       %{
         dest: dest,
         quality: quality,
         rollback:
           Map.merge(rollback, %{
             after_commit: {:movie, movie},
             folder?: folder?,
             source: source
           })
       }}
    end
  end

  @doc "Commits a staged import. Safe to call repeatedly."
  @spec commit_stage(%{dest: String.t(), rollback: map(), quality: map()}) ::
          :ok | {:error, term()}
  def commit_stage(%{dest: dest, rollback: rollback, quality: quality}) do
    result = commit(rollback)
    maybe_commit_sidecars(rollback, dest)
    run_after_commit(rollback, dest, quality)
    result
  end

  @doc "Rolls a staged import back. Safe to call repeatedly."
  @spec rollback_stage(%{rollback: map()}) :: :ok | {:error, term()}
  def rollback_stage(%{rollback: rollback}), do: rollback(rollback)

  @doc false
  def stage_ids(stages),
    do:
      stages
      |> Enum.flat_map(fn
        %{rollback: %{state: :durable, stage_id: id}} -> [id]
        _stage -> []
      end)
      |> Enum.uniq()

  @doc "Converges durable import stages left by process death or a prior filesystem error."
  @spec reconcile_stages() :: :ok
  def reconcile_stages do
    Enum.each(ImportStage.list(), fn stage ->
      ImportStage.with_lock(stage.operation_key, fn -> reconcile_stage(stage.id, :auto) end)
    end)

    :ok
  end

  # Place source at dest; resolve a same-item collision (tmdb-unique folder => same record) by the
  # caller's `upgrade_fun` decision or a forced `replace?`. Shared by movie and episode imports.
  # `upgrade_fun` is a thunk so the (config-reading) upgrade comparison runs only on an actual
  # collision, not every import. `replace?` bypasses the upgrade gate entirely.
  defp place(source, dest, root, {si, sdev}, record, new_q, replace?, upgrade_fun) do
    with {:ok, source} <- safe_source_file(source),
         {:ok, dest} <- safe_destination(dest, root) do
      do_place(source, dest, root, {si, sdev}, record, new_q, replace?, upgrade_fun)
    end
  end

  defp do_place(source, dest, root, {si, sdev}, record, new_q, replace?, upgrade_fun) do
    case fs().ln(source, dest) do
      :ok ->
        {:ok, new_q, true}

      {:error, errno} when errno in @copy_fallback_errnos ->
        # Fresh placement onto a filesystem that can't hardlink this source (cross-mount `:exdev`, or a
        # no-hardlink-support mount → `:eperm`/`:eopnotsupp`/`:enotsup`): copy the bytes in atomically
        # via replace/2 (link-or-copy into a unique temp on the dest fs, then rename). This is the
        # *fresh* case because on Linux (the deployment target) link(2) reports EEXIST before EXDEV/EPERM
        # (filename_create checks EEXIST before vfs_link), so a collision with an existing dest surfaces
        # as :eexist below and still runs the upgrade/keep gate — never an unconditional overwrite here.
        # The copy logs
        # at :info from link_or_copy/2 — the one choke-point both copy paths hit.
        with :ok <- replace(source, dest, root), do: {:ok, new_q, true}

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
  # false either way — no fresh bytes landed, so sidecars are not re-linked.
  defp do_resolve(_source, _dest, true, _upgrade, movie, new_q, replace?, _root),
    do: {:ok, if(replace?, do: new_q, else: existing_quality(movie, new_q)), false}

  defp do_resolve(source, dest, false, true, _movie, new_q, _replace?, root) do
    with :ok <- replace(source, dest, root), do: {:ok, new_q, true}
  end

  defp do_resolve(_source, dest, false, false, movie, new_q, _replace?, _root),
    do: keep(dest, movie, new_q)

  defp stage_place(source, dest, root, {si, sdev}, record, new_q, replace?, upgrade_fun) do
    with {:ok, source} <- safe_source_file(source),
         {:ok, dest} <- safe_destination(dest, root) do
      case fs().lstat(dest) do
        {:error, :enoent} ->
          stage_new(source, dest, root, new_q)

        {:ok, %{inode: ^si, major_device: ^sdev}} ->
          {:ok, existing_quality_for_stage(record, new_q, replace?), noop_rollback(), false}

        {:ok, stat} ->
          stage_existing(source, dest, root, stat, record, new_q, replace?, upgrade_fun)

        {:error, _} = error ->
          error
      end
    end
  end

  defp stage_existing(source, dest, root, stat, record, new_q, replace?, upgrade_fun) do
    if replace? or upgrade_fun.() do
      stage_replacement(source, dest, root, stat, new_q)
    else
      {:ok, quality, false} = keep(dest, record, new_q)
      {:ok, quality, noop_rollback(), false}
    end
  end

  defp existing_quality_for_stage(_record, new_q, true), do: new_q
  defp existing_quality_for_stage(record, new_q, false), do: existing_quality(record, new_q)

  defp stage_new(source, dest, root, quality),
    do: prepare_durable_stage(source, dest, root, nil, nil, quality)

  defp stage_replacement(source, dest, root, original_stat, quality),
    do: prepare_durable_stage(source, dest, root, dest, original_stat, quality)

  defp prepare_durable_stage(source, dest, root, backup_source, backup_stat, quality) do
    operation_key = Ecto.UUID.generate()
    candidate = stage_path(dest, operation_key)
    backup = if backup_source, do: rollback_path(dest, operation_key)

    ImportStage.with_lock(operation_key, fn ->
      stage =
        ImportStage.create!(
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
        )

      case do_prepare_stage(stage, source, backup_source) do
        {:ok, prepared} ->
          {:ok, quality, durable_rollback(prepared), true}

        {:error, reason} = error ->
          record_stage_error(stage.id, reason)
          error
      end
    end)
  end

  defp do_prepare_stage(stage, source, backup_source) do
    candidate = stage.candidate
    dest = stage.dest

    with :ok <- link_or_copy(source, candidate, stage.root),
         {:ok, candidate_stat} <- fs().lstat(candidate),
         stage <- ImportStage.update!(stage, identity_attrs(:candidate, candidate_stat)),
         {:ok, stage} <- maybe_move_backup(stage, backup_source),
         {:ok, ^candidate} <- safe_destination(candidate, stage.root),
         {:ok, ^dest} <- safe_destination(dest, stage.root),
         :ok <- fs().rename(candidate, dest) do
      {:ok,
       ImportStage.update!(
         stage,
         Map.merge(%{state: :prepared, last_error: nil}, identity_attrs(:staged, candidate_stat))
       )}
    end
  end

  defp maybe_move_backup(stage, nil), do: {:ok, stage}

  defp maybe_move_backup(stage, source) do
    backup = stage.backup

    with {:ok, ^source} <- safe_destination(source, stage.root),
         {:ok, ^backup} <- safe_destination(backup, stage.root),
         :ok <- fs().rename(source, backup) do
      {:ok, stage}
    end
  end

  defp durable_rollback(stage),
    do: %{state: :durable, stage_id: stage.id, operation_key: stage.operation_key}

  defp noop_rollback, do: %{state: :noop}

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

  defp rollback(%{state: :noop}), do: :ok
  defp rollback(%{state: :durable, stage_id: id}), do: reconcile_stage(id, :rollback)

  defp commit(%{state: :noop}), do: :ok
  defp commit(%{state: :durable, stage_id: id}), do: reconcile_stage(id, :commit)

  defp reconcile_stage(id, mode) do
    case ImportStage.get(id) do
      nil ->
        :ok

      stage ->
        stage
        |> reconcile_stage_state(mode)
        |> finish_stage_reconciliation(stage)
    end
  end

  defp reconcile_stage_state(%ImportStage{state: :committed} = stage, _mode),
    do: cleanup_committed_stage(stage)

  defp reconcile_stage_state(%ImportStage{}, :commit),
    do: {:error, :import_stage_not_committed}

  defp reconcile_stage_state(%ImportStage{} = stage, _mode),
    do: rollback_uncommitted_stage(stage)

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

  defp remove_unlanded_candidate(%ImportStage{state: :preparing, candidate_inode: nil} = stage),
    do: remove_unique_candidate(stage)

  defp remove_unlanded_candidate(%ImportStage{state: :preparing} = stage),
    do: remove_owned(stage.candidate, candidate_identity(stage), stage.root)

  defp remove_unlanded_candidate(%ImportStage{}), do: :ok

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
    if identity_matches?(stat, staged_identity(stage)) or
         identity_matches?(stat, candidate_identity(stage)) do
      safe_remove(stage.dest, [stage.root])
    else
      fail_if_backup_waits(stage)
    end
  end

  defp fail_if_backup_waits(%ImportStage{backup: nil}), do: :ok

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

  defp delete_stage(stage) do
    case ImportStage.delete(stage) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp finish_stage_reconciliation(:ok, _stage), do: :ok

  defp finish_stage_reconciliation({:error, reason} = error, stage) do
    record_stage_error(stage.id, reason)
    error
  end

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

  defp staged_sidecar_quality(quality, true, true, source) do
    languages = source |> Sidecars.files() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    Map.put(quality, :sidecar_subtitles, languages)
  end

  defp staged_sidecar_quality(quality, _placed?, _folder?, _source), do: quality

  defp maybe_commit_sidecars(%{folder?: true, source: source}, dest),
    do: Sidecars.link(source, dest)

  defp maybe_commit_sidecars(_rollback, _dest), do: []

  defp run_after_commit(%{after_commit: {:movie, movie}}, dest, quality) do
    refresh(:movies, dest)

    fetch_subtitles(
      fn -> Cinder.Subtitles.movie_criteria(movie) end,
      dest,
      :movies,
      quality.sidecar_subtitles
    )
  end

  defp run_after_commit(%{after_commit: {:episodes, episodes}}, dest, quality) do
    refresh(:tv, dest)
    fetch_episode_subtitles_for_dest(episodes, dest, quality)
  end

  defp run_after_commit(_rollback, _dest, _quality), do: :ok

  defp existing_quality(record, new_q) do
    if nil_q?(record), do: new_q, else: old_quality(record)
  end

  # Quality maps shared by movie + episode import (both carry the imported_* fields). Reads the
  # stored media-info lists too, so the keep branch carries them forward unchanged.
  defp old_quality(record) do
    %{
      resolution: record.imported_resolution,
      size: record.imported_size,
      language: record.imported_language,
      source: record.imported_source,
      audio_languages: record.imported_audio_languages,
      embedded_subtitles: record.imported_embedded_subtitles,
      sidecar_subtitles: record.imported_sidecar_subtitles
    }
  end

  defp new_quality(parsed, size) do
    %{resolution: parsed.resolution, source: parsed.source, size: size, language: parsed.language}
  end

  # Probe the source's audio + embedded-subtitle languages for storage on the imported row. Empty
  # lists when media_info is disabled or the probe errors — never blocks the import. Runs on every
  # import (folder or single-file); the release's sidecar languages are captured separately by
  # maybe_link_sidecars/5 (a folder scan) only when a fresh file is actually placed.
  defp capture_media(source) do
    case media_info() do
      nil -> %{audio_languages: [], embedded_subtitles: []}
      impl -> probe_media(impl, source)
    end
  end

  defp probe_media(impl, source) do
    case impl.probe(source) do
      {:ok, %{audio: audio, subtitles: subtitles}} ->
        %{audio_languages: audio, embedded_subtitles: subtitles}

      other ->
        # Degrading to empty metadata is deliberate — but a broken/missing ffprobe must be
        # diagnosable: silently-empty fields read as "the file has no tags", not "the probe
        # is broken" (media_info is on by default, and there is no health row for it).
        Logger.warning("media-info probe failed for #{source}: #{inspect(other)}")
        %{audio_languages: [], embedded_subtitles: []}
    end
  end

  # Hardlink the release's sidecar subtitles next to a freshly-placed dest and record their
  # languages — only when the file was actually placed (`placed?`, not a keep/idempotent no-op)
  # AND the download was a folder (`folder?`); a single-file download ships no sidecars. Best-effort
  # via Sidecars.link/2, which never raises. Otherwise the quality's `sidecar_subtitles` stays as it
  # was (the fresh `[]` on new_q, or the stored value on the keep branch's old_quality).
  defp maybe_link_sidecars(quality, true, true, source, dest),
    do: Map.put(quality, :sidecar_subtitles, Sidecars.link(source, dest))

  defp maybe_link_sidecars(quality, _placed?, _folder?, _source, _dest), do: quality

  defp nil_q?(m),
    do: is_nil(m.imported_resolution) and is_nil(m.imported_size) and is_nil(m.imported_language)

  defp upgrade?(movie, new_q) do
    target = Language.target(movie.preferred_language, movie.original_language)

    Upgrade.better?(
      new_q,
      old_quality(movie),
      target,
      preferred_resolutions(:movies),
      preferred_sources(:movies)
    )
  end

  defp keep(dest, movie, new_q) do
    old_q = existing_quality(movie, new_q)

    Logger.warning(
      "kept existing #{inspect(old_q.resolution)} file at #{dest}; new release not an upgrade"
    )

    {:ok, old_q, false}
  end

  defp preferred_resolutions(kind),
    do: Application.get_env(:cinder, :"#{kind}_preferred_resolutions")

  defp preferred_sources(kind),
    do: Application.get_env(:cinder, :"#{kind}_preferred_sources")

  # Atomic replace of an existing dest with source's content: sweep stale temps (a host crash between
  # link/copy and rename can leak one), link-or-copy source -> unique temp in the dest dir, then rename
  # over dest. The temp lives on the dest filesystem, so the rename is same-fs and atomic even when the
  # source content had to be copied across filesystems.
  defp replace(source, dest, root) do
    dir = Path.dirname(dest)
    sweep_temps(dir, root)
    tmp = Path.join(dir, ".cinder-tmp-#{System.unique_integer([:positive])}")

    with {:ok, ^dest} <- safe_destination(dest, root),
         {:ok, ^tmp} <- safe_destination(tmp, root),
         :ok <- link_or_copy(source, tmp, root),
         {:ok, ^tmp} <- safe_destination(tmp, root),
         {:ok, ^dest} <- safe_destination(dest, root),
         :ok <- fs().rename(tmp, dest) do
      :ok
    else
      {:error, _} = err ->
        _ = safe_remove(tmp, [root])
        err
    end
  end

  # Hardlink source -> target, falling back to a byte copy only when the dest filesystem can't be
  # hardlinked to (@copy_fallback_errnos: cross-mount `:exdev`, or no hardlink support at all →
  # `:eperm`/`:eopnotsupp`/`:enotsup`). Every other ln error (`:eacces`, `:enoent`, `:enospc`, …) is a
  # real failure and propagates unchanged — a copy would fail the same way. Both the fresh placement
  # and the upgrade-replace path route the copy through here, so the :info fallback log lives at this
  # single choke-point and covers every fallback (per docs/operating.md).
  defp link_or_copy(source, target, root) do
    with {:ok, source} <- safe_source_file(source),
         {:ok, target} <- safe_destination(target, root) do
      do_link_or_copy(source, target, root)
    end
  end

  defp do_link_or_copy(source, target, root) do
    case fs().ln(source, target) do
      {:error, errno} when errno in @copy_fallback_errnos ->
        Logger.info(
          "hardlink unsupported (#{errno}); copying #{source} into #{Path.dirname(target)}"
        )

        with {:ok, ^source} <- safe_source_file(source),
             {:ok, ^target} <- safe_destination(target, root),
             do: fs().cp(source, target)

      other ->
        other
    end
  end

  defp sweep_temps(dir, root) do
    case path_policy().walk(dir, roots: [root], filesystem: fs()) do
      {:ok, files} ->
        for {p, _size} <- files,
            String.contains?(Path.basename(p), ".cinder-tmp-"),
            do: safe_remove(p, [root])

        :ok

      _ ->
        :ok
    end
  end

  # MediaInfo safety net behind the name filter: when a language is wanted and the file's audio
  # tracks positively don't include it, fail with `:wrong_audio_language` so the poller parks the
  # movie at :import_failed rather than importing the wrong language. Conservative — no impl
  # configured (`:media_info` unset), no probeable language (empty / `und`), or a probe error all
  # import; only a confirmed mismatch parks. `target` is nil for an "any" pick or unknown original.
  defp verify_audio(_source, nil), do: :ok

  defp verify_audio(source, target) do
    case media_info() do
      nil -> :ok
      impl -> check_audio(impl, source, target)
    end
  end

  defp check_audio(impl, source, target) do
    case impl.probe(source) do
      {:ok, %{audio: []}} ->
        :ok

      {:ok, %{audio: langs}} ->
        audio_result(Language.audio_satisfies?(target, langs))

      {:error, reason} ->
        # Only a CONFIRMED mismatch parks (conservative by design) — but skipping the check
        # silently would disable the advertised wrong-language protection invisibly.
        Logger.warning("media-info audio check skipped for #{source}: #{inspect(reason)}")
        :ok
    end
  end

  defp audio_result(true), do: :ok
  defp audio_result(false), do: {:error, :wrong_audio_language}

  defp media_info, do: Application.get_env(:cinder, :media_info)

  @doc """
  Imports the video files at `content_path` for `episodes` (a grab's episodes, each preloaded
  `season: :series`). Returns `{:ok, imported, unmatched}` — `imported` is
  `[{episode_id, dest_path, quality}]` where `quality = %{resolution:, size:, language:}`,
  `unmatched` the video files that mapped to no episode (logged,
  not an error: graceful park) — or `{:error, reason}` on a transient filesystem error (the grab
  retries). One best-effort scan fires when anything imported.

  Layout: `Show (Year)/Season NN/Show (Year) - SxxEyy.ext`. Files are matched by parsing `SxxEyy`
  from each name and intersecting with the grab's episodes (a double-episode file maps to both).
  For a single-episode grab whose files name no specific episode, the largest video is assigned
  to it — mirroring `import_movie`'s sample-skipping largest-wins, since the grab already names
  the one episode. Reuses `import_movie`'s place/scan/naming primitives.

  When `:media_info` is configured and the series wants a language, a file whose actual audio is a
  confirmed different language is dropped to `unmatched` (logged, not imported) rather than landing
  the wrong language — so the episode re-searches. Same conservative rule as the movie path.
  """
  @spec import_episodes(String.t() | nil, [Episode.t()]) ::
          {:ok, [{integer(), String.t(), map()}], [String.t()]} | {:error, term()}
  def import_episodes(content_path, _episodes) when content_path in [nil, ""],
    do: {:error, :no_content_path}

  def import_episodes(content_path, episodes) do
    # Strict separate TV root: with no :tv_library_path configured, return an error tuple so the
    # poller holds the grab (no bump, no park) until it's set, rather than raising every tick
    # (a raise would sit above the poller's {:error,_} clause and re-raise — see TvPoller). The
    # same guard (`root/1`) protects the movie path symmetrically.
    with {:ok, root} <- root(:tv) do
      do_import_episodes(content_path, episodes, root)
    end
  end

  @doc "Stages episode imports with rollback material for `Catalog.finish_grab/2`."
  @spec stage_episodes(String.t() | nil, [Episode.t()]) ::
          {:ok, [{integer(), map()}], [String.t()]} | {:error, term()}
  def stage_episodes(content_path, _episodes) when content_path in [nil, ""],
    do: {:error, :no_content_path}

  def stage_episodes(content_path, episodes) do
    with {:ok, root} <- root(:tv),
         {:ok, videos, folder?} <- video_files(content_path) do
      {to_import, unmatched} =
        videos
        |> match_episodes(episodes)
        |> dedupe_per_episode()
        |> resolve(videos, episodes)
        |> reject_wrong_audio(episodes)

      case stage_all(to_import, root, episode_target(episodes), folder?) do
        {:ok, []} ->
          log_unmatched(unmatched)
          {:ok, [], unmatched}

        {:ok, imported} ->
          log_unmatched(unmatched)
          {:ok, imported, unmatched}

        {:error, _} = error ->
          error
      end
    end
  end

  defp do_import_episodes(content_path, episodes, root) do
    with {:ok, videos, folder?} <- video_files(content_path) do
      {to_import, unmatched} =
        videos
        |> match_episodes(episodes)
        |> dedupe_per_episode()
        |> resolve(videos, episodes)
        |> reject_wrong_audio(episodes)

      case link_all(to_import, root, episode_target(episodes), folder?) do
        {:ok, []} ->
          # Nothing mapped — still surface the offending file names (don't silently drop them)
          # so a parser gap on a real release is diagnosable; the poller parks the grab.
          log_unmatched(unmatched)
          {:ok, [], unmatched}

        {:ok, imported} ->
          log_unmatched(unmatched)
          refresh(:tv, content_path)
          fetch_episode_subtitles(imported, episodes)
          {:ok, imported, unmatched}

        {:error, _reason} = err ->
          err
      end
    end
  end

  # MediaInfo safety net for TV (same as the movie path): drop a file whose actual audio is a
  # confirmed different language from the series' wanted language into `unmatched` (logged, not
  # imported) so its episode re-searches next tick, instead of importing the wrong language. Skipped
  # when no language is wanted (`target` nil) or the probe is disabled (`media_info` unset).
  defp reject_wrong_audio({to_import, unmatched} = result, episodes) do
    impl = media_info()
    target = episode_target(episodes)

    if is_nil(target) or is_nil(impl) do
      result
    else
      filter_audio(to_import, unmatched, target, impl)
    end
  end

  defp filter_audio(to_import, unmatched, target, impl) do
    # Probe each unique source once (a double-episode file appears twice in `to_import`).
    ok? =
      to_import
      |> Enum.map(fn {_ep, source} -> source end)
      |> Enum.uniq()
      |> Map.new(fn source -> {source, check_audio(impl, source, target) == :ok} end)

    {keep, rejected} = Enum.split_with(to_import, fn {_ep, source} -> ok?[source] end)
    rejected_sources = rejected |> Enum.map(fn {_ep, source} -> source end) |> Enum.uniq()
    # Log distinctly so a language rejection isn't mistaken for a parser miss in `log_unmatched`.
    log_wrong_audio(rejected_sources, target)
    {keep, unmatched ++ rejected_sources}
  end

  defp log_wrong_audio([], _target), do: :ok

  defp log_wrong_audio(sources, target) do
    Logger.info(
      "skipping #{length(sources)} file(s) with wrong audio language (wanted #{target}): " <>
        inspect(sources)
    )
  end

  # The series' wanted language for a grab's episodes (they share one series, preloaded
  # `season: :series`). nil — skip the check — when the series isn't loaded or wants no language.
  defp episode_target([%Episode{season: %{series: %Series{} = series}} | _]),
    do: Language.target(series.preferred_language, series.original_language)

  defp episode_target(_episodes), do: nil

  # All video files under content_path, plus whether content_path is a folder. The folder's video
  # files for a pack/multi-file download, or the lone file itself for a single-file one (size 0 —
  # it's the only candidate). `folder?` gates sidecar linking (single-file downloads ship none).
  defp video_files(path) do
    case safe_walk(path) do
      {:ok, files} ->
        {:ok, only_videos(files), true}

      {:error, :enotdir} ->
        with {:ok, source} <- safe_source_file(path), do: {:ok, [{source, 0}], false}

      {:error, _reason} = error ->
        error
    end
  end

  defp only_videos(files),
    do: Enum.filter(files, fn {p, _size} -> String.downcase(Path.extname(p)) in @video_exts end)

  # {episode, source_path, size} triples for files that name a specific episode in the grab. A
  # double-episode file yields two entries; `link_all/4` groups them back to one library file.
  defp match_episodes(videos, episodes) do
    for {path, size} <- videos,
        parsed = Parser.parse(Path.basename(path)),
        not is_nil(parsed.episodes),
        ep <- episodes,
        ep.season.season_number == parsed.season,
        ep.episode_number in parsed.episodes,
        do: {ep, path, size}
  end

  # One source per episode: when two files parse the same SxxEyy, keep the largest (path breaks
  # ties for a dest stable across retries) and let the losers fall through to `resolve` as
  # unmatched (logged) — never link two different sources onto one episode's dest (the second
  # would collide). Group by episode, not source, so a double-episode file still maps to both.
  defp dedupe_per_episode(matches) do
    matches
    |> Enum.group_by(fn {ep, _path, _size} -> ep.id end)
    |> Enum.map(fn {_id, group} ->
      {ep, path, _size} = Enum.max_by(group, fn {_ep, path, size} -> {size, path} end)
      {ep, path}
    end)
  end

  # Decide the import set + the leftover (unmatched) video files for logging.
  defp resolve([], videos, episodes) do
    if single_ep_fallback?(episodes, videos) do
      # Largest wins (skips samples/extras); path breaks ties so the dest is stable across retries.
      {path, _size} = Enum.max_by(videos, fn {p, size} -> {size, p} end)
      {[{hd(episodes), path}], paths(videos) -- [path]}
    else
      {[], paths(videos)}
    end
  end

  defp resolve(matched, videos, _episodes) do
    matched_paths = matched |> Enum.map(fn {_ep, p} -> p end) |> MapSet.new()
    {matched, Enum.reject(paths(videos), &MapSet.member?(matched_paths, &1))}
  end

  # Fall back to largest-wins only for a lone-episode grab whose files name NO specific episode
  # (so we never mistake a clearly-numbered other episode for ours).
  defp single_ep_fallback?([_one], [_ | _] = videos),
    do: Enum.all?(videos, fn {p, _size} -> is_nil(Parser.parse(Path.basename(p)).episodes) end)

  defp single_ep_fallback?(_episodes, _videos), do: false

  defp paths(videos), do: Enum.map(videos, fn {p, _size} -> p end)

  # Hardlink each match into its tmdb-tagged dest, resolving a same-episode collision by upgrade
  # decision (replace if the new file is better, else keep). One source covering several episodes
  # gets one multi-episode destination, which every covered episode references. Returns
  # {ep_id, dest, quality} per episode; a transient FS error halts and returns {:error, _} so the
  # grab retries the whole import next tick.
  defp link_all(to_import, root, target, folder?) do
    to_import
    |> Enum.group_by(fn {_ep, source} -> source end, fn {ep, _source} -> ep end)
    |> Enum.reduce_while({:ok, []}, fn {source, episodes}, {:ok, acc} ->
      episodes = Enum.sort_by(episodes, & &1.episode_number)

      case place_episode_file(episodes, source, root, target, folder?) do
        {:ok, dest, q} ->
          imported = Enum.map(episodes, &{&1.id, dest, q})
          {:cont, {:ok, Enum.reverse(imported, acc)}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp stage_all(to_import, root, target, folder?) do
    to_import
    |> Enum.group_by(fn {_ep, source} -> source end, fn {ep, _source} -> ep end)
    |> Enum.reduce_while({:ok, []}, fn {source, episodes}, {:ok, acc} ->
      episodes = Enum.sort_by(episodes, & &1.episode_number)

      case stage_episode_file(episodes, source, root, target, folder?) do
        {:ok, stage} ->
          imported = Enum.map(episodes, &{&1.id, stage})
          {:cont, {:ok, Enum.reverse(imported, acc)}}

        {:error, _} = error ->
          acc |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.dest) |> Enum.each(&rollback_stage/1)
          {:halt, error}
      end
    end)
  end

  defp place_episode_file([ep | _] = episodes, source, root, target, folder?) do
    dest = build_episode_dest(episodes, source, root)

    with {:ok, source} <- safe_source_file(source),
         {:ok, %{size: size, inode: si, major_device: sdev}} <- fs().lstat(source),
         parsed = Parser.parse(Path.basename(source)),
         new_q =
           new_quality(parsed, size)
           |> Map.merge(capture_media(source))
           |> Map.put_new(:sidecar_subtitles, []),
         {:ok, dest} <- safe_destination(dest, root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, q, placed?} <-
           place(source, dest, root, {si, sdev}, ep, new_q, false, fn ->
             ep_upgrade?(ep, new_q, target)
           end) do
      {:ok, dest, maybe_link_sidecars(q, placed?, folder?, source, dest)}
    end
  end

  defp stage_episode_file([ep | _] = episodes, source, root, target, folder?) do
    dest = build_episode_dest(episodes, source, root)

    with {:ok, source} <- safe_source_file(source),
         {:ok, %{size: size, inode: si, major_device: sdev}} <- fs().lstat(source),
         parsed = Parser.parse(Path.basename(source)),
         new_q =
           new_quality(parsed, size)
           |> Map.merge(capture_media(source))
           |> Map.put_new(:sidecar_subtitles, []),
         {:ok, dest} <- safe_destination(dest, root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, quality, rollback, placed?} <-
           stage_place(source, dest, root, {si, sdev}, ep, new_q, false, fn ->
             ep_upgrade?(ep, new_q, target)
           end) do
      quality = staged_sidecar_quality(quality, placed?, folder?, source)

      {:ok,
       %{
         dest: dest,
         quality: quality,
         rollback:
           Map.merge(rollback, %{
             after_commit: {:episodes, episodes},
             folder?: folder?,
             source: source
           })
       }}
    end
  end

  defp ep_upgrade?(ep, new_q, target) do
    Upgrade.better?(
      new_q,
      old_quality(ep),
      target,
      preferred_resolutions(:tv),
      preferred_sources(:tv)
    )
  end

  defp build_episode_dest([%Episode{season: season} | _] = episodes, source, root) do
    show = library_name(sanitize(season.series.title), season.series.year, season.series.tmdb_id)
    code = episode_code(episodes)

    Path.join([
      root,
      show,
      "Season #{Episode.pad(season.season_number)}",
      "#{show} - #{code}#{Path.extname(source)}"
    ])
  end

  defp episode_code([%Episode{} = ep]),
    do: Episode.code(ep.season.season_number, ep.episode_number)

  defp episode_code([%Episode{} = first | rest]) do
    last = List.last(rest)
    first_code = Episode.code(first.season.season_number, first.episode_number)

    if first.episode_number + length(rest) == last.episode_number do
      "#{first_code}-E#{Episode.pad(last.episode_number)}"
    else
      first_code <> Enum.map_join(rest, "", &"E#{Episode.pad(&1.episode_number)}")
    end
  end

  defp log_unmatched([]), do: :ok

  defp log_unmatched(paths) do
    Logger.warning("import skipped #{length(paths)} unmatched file(s): #{inspect(paths)}")
    :ok
  end

  # Best-effort: the file is already hardlinked into the library, so a failed scan —
  # an {:error, _} return OR a raise/exit from a misconfigured impl (e.g. a bad URL
  # deep in the HTTP stack) — must not strand a correctly-imported movie at
  # :import_failed. The media server picks it up on its next periodic scan. Log and
  # report the import as done.
  @doc "Requests a library scan and returns the configured media server's result."
  @spec scan(:movies | :tv) :: :ok | {:error, term()}
  def scan(kind), do: media_server().scan(kind)

  @doc false
  @spec refresh(:movies | :tv, String.t()) :: :ok
  def refresh(kind, dest) do
    case scan(kind) do
      {:error, reason} -> log_scan_failure(dest, reason)
      _ -> :ok
    end
  rescue
    e -> log_scan_failure(dest, e)
  catch
    caught, value -> log_scan_failure(dest, {caught, value})
  end

  defp log_scan_failure(dest, reason) do
    Logger.warning("media-server scan failed after importing #{dest}: #{inspect(reason)}")
  end

  # Dispatches the subtitle fetch on a supervised Task (fetch_after_import/4) so a slow OpenSubtitles
  # round-trip can't stall the import poller tick; the fetch's own errors are handled inside the task.
  # The dispatch is still wrapped best-effort — exactly like scan/2 — so even a supervisor hiccup
  # can't turn a correctly-placed file into :import_failed. `criteria_fun` is a thunk so it's built
  # inside the isolated task, not in the caller's argument.
  defp fetch_subtitles(criteria_fun, dest, kind, release_sidecar_languages)
       when is_function(criteria_fun, 0) do
    Cinder.Subtitles.fetch_after_import(criteria_fun, dest, kind, release_sidecar_languages)
  rescue
    e -> Logger.warning("subtitle fetch dispatch failed after importing #{dest}: #{inspect(e)}")
  catch
    kind, value ->
      Logger.warning(
        "subtitle fetch dispatch failed after importing #{dest}: #{inspect({kind, value})}"
      )
  end

  # Match each imported {episode_id, dest, quality} back to its Episode (for the series tmdb_id +
  # season/episode numbers) and fetch a subtitle for it; an id absent from `episodes` is skipped.
  defp fetch_episode_subtitles(imported, episodes) do
    by_id = Map.new(episodes, &{&1.id, &1})

    for {ep_id, dest, quality} <- imported, ep = by_id[ep_id], not is_nil(ep) do
      fetch_subtitles(
        fn -> Cinder.Subtitles.episode_criteria(ep) end,
        dest,
        :tv,
        Map.get(quality, :sidecar_subtitles, [])
      )
    end
  end

  defp fetch_episode_subtitles_for_dest(episodes, dest, quality) do
    imported = Enum.map(episodes, &{&1.id, dest, quality})
    fetch_episode_subtitles(imported, episodes)
  end

  # content_path is a file for single-file torrents, a folder for multi-file ones. Returns the
  # picked video plus whether the download was a folder (`folder?` gates sidecar linking).
  defp resolve_source(path) do
    case safe_walk(path) do
      {:ok, files} ->
        with {:ok, video} <- pick_video(files),
             {:ok, source} <- safe_source_file(video),
             do: {:ok, source, true}

      {:error, :enotdir} ->
        with {:ok, source} <- safe_source_file(path), do: {:ok, source, false}

      {:error, _reason} = error ->
        error
    end
  end

  # Largest video file wins (skips samples/extras); lexicographic path breaks ties
  # so the choice — and therefore the dest — is stable across retries.
  defp pick_video(files) do
    files
    |> Enum.filter(fn {p, _size} -> String.downcase(Path.extname(p)) in @video_exts end)
    |> Enum.sort_by(fn {p, size} -> {-size, p} end)
    |> case do
      [{path, _size} | _] -> {:ok, path}
      [] -> {:error, :no_video_file}
    end
  end

  defp build_dest(%Movie{title: title, year: year, tmdb_id: tmdb_id}, source, root) do
    name = library_name(sanitize(title), year, tmdb_id)
    Path.join([root, name, name <> Path.extname(source)])
  end

  # Plex's scheme is `Title (Year) {tmdb-<id>}`; with no year (a TMDB entry lacking a
  # release date) fall back to `Title {tmdb-<id>}`, and if the title sanitizes to
  # nothing (all-illegal characters) fall back to a bare tmdb id so the file lands in
  # its own folder rather than the library root.
  defp library_name("", _year, tmdb_id), do: "tmdb-#{tmdb_id}"
  defp library_name(title, nil, tmdb_id), do: "#{title} {tmdb-#{tmdb_id}}"
  defp library_name(title, year, tmdb_id), do: "#{title} (#{year}) {tmdb-#{tmdb_id}}"

  # Strip filesystem-illegal characters, then trim surrounding whitespace so a
  # title that is blank after sanitizing collapses to "" and hits the tmdb-id
  # fallback rather than producing a whitespace-named folder.
  defp sanitize(title) do
    title
    |> String.replace(@illegal, "")
    |> String.trim()
    |> reject_dot_only()
  end

  # A name that is only dots (".", "..", …) would become a path segment that escapes the library
  # root (`Path.join([root, "..", …])`). Collapse it to "" so library_name falls back to the
  # tmdb-id folder, same as an all-illegal title.
  defp reject_dot_only(name), do: if(name =~ ~r/\A\.+\z/, do: "", else: name)

  @doc """
  Deletes one imported library file and prunes the folders it leaves empty.

  Idempotent: a `nil`/blank path or an already-missing file is `:ok`. After unlinking, empty
  parent directories are removed walking up, stopping at (never removing) the configured library
  root — so a `Title (Year)/` or `Season NN/`→show folder disappears when it empties, but the root
  and any non-empty or out-of-library directory are untouched. A real unlink error (e.g. `:eacces`)
  is surfaced and nothing is pruned. Hardlink note: this frees disk space only once the download
  client also drops its copy. Paths outside the configured roots, symlink leaves, and paths with
  symlinked components fail closed with `{:error, :unsafe_delete}` before unlinking.
  """
  @spec delete_file(String.t() | nil) :: :ok | {:error, term()}
  def delete_file(path) when path in [nil, ""], do: :ok

  def delete_file(path) do
    roots = library_roots()

    with :ok <- path_policy().deletable_file(path, roots, filesystem: fs()) do
      do_delete_file(path)
    end
  end

  defp do_delete_file(path) do
    expanded = Path.expand(path)

    case fs().rm(expanded) do
      :ok -> prune_empty_dirs(Path.dirname(expanded))
      {:error, :enoent} -> prune_empty_dirs(Path.dirname(expanded))
      {:error, _reason} = err -> err
    end
  end

  # Remove `dir` if it is empty and strictly inside a library root, then recurse to its parent.
  # `fs().rmdir/1` only removes an empty dir, so a non-empty parent returns an error and halts the
  # walk. Always returns :ok — pruning is best-effort cleanup, never the operation's success signal.
  defp prune_empty_dirs(dir) do
    if prunable?(dir) and safe_directory?(dir) do
      case fs().rmdir(dir) do
        :ok -> prune_empty_dirs(Path.dirname(dir))
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  end

  # Prunable only when `dir` sits strictly inside a configured library root (never the root itself,
  # never a path outside any root) — so a misconfigured/old file_path can never rmdir outside the
  # library or delete a root. Split into a flat helper to keep credo Refactor.Nesting happy.
  defp prunable?(dir) do
    expanded = Path.expand(dir)
    Enum.any?(@kinds, &prunable_under_kind?(expanded, &1))
  end

  defp prunable_under_kind?(expanded, kind) do
    case root(kind) do
      {:ok, r} ->
        r = Path.expand(r)
        expanded != r and String.starts_with?(expanded <> "/", r <> "/")

      _ ->
        false
    end
  end

  defp safe_directory?(dir) do
    match?(
      {:ok, _expanded},
      path_policy().destination(dir, library_roots(), filesystem: fs())
    )
  end

  defp safe_source_file(path) do
    case Settings.import_roots() do
      [] -> {:error, :download_roots_not_configured}
      roots -> path_policy().source_file(path, roots, @video_exts, filesystem: fs())
    end
  end

  defp safe_walk(path) do
    case Settings.import_roots() do
      [] -> {:error, :download_roots_not_configured}
      roots -> path_policy().walk(path, roots: roots, filesystem: fs(), source: true)
    end
  end

  defp safe_destination(path, root),
    do: path_policy().destination(path, root, filesystem: fs())

  defp safe_remove(path, roots) do
    with :ok <- path_policy().deletable_file(path, roots, filesystem: fs()),
         do: fs().rm(path)
  end

  defp library_roots, do: Settings.library_roots()

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
  defp media_server, do: Application.fetch_env!(:cinder, :media_server)

  @doc false
  def path_policy, do: Application.get_env(:cinder, :path_policy, PathPolicy)

  # The configured import root for a kind, or {:error, :library_not_configured} when unset/blank —
  # used by both importers so an unconfigured root holds (poller retries) instead of raising. The
  # same shape for every kind: movies and TV are no longer special-cased.
  defp root(kind) do
    case Application.get_env(:cinder, :"#{kind}_library_path") do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :library_not_configured}
    end
  end
end
