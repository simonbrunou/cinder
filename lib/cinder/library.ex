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
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, GrabFile, Movie, Series}

  alias Cinder.Library.{
    AnimePreflight,
    ImportStage,
    Naming,
    PathPolicy,
    PolicyVerifier,
    Sidecars,
    StageEngine,
    Upgrade
  }

  alias Cinder.Settings

  @video_exts ~w(.mkv .mp4 .avi .m4v .mov .wmv .ts)

  # link(2) errnos that mean "this dest can't be hardlinked to" — fall back to an atomic byte copy
  # rather than parking. `:exdev` = source and dest on different mounts. `:eperm`/`:eopnotsupp`/
  # `:enotsup` = a single mount whose filesystem has no hardlink support at all (FAT/exFAT on USB
  # drives, SMB/CIFS without Unix extensions, some FUSE), where `link()` fails without `:exdev` ever
  # firing (issue #59). `:eperm` can also be a genuine permission error, but then the copy fails the
  # same way (`cp` can't open the dest) and the item still parks — a wasted copy attempt, not a
  # wrong import. Every other errno (`:enoent`, `:enospc`, …) is a real failure and propagates.
  @copy_fallback_errnos [:exdev, :eperm, :eopnotsupp, :enotsup]
  @anime_identity_keys ~w(relative_path size major_device inode mtime)
  @standard_tv_bridged_schemes ~w(scene aired)

  # The library kinds Cinder manages. The single source of truth — config keys
  # (`:"#{kind}_library_path"`, the per-kind Plex section, the size band), the
  # settings UI, health checks, and the media-server scan all derive from it, so a
  # new media type (e.g. `:books`) is one entry here, not a fork. Pure literal:
  # read at boot and at config-eval time, so it must not touch Application env or Repo.
  @kinds [:movies, :tv]

  @doc "The library kinds Cinder manages (e.g. `:movies`, `:tv`)."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Whether `path` has a video extension supported by the library importer."
  def video_file?(path),
    do: String.downcase(Path.extname(path)) in @video_exts

  @doc "Stages a movie import with rollback material for a guarded Catalog transition."
  @spec stage_movie(Movie.t(), keyword()) ::
          {:ok, %{dest: String.t(), rollback: map(), quality: map()}} | {:error, term()}
  def stage_movie(movie, opts \\ [])

  def stage_movie(%Movie{} = movie, opts) do
    case Movie.download_source(movie) do
      path when path in [nil, ""] -> {:error, :no_file_path}
      path -> do_stage_movie(movie, path, opts)
    end
  end

  defp do_stage_movie(movie, path, opts) do
    replace? = Keyword.get(opts, :replace, false)

    with {:ok, root} <- root(:movies),
         {:ok, source, folder?} <- resolve_source(path),
         {:ok, reports} <- verify_movie_policy(movie, source),
         {:ok, %{size: size, inode: si, major_device: sdev}} <- fs().lstat(source),
         parsed = Parser.parse(Path.basename(path)),
         new_q =
           new_quality(parsed, size)
           |> Map.merge(cached_or_capture_media(source, reports))
           |> Map.put_new(:sidecar_subtitles, []),
         dest = Naming.movie_dest(movie, source, root),
         {:ok, dest} <- safe_destination(dest, root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, quality, rollback, placed?} <-
           StageEngine.stage_place(source, dest, root, {si, sdev}, movie, new_q, replace?, fn ->
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
    if StageEngine.claim_post_commit_effects(rollback) do
      maybe_commit_sidecars(rollback, dest)
      run_after_commit(rollback, dest, quality)
    end

    StageEngine.commit(rollback)
  end

  @doc "Rolls a staged import back. Safe to call repeatedly."
  @spec rollback_stage(%{rollback: map()}) :: :ok | {:error, term()}
  def rollback_stage(%{rollback: rollback}), do: StageEngine.rollback(rollback)

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
    Enum.each(ImportStage.list(), &StageEngine.reconcile_stage(&1.id, :auto))

    :ok
  end

  @doc "Lists quarantined import journals for operator inspection."
  @spec quarantined_import_stages() :: [map()]
  def quarantined_import_stages, do: ImportStage.quarantined()

  @doc "Releases a quarantined import journal for a safe retry without discarding its files."
  @spec retry_import_stage(pos_integer()) :: {:ok, map()} | {:error, term()}
  def retry_import_stage(id), do: ImportStage.retry_quarantined(id)

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

  # A never-before-imported record (nil_q?) whose computed dest already holds a file we're not
  # overwriting is the delete-and-re-add case (issue #128): the pre-existing sidecars at dest are
  # real, so scan them the same way a fresh placement's maybe_link_sidecars/5 would, instead of
  # defaulting new_q's sidecar_subtitles to "[]" just because nothing was freshly linked. A record
  # that's already been imported before keeps its stored quality untouched. Public (not private):
  # also called from `Cinder.Library.StageEngine`.
  @doc false
  def existing_quality(record, new_q, dest) do
    if nil_q?(record), do: adopt_quality(new_q, dest), else: old_quality(record)
  end

  defp adopt_quality(new_q, dest) do
    languages = dest |> Sidecars.files() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    Map.put(new_q, :sidecar_subtitles, languages)
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
      sidecar_subtitles: record.imported_sidecar_subtitles,
      # Map.get: only Movie has this column; old_quality/1 also serves Episode.
      default_audio_language: Map.get(record, :imported_default_audio_language)
    }
  end

  defp new_quality(parsed, size) do
    %{resolution: parsed.resolution, source: parsed.source, size: size, language: parsed.language}
  end

  # Probe the source's audio + embedded-subtitle languages for storage on the imported row. Empty
  # lists when media_info is disabled or the probe errors — never blocks the import. Runs on every
  # import (folder or single-file); the release's sidecar languages are captured separately —
  # by maybe_link_sidecars/5 (a folder scan) when a fresh file is actually placed, or by
  # adopt_quality/2 (a dest scan) when a never-imported record adopts an already-present file
  # (issue #128).
  defp capture_media(source) do
    case media_info() do
      nil -> empty_media()
      impl -> probe_media(impl, source)
    end
  end

  defp cached_or_capture_media(source, reports) do
    case Map.fetch(reports, source) do
      {:ok, report} -> captured_media(report)
      :error -> capture_media(source)
    end
  end

  # Map.get: `default_audio` is an optional key on the behaviour, so a Mox stub returning only
  # audio/subtitles stays valid (issue #197).
  defp captured_media(%{audio: audio, subtitles: subtitles} = report),
    do: %{
      audio_languages: audio,
      embedded_subtitles: subtitles,
      default_audio_language: Map.get(report, :default_audio)
    }

  defp empty_media,
    do: %{audio_languages: [], embedded_subtitles: [], default_audio_language: nil}

  defp probe_media(impl, source) do
    case impl.probe(source) do
      {:ok, %{audio: _, subtitles: _} = report} ->
        captured_media(report)

      other ->
        # Degrading to empty metadata is deliberate — but a broken/missing ffprobe must be
        # diagnosable: silently-empty fields read as "the file has no tags", not "the probe
        # is broken" (media_info is on by default, and there is no health row for it).
        Logger.warning("media-info probe failed for #{source}: #{inspect(other)}")
        empty_media()
    end
  end

  # Hardlink the release's sidecar subtitles next to a freshly-placed dest and record their
  # languages — only when the file was actually placed (`placed?`, not a keep/idempotent no-op)
  # AND the download was a folder (`folder?`); a single-file download ships no sidecars. Best-effort
  # via Sidecars.link/2, which never raises. Otherwise the quality's `sidecar_subtitles` stays as it
  # was: the stored value on the keep branch's old_quality, or on the adopt branch the dest-scanned
  # value from adopt_quality/2 (issue #128) rather than new_q's fresh `[]`.
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

  # Public (not private): also called from `Cinder.Library.StageEngine`.
  @doc false
  def keep(dest, movie, new_q) do
    old_q = existing_quality(movie, new_q, dest)

    Logger.warning(
      "kept existing #{inspect(old_q.resolution)} file at #{dest}; new release not an upgrade"
    )

    {:ok, old_q, false}
  end

  # Both reads live in Upgrade, which also ranks against them — one definition, no drift.
  defp preferred_resolutions(kind), do: Upgrade.preferred_resolutions(kind)
  defp preferred_sources(kind), do: Upgrade.preferred_sources(kind)

  # Atomic replace of an existing dest with source's content: sweep stale temps (a host crash between
  # link/copy and rename can leak one), link-or-copy source -> unique temp in the dest dir, then rename
  # over dest. The temp lives on the dest filesystem, so the rename is same-fs and atomic even when the
  # source content had to be copied across filesystems. Public (not private): also called from
  # `Cinder.Library.StageEngine`.
  @doc false
  def replace(source, dest, root) do
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
  # single choke-point and covers every fallback (per docs/operating.md). Public (not private):
  # also called from `Cinder.Library.StageEngine`.
  @doc false
  def link_or_copy(source, target, root) do
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

  defp verify_movie_policy(%Movie{release_policy_snapshot: snapshot}, source)
       when is_map(snapshot),
       do: verify_release_policy([source], snapshot)

  defp verify_movie_policy(%Movie{} = movie, source) do
    case verify_audio(
           source,
           Language.target(movie.preferred_language, movie.original_language)
         ) do
      :ok -> {:ok, %{}}
      {:error, _reason} = error -> error
    end
  end

  defp verify_release_policy(paths, snapshot) do
    case PolicyVerifier.verify_sources(paths, snapshot, media_info()) do
      {:ok, reports} -> {:ok, reports}
      {:mismatch, evidence} -> {:error, {:release_policy_mismatch, evidence}}
      {:unavailable, reason} -> {:error, {:release_policy_unavailable, reason}}
    end
  end

  defp media_info, do: Application.get_env(:cinder, :media_info)

  @doc """
  Imports the video files at `content_path` for `episodes` (a grab's episodes, each preloaded
  `season: :series`). Returns `{:ok, imported, unmatched}` — `imported` is
  `[{episode_id, dest_path, quality}]` where `quality = %{resolution:, size:, language:}`,
  `unmatched` the video files that mapped to no episode (logged,
  not an error: graceful park) — or `{:error, reason}` on a transient filesystem error (the grab
  retries). One best-effort scan fires when anything imported.

  Layout: `Show (Year)/Season NN/Show (Year) - SxxEyy.ext`. Files are matched by parsing `SxxEyy`
  from each name and intersecting with the grab's native episode numbers or exact persisted
  `scene`/TVDB `aired` coordinates (a double-episode file maps to both). When an episode has both
  alternate schemes, operator-selected `scene` wins over migration-inferred `aired`.
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

  @doc """
  Stages standard-TV imports with rollback material for `Catalog.commit_grab_imports/3`.

  `arbitrate: true` (the unattended upgrade sweep, `Grab.arbitrate_at_import`) makes THIS import
  the arbiter of every swap: an episode that already holds a file keeps it unless the incoming
  release beats it. The default forces the swap, which is what the manual path wants — the
  operator picked that release, possibly for something the ranking can't see (#250).

  `already_held:` is the series' episodes that already have a file. A video claimed by one of
  them is dropped rather than reported unmatched, so a pack grabbed for the *wanted* half of a
  season doesn't turn the other half's files into operator decisions (#251).
  """
  @spec stage_episodes(String.t() | nil, [Episode.t()], keyword()) ::
          {:ok, [{integer(), map()}], [String.t()]} | {:error, term()}
  def stage_episodes(content_path, episodes, opts \\ [])

  def stage_episodes(content_path, _episodes, _opts) when content_path in [nil, ""],
    do: {:error, :no_content_path}

  def stage_episodes(content_path, episodes, opts) do
    collision = if Keyword.get(opts, :arbitrate, false), do: :arbitrate, else: :force

    with {:ok, root} <- root(:tv),
         {:ok, videos, folder?} <- video_files(content_path) do
      {to_import, unmatched} =
        videos
        |> match_episodes(episodes)
        |> dedupe_per_episode()
        |> resolve(videos, episodes)
        |> reject_wrong_audio(episodes)
        |> drop_already_held(videos, Keyword.get(opts, :already_held, []))

      case stage_all(to_import, root, episode_target(episodes), folder?, collision) do
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

  @doc "Builds restart-safe rows for standard-TV video files that staging could not match."
  @spec inventory_grab_files(String.t(), [String.t()], [Episode.t()]) ::
          {:ok, [map()]} | {:error, term()}
  def inventory_grab_files(content_path, paths, episodes) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, files} ->
      case inventory_grab_file(content_path, path, episodes) do
        {:ok, file} -> {:cont, {:ok, [file | files]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Stages one operator-selected residual video at a canonical episode part destination.

  The inventoried device/inode/size must still match; a changed source fails before staging.
  """
  def stage_grab_file_part(
        %Grab{content_path: content_path},
        %GrabFile{} = file,
        %Episode{file_path: primary} = episode
      )
      when is_binary(content_path) and content_path != "" and is_binary(primary) and primary != "" do
    with {:ok, root} <- root(:tv),
         {:ok, source, folder?} <- grab_file_source(content_path, file.relative_path),
         {:ok, stat} <- fs().lstat(source),
         :ok <- verify_grab_file_identity(file, stat),
         dest = Naming.episode_part_dest(episode, source, root, file.id),
         {:ok, stage} <-
           stage_episode_file_at(
             [episode],
             source,
             root,
             folder?,
             %{},
             dest,
             :adopt,
             fn _new_quality -> false end
           ) do
      if stage.placed? do
        {:ok, Map.delete(stage, :placed?)}
      else
        rollback_stage(stage)
        {:error, :part_destination_occupied}
      end
    end
  end

  def stage_grab_file_part(%Grab{}, %GrabFile{}, %Episode{}),
    do: {:error, :primary_file_missing}

  defp grab_file_source(content_path, relative_path) do
    content_path = Path.expand(content_path)

    if fs().dir?(content_path) do
      grab_file_source_in_directory(content_path, relative_path)
    else
      grab_file_single_source(content_path, relative_path)
    end
  end

  defp grab_file_source_in_directory(content_path, relative_path) do
    source = Path.expand(relative_path, content_path)
    relative = Path.relative_to(source, content_path)

    if relative == ".." or String.starts_with?(relative, "../") do
      {:error, :unsafe_source}
    else
      with {:ok, source} <- safe_source_file(source), do: {:ok, source, true}
    end
  end

  defp grab_file_single_source(content_path, relative_path) do
    if Path.basename(content_path) == relative_path do
      with {:ok, source} <- safe_source_file(content_path), do: {:ok, source, false}
    else
      {:error, :inventory_changed}
    end
  end

  defp verify_grab_file_identity(file, stat) do
    if {file.device, file.inode, file.size} ==
         {stat.major_device, stat.inode, stat.size},
       do: :ok,
       else: {:error, :inventory_changed}
  end

  defp inventory_grab_file(content_path, path, episodes) do
    with {:ok, source} <- safe_source_file(path),
         {:ok, stat} <- fs().lstat(source),
         folder? = Path.expand(source) != Path.expand(content_path),
         {:ok, relative_path} <- inventory_relative_path(source, content_path, folder?) do
      {:ok,
       %{
         relative_path: relative_path,
         size: stat.size,
         device: stat.major_device,
         inode: stat.inode
       }
       |> Map.merge(standard_provider_evidence(source, episodes))}
    end
  end

  defp standard_provider_evidence(
         path,
         [%Episode{season: %{series: %Series{tvdb_id: tvdb_id}}} | _]
       )
       when is_integer(tvdb_id) do
    case Parser.parse(Path.basename(path)) do
      %{season: season, episodes: [episode]}
      when is_integer(season) and is_integer(episode) ->
        %{
          source: "tvdb",
          scheme: "aired",
          namespace: Integer.to_string(tvdb_id),
          canonical_value: Episode.code(season, episode)
        }

      _unidentified ->
        %{}
    end
  end

  defp standard_provider_evidence(_path, _episodes), do: %{}

  @doc "Inventories anime videos without exposing their absolute source paths."
  def inventory_anime_videos(content_path) do
    with {:ok, videos, folder?} <- video_files(content_path),
         {:ok, files} <- inventory_anime_files(videos, content_path, folder?) do
      {:ok, %{files: Enum.sort_by(files, & &1.relative_path), folder?: folder?}}
    end
  end

  @doc "Runs anime mapping preflight and persists its evidence before import staging."
  def preflight_anime_grab(%Grab{} = grab) do
    episodes =
      Enum.map(grab.episodes, fn episode ->
        %{
          id: episode.id,
          season_number: episode.season.season_number,
          episode_number: episode.episode_number
        }
      end)

    with {:ok, inventory} <- inventory_anime_videos(grab.content_path),
         result = AnimePreflight.run(grab.mapping_snapshot, inventory.files, episodes),
         {:ok, persisted} <- Catalog.record_mapping_result(grab, result) do
      attach_preflight_grab(result, persisted, inventory.folder?)
    end
  end

  @doc "Stages persisted anime assignments after revalidating the download inventory."
  def stage_anime_episodes(%Grab{} = grab, preflight) do
    with {:ok, current} <- inventory_anime_videos(grab.content_path),
         :ok <- same_inventory(current.files, preflight.decisions),
         :ok <- same_container_kind(current.folder?, preflight.folder?),
         {:ok, root} <- root(:tv),
         {:ok, to_import} <-
           anime_import_pairs(grab, preflight.assignments, current.folder?),
         {:ok, reports} <- verify_grab_policy(grab, to_import) do
      stage_anime_all(to_import, root, episode_target(grab.episodes), current.folder?, reports)
    else
      {:error, :inventory_changed} -> {:restart_preflight, :inventory_changed}
      {:error, _reason} = error -> error
    end
  end

  defp attach_preflight_grab({:ok, preflight}, grab, folder?),
    do: {:ok, preflight |> Map.put(:grab, grab) |> Map.put(:folder?, folder?)}

  defp attach_preflight_grab({:needs_mapping, preflight}, grab, _folder?),
    do: {:needs_mapping, Map.put(preflight, :grab, grab)}

  defp same_container_kind(container?, container?), do: :ok
  defp same_container_kind(_current, _persisted), do: {:error, :inventory_changed}

  defp same_inventory(current, %{"files" => persisted}) when is_list(persisted) do
    current =
      Enum.map(current, fn %{relative_path: relative_path, identity: identity} ->
        identity
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.put("relative_path", relative_path)
      end)

    persisted = Enum.map(persisted, &Map.take(&1, @anime_identity_keys))

    if sort_inventory(current) == sort_inventory(persisted),
      do: :ok,
      else: {:error, :inventory_changed}
  end

  defp same_inventory(_current, _persisted), do: {:error, :inventory_changed}

  defp sort_inventory(files), do: Enum.sort_by(files, & &1["relative_path"])

  defp anime_import_pairs(%Grab{} = grab, assignments, folder?) do
    episodes = Map.new(grab.episodes, &{&1.id, &1})

    assignments
    |> Enum.reduce_while({:ok, []}, fn assignment, {:ok, acc} ->
      case anime_assignment_pairs(grab.content_path, folder?, assignment, episodes) do
        {:ok, pairs} -> {:cont, {:ok, Enum.reverse(pairs, acc)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _reason} = error -> error
    end
  end

  defp anime_assignment_pairs(
         content_path,
         folder?,
         %{relative_path: relative_path, episode_ids: episode_ids},
         episodes
       ) do
    with {:ok, source} <- anime_assignment_source(content_path, relative_path, folder?),
         {:ok, assigned} <- assigned_episodes(episode_ids, episodes) do
      {:ok, Enum.map(assigned, &{&1, source})}
    end
  end

  defp anime_assignment_pairs(_content_path, _folder?, _assignment, _episodes),
    do: {:error, :invalid_anime_assignment}

  defp anime_assignment_source(content_path, relative_path, true),
    do: content_path |> Path.join(relative_path) |> revalidate_anime_source()

  defp anime_assignment_source(content_path, relative_path, false) do
    if relative_path == Path.basename(content_path),
      do: revalidate_anime_source(content_path),
      else: {:error, :invalid_anime_assignment}
  end

  defp revalidate_anime_source(path) do
    case safe_source_file(path) do
      {:ok, _source} = ok -> ok
      {:error, :download_roots_not_configured} = error -> error
      {:error, _reason} -> {:error, :inventory_changed}
    end
  end

  defp assigned_episodes(ids, episodes) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Map.fetch(episodes, id) do
        {:ok, episode} -> {:cont, {:ok, [episode | acc]}}
        :error -> {:halt, {:error, :invalid_anime_assignment}}
      end
    end)
    |> case do
      {:ok, assigned} -> {:ok, Enum.reverse(assigned)}
      {:error, _reason} = error -> error
    end
  end

  defp verify_grab_policy(%Grab{release_policy_snapshot: snapshot}, to_import)
       when is_map(snapshot) do
    paths = to_import |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    verify_release_policy(paths, snapshot)
  end

  defp verify_grab_policy(%Grab{}, _to_import), do: {:ok, %{}}

  defp inventory_anime_files(videos, content_path, folder?) do
    videos
    |> Enum.reduce_while({:ok, []}, fn {path, _size}, {:ok, files} ->
      case inventory_anime_file(path, content_path, folder?) do
        {:ok, file} -> {:cont, {:ok, [file | files]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.map(files, &inventory_entry/1)}
      {:error, _reason} = error -> error
    end
  end

  defp inventory_anime_file(path, content_path, folder?) do
    with {:ok, source} <- safe_source_file(path),
         {:ok, stat} <- fs().lstat(source),
         {:ok, relative_path} <- inventory_relative_path(source, content_path, folder?) do
      {:ok, {source, relative_path, stat}}
    end
  end

  defp inventory_relative_path(source, _content_path, false), do: {:ok, Path.basename(source)}

  defp inventory_relative_path(source, content_path, true) do
    relative_path = Path.relative_to(source, Path.expand(content_path))

    if relative_path == ".." or String.starts_with?(relative_path, "../"),
      do: {:error, :unsafe_source},
      else: {:ok, relative_path}
  end

  defp inventory_entry({_source, relative_path, stat}) do
    %{
      relative_path: relative_path,
      identity: %{
        size: stat.size,
        major_device: stat.major_device,
        inode: stat.inode,
        mtime: stat.mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_iso8601()
      }
    }
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
  # A season pack grabbed for the WANTED half of a season also delivers the half we already hold.
  # Those files claim no linked episode, so they used to land in `grab_files` as undecided
  # residuals: an operator hold, one click per file, for episodes we already have (#251). The
  # residual UI exists for files we can't identify — these we can, so drop them. Anything naming
  # an episode we don't hold, naming nothing, or naming another series stays a residual.
  defp drop_already_held(result, _videos, []), do: result

  defp drop_already_held({to_import, unmatched}, videos, already_held) do
    claimed =
      videos
      |> Enum.filter(fn {path, _size} -> path in unmatched end)
      |> match_episodes(already_held)
      |> MapSet.new(fn {_ep, path, _size} -> path end)

    case Enum.split_with(unmatched, &MapSet.member?(claimed, &1)) do
      {[], ^unmatched} -> {to_import, unmatched}
      {dropped, kept} -> {to_import, log_already_held(dropped, kept)}
    end
  end

  defp log_already_held(dropped, kept) do
    Logger.info(
      "import: dropped #{length(dropped)} file(s) for episodes already in the library: " <>
        inspect(Enum.map(dropped, &Path.basename/1))
    )

    kept
  end

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
    do: Enum.filter(files, fn {path, _size} -> video_file?(path) end)

  # {episode, source_path, size} triples for files that name a specific episode in the grab. A
  # double-episode file yields two entries; `link_all/4` groups them back to one library file.
  defp match_episodes(videos, episodes) do
    episodes = prefer_scene_coordinates(episodes)

    matches =
      for {path, size} <- videos,
          parsed = Parser.parse(Path.basename(path)),
          not is_nil(parsed.episodes),
          ep <- episodes,
          arm = match_arm(ep, parsed),
          do: {ep, path, size, arm}

    matches
    |> Enum.group_by(fn {_ep, path, _size, _arm} -> path end)
    |> Enum.flat_map(&single_arm_claims/1)
  end

  # Never guess: a file claimed through conflicting native/bridged numbering arms is ambiguous,
  # so leave it unmatched (logged, parks) rather than file one source onto two episodes.
  defp single_arm_claims({path, claims}) do
    case claims |> Enum.map(fn {_ep, _p, _size, arm} -> arm end) |> Enum.uniq() do
      [_one_arm] ->
        Enum.map(claims, fn {ep, p, size, _arm} -> {ep, p, size} end)

      _both ->
        Logger.warning(
          "import: #{Path.basename(path)} matches different episodes via native and " <>
            "alternate numbering; leaving unmatched"
        )

        []
    end
  end

  # An episode claims a parsed file through exactly one arm: its native TMDB numbering, or one
  # persisted alternate numbering scheme bridged at import. nil = no claim.
  defp match_arm(episode, parsed) do
    cond do
      episode.season.season_number == parsed.season and
          episode.episode_number in parsed.episodes ->
        :native

      scheme = bridged_coordinate_scheme(episode, parsed) ->
        {:bridged, scheme}

      true ->
        nil
    end
  end

  defp bridged_coordinate_scheme(%Episode{episode_coordinates: coordinates}, parsed)
       when is_list(coordinates) do
    Enum.find(@standard_tv_bridged_schemes, fn scheme ->
      Enum.any?(coordinates, fn coordinate ->
        coordinate.scheme == scheme and
          Enum.any?(
            parsed.episodes,
            &(coordinate.canonical_value == Episode.code(parsed.season, &1))
          )
      end)
    end)
  end

  defp bridged_coordinate_scheme(_episode, _parsed), do: nil

  defp prefer_scene_coordinates(episodes) do
    Enum.map(episodes, fn
      %Episode{episode_coordinates: coordinates} = episode when is_list(coordinates) ->
        if Enum.any?(coordinates, &(&1.scheme == "scene")) do
          %{episode | episode_coordinates: Enum.reject(coordinates, &(&1.scheme == "aired"))}
        else
          episode
        end

      episode ->
        episode
    end)
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
  # (so we never mistake a clearly-numbered other episode for ours). See
  # Cinder.Library.AnimePreflight.infer_lone_file/3 for anime's stricter analogue.
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

  # `keeps` (held path => its noop stage) is threaded across every group on purpose: two episodes
  # sharing one `file_path` can decline in one group (a combined incoming file) or in two (the
  # pack ships them separately), and `import_stages.dest` is globally unique either way.
  defp stage_all(to_import, root, target, folder?, collision) do
    to_import
    |> Enum.group_by(fn {_ep, source} -> source end, fn {ep, _source} -> ep end)
    |> Enum.reduce_while({:ok, [], %{}}, fn {source, episodes}, {:ok, acc, keeps} ->
      episodes = Enum.sort_by(episodes, & &1.episode_number)

      case stage_group(episodes, source, root, target, folder?, collision, keeps) do
        {:ok, imported, keeps} ->
          {:cont, {:ok, Enum.reverse(imported, acc), keeps}}

        {:error, _} = error ->
          acc |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.dest) |> Enum.each(&rollback_stage/1)
          {:halt, error}
      end
    end)
    |> case do
      {:ok, imported, _keeps} -> {:ok, imported}
      {:error, _reason} = error -> error
    end
  end

  # A staged file is indivisible — one source can cover several episodes (an S01E01E02 file), and
  # it replaces every episode it covers or none of them. So the arbitrated decision is taken here,
  # for the WHOLE group, before anything is staged. Deciding per stage would be wrong twice over:
  # the gate would consult only the group's first episode, and a decline would re-point every row
  # in the group at that one episode's file — leaving the others' files unreferenced for
  # `remove_superseded_episode_files/1` to delete.
  defp stage_group(episodes, source, root, target, folder?, :arbitrate, keeps) do
    case arbitration_quality(source) do
      {:ok, new_q} ->
        if Enum.all?(episodes, &ep_upgrade?(&1, new_q, target)) do
          stage_group(episodes, source, root, target, folder?, :adopt, keeps)
        else
          keep_held_files(episodes, source, root, keeps)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp stage_group(episodes, source, root, target, folder?, collision, keeps) do
    case stage_episode_file(episodes, source, root, target, folder?, %{}, collision) do
      {:ok, stage} -> {:ok, Enum.map(episodes, &{&1.id, stage}), keeps}
      {:error, _reason} = error -> error
    end
  end

  # Only the four fields `Upgrade.better?/5` ranks on, so this skips the media-info probe
  # `stage_episode_file_at/8` runs — audio and subtitle languages never enter the comparison.
  defp arbitration_quality(source) do
    with {:ok, source} <- safe_source_file(source),
         {:ok, %{size: size}} <- fs().lstat(source) do
      {:ok, new_quality(Parser.parse(Path.basename(source)), size)}
    end
  end

  # The declined group: every episode that holds a file gets a noop stage pinned to THAT file, so
  # it keeps its own path and recorded quality and still counts as imported — otherwise
  # `commit_grab_imports/4` would bump it as missing. An episode in the group holding nothing gets
  # nothing: the file is one unit and we just declined it, so that episode stays wanted and
  # re-searches.
  # One stage per distinct HELD PATH across the whole import, never one per episode:
  # `import_stages.dest` is globally unique and two episodes legitimately share a `file_path` —
  # that is exactly what a previously imported double-episode file leaves behind. A stage each
  # would collide on the second insert, fail the whole grab, and leave the first one's `:prepared`
  # row holding that dest until its handoff deadline, so retries inside that window would fail
  # identically. The stage fans back out to every episode on that path, as `stage_group/7` already
  # does for placements.
  defp keep_held_files(episodes, source, root, keeps) do
    held = Enum.filter(episodes, &(&1.file_path not in [nil, ""]))

    held
    |> Enum.uniq_by(& &1.file_path)
    |> Enum.reduce_while({:ok, [], keeps}, &keep_held_file(&1, &2, held, source, root))
  end

  defp keep_held_file(ep, {:ok, acc, keeps}, held, source, root) do
    case keep_stage(ep, source, root, keeps) do
      {:ok, stage} ->
        rows = for e <- held, e.file_path == ep.file_path, do: {e.id, stage}
        {:cont, {:ok, rows ++ acc, Map.put(keeps, ep.file_path, stage)}}

      {:error, _reason} = error ->
        # Release the dests this group already claimed, or the retry collides with itself.
        acc |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.dest) |> Enum.each(&rollback_stage/1)
        {:halt, error}
    end
  end

  # `placed?` survives on these stages (the other builders strip it): it is what tells
  # `commit_grab_imports/4` the episode's file did not change, so its part files must be carried
  # through rather than cleared.
  defp keep_stage(ep, source, root, keeps) do
    case Map.fetch(keeps, ep.file_path) do
      {:ok, stage} ->
        {:ok, stage}

      :error ->
        decline = fn _new_quality -> false end
        stage_episode_file_at([ep], source, root, false, %{}, ep.file_path, :adopt, decline)
    end
  end

  defp stage_anime_all(to_import, root, target, folder?, reports) do
    to_import
    |> Enum.group_by(
      fn {episode, source} -> {source, episode.season.season_number} end,
      fn {episode, _source} -> episode end
    )
    |> Enum.sort_by(fn {{source, season}, _episodes} -> {source, season} end)
    |> Enum.reduce_while({:ok, []}, fn {{source, _season}, episodes}, {:ok, acc} ->
      episodes = Enum.sort_by(episodes, & &1.episode_number)

      case stage_episode_file(episodes, source, root, target, folder?, reports, :force) do
        {:ok, stage} ->
          rows = Enum.map(episodes, &{&1.id, stage})
          {:cont, {:ok, Enum.reverse(rows, acc)}}

        {:error, _reason} = error ->
          acc |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.dest) |> Enum.each(&rollback_stage/1)
          {:halt, error}
      end
    end)
  end

  defp place_episode_file([ep | _] = episodes, source, root, target, folder?) do
    dest = Naming.episode_dest(episodes, source, root)

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
           StageEngine.place(source, dest, root, {si, sdev}, ep, new_q, false, fn ->
             ep_upgrade?(ep, new_q, target)
           end) do
      {:ok, dest, maybe_link_sidecars(q, placed?, folder?, source, dest)}
    end
  end

  defp stage_episode_file([ep | _] = episodes, source, root, target, folder?, reports, collision) do
    dest = Naming.episode_dest(episodes, source, root)

    collision =
      if collision == :force and Enum.all?(episodes, &(&1.file_path in [nil, ""])),
        do: :adopt,
        else: collision

    case stage_episode_file_at(
           episodes,
           source,
           root,
           folder?,
           reports,
           dest,
           collision,
           fn new_quality -> ep_upgrade?(ep, new_quality, target) end
         ) do
      {:ok, stage} -> {:ok, Map.delete(stage, :placed?)}
      {:error, _reason} = error -> error
    end
  end

  # `collision` decides what happens when a file already sits at `dest`. Only `:force` (the manual
  # path, and anime) and `:adopt` reach here — `:arbitrate` is settled a level up, in
  # `stage_group/6`, because the choice belongs to the whole group and not to one stage.
  #   :force — swap it, no questions.
  #   :adopt — leave StageEngine's own gate to settle it (nothing is held, or the group already
  #            decided and passed a `upgrade_fun` that says so).
  defp stage_episode_file_at(
         [ep | _] = episodes,
         source,
         root,
         folder?,
         reports,
         dest,
         collision,
         upgrade_fun
       ) do
    with {:ok, source} <- safe_source_file(source),
         {:ok, %{size: size, inode: si, major_device: sdev}} <- fs().lstat(source),
         parsed = Parser.parse(Path.basename(source)),
         new_q =
           new_quality(parsed, size)
           |> Map.merge(cached_or_capture_media(source, reports))
           |> Map.put_new(:sidecar_subtitles, []),
         {:ok, dest} <- safe_destination(dest, root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, quality, rollback, placed?} <-
           StageEngine.stage_place(
             source,
             dest,
             root,
             {si, sdev},
             ep,
             new_q,
             collision == :force,
             fn -> upgrade_fun.(new_q) end
           ) do
      quality = staged_sidecar_quality(quality, placed?, folder?, source)

      {:ok,
       %{
         dest: dest,
         quality: quality,
         placed?: placed?,
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
  # One fetch per physical file: a combined-episode file (S01E01-E02) maps every covered episode
  # to the same dest, and concurrent fetches would race/overwrite the shared sidecar (issue #141)
  # — the lowest-numbered covered episode names the provider query.
  defp fetch_episode_subtitles(imported, episodes) do
    by_id = Map.new(episodes, &{&1.id, &1})

    imported
    |> Enum.filter(fn {ep_id, _dest, _quality} -> not is_nil(by_id[ep_id]) end)
    |> Enum.group_by(fn {_ep_id, dest, _quality} -> dest end)
    |> Enum.each(fn {dest, group} ->
      {ep_id, _dest, quality} =
        Enum.min_by(group, fn {ep_id, _dest, _quality} ->
          ep = by_id[ep_id]
          {ep.season.season_number, ep.episode_number}
        end)

      fetch_subtitles(
        fn -> Cinder.Subtitles.episode_criteria(by_id[ep_id]) end,
        dest,
        :tv,
        Map.get(quality, :sidecar_subtitles, [])
      )
    end)
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
    |> Enum.filter(fn {path, _size} -> video_file?(path) end)
    |> Enum.sort_by(fn {p, size} -> {-size, p} end)
    |> case do
      [{path, _size} | _] -> {:ok, path}
      [] -> {:error, :no_video_file}
    end
  end

  @doc "Deletes one imported library file and prunes the folders it leaves empty."
  defdelegate delete_file(path), to: Cinder.Library.Deletion

  @doc "Deletes a completed download's source directory after a successful `move_on_import`."
  defdelegate delete_download_source(path), to: Cinder.Library.Deletion

  defp safe_source_file(path) do
    case Settings.import_roots() do
      [] -> {:error, :download_roots_not_configured}
      roots -> path_policy().source_file(path, roots, @video_exts, filesystem: fs())
    end
  end

  defp safe_walk(path) do
    case Settings.import_roots() do
      [] -> {:error, :download_roots_not_configured}
      roots -> path_policy().walk(path, roots: roots, filesystem: fs())
    end
  end

  defp safe_destination(path, root),
    do: path_policy().destination(path, root, filesystem: fs())

  defp safe_remove(path, roots) do
    with :ok <- path_policy().deletable_file(path, roots, filesystem: fs()),
         do: fs().rm(path)
  end

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
