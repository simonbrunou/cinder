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

  alias Cinder.Acquisition
  alias Cinder.Acquisition.{Language, Parser}
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, GrabFile, Movie, Series}

  alias Cinder.Library.{
    AnimeInventory,
    AnimePreflight,
    EpisodeSources,
    ImportedQuality,
    ImportStage,
    MovieSources,
    Naming,
    PathPolicy,
    PolicyVerifier,
    StagedImport,
    Upgrade
  }

  alias Cinder.Settings

  @video_exts ~w(.mkv .mp4 .avi .m4v .mov .wmv .ts)
  @standard_tv_bridged_schemes ~w(scene aired)

  # The video library kinds Cinder manages. `Cinder.LibraryKind` is the full library-kind registry;
  # per-kind video derivations (Plex sections, size bands, release policy, reconciler, disk
  # telemetry, and the setup gate) intentionally hang off this narrower list. The registry is a
  # pure literal read at boot and config-eval time, so it must not touch Application env or Repo.

  @doc "The video library kinds Cinder manages (e.g. `:movies`, `:tv`)."
  @spec kinds() :: [atom()]
  def kinds, do: Cinder.LibraryKind.video()

  @doc "Whether `path` has a video extension supported by the library importer."
  def video_file?(path),
    do: String.downcase(Path.extname(path)) in @video_exts

  @doc false
  def video_extensions, do: @video_exts

  @doc """
  Stages a movie's download as a `Cinder.Library.StagedImport` for
  `Cinder.Catalog.MovieLifecycle.import_staged/2`.

  The record is `%{file_path:, part_file_paths:, quality:}`: the primary file, the further parts
  of a strict CD/part stack, and the quality to record (sidecar languages merged across parts).
  `replace: true` (a forced upgrade) swaps whatever sits at the movie's destination; otherwise a
  file already there is swapped only when the download ranks better than the recorded quality.
  """
  @spec stage_movie(Movie.t(), keyword()) :: {:ok, StagedImport.t()} | {:error, term()}
  def stage_movie(movie, opts \\ [])

  def stage_movie(%Movie{} = movie, opts) do
    case Movie.download_source(movie) do
      path when path in [nil, ""] -> {:error, :no_file_path}
      path -> do_stage_movie(movie, path, opts)
    end
  end

  defp do_stage_movie(movie, path, opts) do
    replace? = Keyword.get(opts, :replace, false)

    with {:ok, root} <- Settings.library_root(:movies, movie),
         {:ok, sources, folder?} <- MovieSources.resolve(path),
         {:ok, reports} <- verify_movie_policy(movie, Enum.map(sources, &elem(&1, 0))),
         :ok <- PolicyVerifier.verify_runtime(movie.runtime, sources, media_info()),
         {:ok, sources} <- stat_movie_sources(sources),
         new_q =
           ImportedQuality.capture(path, Enum.map(sources, &{&1.path, &1.size}),
             release_title: movie.release_title,
             reports: reports
           ),
         context = %{
           movie: movie,
           root: root,
           quality: new_q,
           forced?: replace?,
           on_collision: if(replace? or upgrade?(movie, new_q), do: :replace, else: :keep),
           folder?: folder?
         },
         {:ok, staged, stages} <- stage_movie_sources(sources, context) do
      {:ok, StagedImport.put_record(staged, movie_record(stages))}
    end
  end

  defp stat_movie_sources(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn {path, part}, {:ok, acc} ->
      case fs().lstat(path) do
        {:ok, %{size: size}} ->
          {:cont, {:ok, [%{path: path, part: part, size: size} | acc]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      {:error, _reason} = error -> error
    end
  end

  # The first source is the primary file; any further ones are the parts of a stack.
  defp stage_movie_sources(sources, context) do
    sources
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, StagedImport.new(), []}, fn {source, index},
                                                           {:ok, staged, stages} ->
      effect = if index == 0, do: :movie, else: :movie_part

      case stage_movie_source(staged, source, effect, context) do
        {:ok, staged, stage} ->
          {:cont, {:ok, staged, [stage | stages]}}

        {:error, _reason} = error ->
          StagedImport.rollback(staged)
          {:halt, error}
      end
    end)
    |> case do
      {:ok, staged, stages} -> {:ok, staged, Enum.reverse(stages)}
      {:error, _reason} = error -> error
    end
  end

  defp stage_movie_source(staged, source, effect, %{movie: movie, root: root} = context) do
    dest =
      if source.part,
        do: Naming.movie_part_dest(movie, source.path, root, source.part),
        else: Naming.movie_dest(movie, source.path, root)

    with {:ok, dest} <- safe_destination(dest, root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, staged, outcome} <-
           StagedImport.place(staged, source.path, dest, root,
             on_collision: context.on_collision,
             extensions: @video_exts
           ) do
      quality =
        ImportedQuality.for_outcome(context.quality, outcome, movie,
          dest: dest,
          forced?: context.forced?,
          sidecars_from: if(context.folder?, do: source.path)
        )

      staged =
        StagedImport.after_commit(staged, dest, {effect, movie, quality.sidecar_subtitles},
          link_sidecars_from: if(context.folder?, do: source.path)
        )

      {:ok, staged, %{dest: dest, quality: quality}}
    end
  end

  defp movie_record([primary]),
    do: %{file_path: primary.dest, part_file_paths: [], quality: primary.quality}

  defp movie_record([primary | parts] = stages) do
    sidecars =
      stages
      |> Enum.flat_map(& &1.quality.sidecar_subtitles)
      |> Enum.uniq()

    %{
      file_path: primary.dest,
      part_file_paths: Enum.map(parts, & &1.dest),
      quality: %{primary.quality | sidecar_subtitles: sidecars}
    }
  end

  @doc "Lists quarantined import journals for operator inspection."
  @spec quarantined_import_stages() :: [map()]
  def quarantined_import_stages, do: ImportStage.quarantined()

  @doc "Releases a quarantined import journal for a safe retry without discarding its files."
  @spec retry_import_stage(pos_integer()) :: {:ok, map()} | {:error, term()}
  def retry_import_stage(id), do: ImportStage.retry_quarantined(id)

  # Only fresh bytes count as placed: a staged no-op (the same file, or a kept one) moved nothing.
  defp placed?(outcome), do: outcome in [:placed, :replaced]

  # What a staged file inherits from the download it arrived in, threaded as one value because the
  # three travel together the whole way down: `folder?` gates sidecar linking, `reports` is the
  # media-probe cache (anime preflight), and `release_title` is the grab's release name, whose
  # parsed tokens backfill what a terse inner file name omits (see `ImportedQuality.capture/3`).
  defp download_context(folder?, reports, release_title),
    do: %{folder?: folder?, reports: reports, release_title: release_title}

  defp upgrade?(movie, new_q) do
    target = Language.target(movie.preferred_language, movie.original_language)

    Upgrade.better?(
      new_q,
      ImportedQuality.of(movie),
      target,
      preferred_resolutions(:movies),
      preferred_sources(:movies)
    )
  end

  # Both reads live in Upgrade, which also ranks against them — one definition, no drift.
  defp preferred_resolutions(kind), do: Upgrade.preferred_resolutions(kind)
  defp preferred_sources(kind), do: Upgrade.preferred_sources(kind)

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

  defp verify_movie_policy(%Movie{release_policy_snapshot: snapshot}, sources)
       when is_map(snapshot),
       do: PolicyVerifier.verify_release(sources, snapshot, media_info())

  defp verify_movie_policy(%Movie{} = movie, sources) do
    target = Language.target(movie.preferred_language, movie.original_language)

    Enum.reduce_while(sources, {:ok, %{}}, fn source, {:ok, reports} ->
      case verify_audio(source, target) do
        :ok -> {:cont, {:ok, reports}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp media_info, do: Application.get_env(:cinder, :media_info)

  @doc """
  Stages a standard-TV grab's download as a `Cinder.Library.StagedImport` for
  `Catalog.commit_grab_imports/4`, together with the video files that matched no episode.

  The record is `[{episode_id, dest, quality, placed?}]`, one row per staged episode; one file can
  be the dest of several episodes. `placed?` is false only for an arbitrated decline, where the
  episode keeps its own file; it is empty when nothing matched.

  `arbitrate: true` (the unattended upgrade sweep, `Grab.arbitrate_at_import`) makes THIS import
  the arbiter of every swap: an episode that already holds a file keeps it unless the incoming
  release beats it. The default forces the swap, which is what the manual path wants — the
  operator picked that release, possibly for something the ranking can't see (#250).

  `already_held:` is the series' episodes that already have a file. A video claimed by one of
  them is dropped rather than reported unmatched, so a pack grabbed for the *wanted* half of a
  season doesn't turn the other half's files into operator decisions (#251).

  `release_title:` is the grab's release name, which is what confirms such a file really belongs
  to this pack (`names_series?/3`, #265).

  A sample-named file that lost every episode it names to a real file is dropped the same way, so
  a release's `Sample/` clip doesn't become an operator decision either.
  """
  @spec stage_episodes(String.t() | nil, [Episode.t()], keyword()) ::
          {:ok, StagedImport.t(), [String.t()]} | {:error, term()}
  def stage_episodes(content_path, episodes, opts \\ [])

  def stage_episodes(content_path, _episodes, _opts) when content_path in [nil, ""],
    do: {:error, :no_content_path}

  def stage_episodes(content_path, episodes, opts) do
    collision = if Keyword.get(opts, :arbitrate, false), do: :arbitrate, else: :force
    already_held = Keyword.get(opts, :already_held, [])
    release_title = Keyword.get(opts, :release_title)

    with {:ok, root} <- Settings.library_root(:tv, episodes),
         {:ok, videos, folder?} <- video_files(content_path) do
      {to_import, unmatched} =
        videos
        |> match_episodes(episodes)
        |> EpisodeSources.pick(videos, episodes)
        |> reject_wrong_audio(episodes)
        |> drop_already_held(videos, already_held, release_title)

      download = download_context(folder?, %{}, release_title)

      with {:ok, staged} <-
             stage_all(to_import, root, episode_target(episodes), download, collision) do
        log_unmatched(unmatched)
        {:ok, staged, unmatched}
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
  Stages one operator-selected residual video at a canonical episode part destination, as a
  `Cinder.Library.StagedImport` whose record is that destination.

  The inventoried device/inode/size must still match; a changed source fails before staging, and
  a destination that already holds a file fails with `{:error, :part_destination_occupied}`.
  """
  def stage_grab_file_part(
        %Grab{content_path: content_path},
        %GrabFile{} = file,
        %Episode{file_path: primary} = episode
      )
      when is_binary(content_path) and content_path != "" and is_binary(primary) and primary != "" do
    with {:ok, root} <- Settings.library_root_for_path(primary),
         {:ok, source, folder?} <- grab_file_source(content_path, file.relative_path),
         {:ok, stat} <- fs().lstat(source),
         :ok <- verify_grab_file_identity(file, stat),
         dest = Naming.episode_part_dest(episode, source, root, file.id),
         {:ok, staged, stage} <-
           stage_episode_file_at(
             StagedImport.new(),
             [episode],
             source,
             root,
             download_context(folder?, %{}, nil),
             dest,
             :adopt,
             fn _new_quality -> false end
           ) do
      if placed?(stage.outcome) do
        {:ok,
         staged
         |> register_episode_effect([episode], stage, folder?)
         |> StagedImport.put_record(stage.dest)}
      else
        StagedImport.rollback(staged)
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
         {:ok, files} <- AnimeInventory.build(videos, content_path, folder?) do
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

  @doc """
  Stages persisted anime assignments after revalidating the download inventory, as a
  `Cinder.Library.StagedImport` whose record has `stage_episodes/3`'s row shape.
  """
  def stage_anime_episodes(%Grab{} = grab, preflight) do
    collision = if grab.arbitrate_at_import, do: :arbitrate, else: :force
    target = if grab.arbitrate_at_import, do: nil, else: episode_target(grab.episodes)

    with {:ok, current} <- inventory_anime_videos(grab.content_path),
         :ok <- AnimeInventory.same_inventory(current.files, preflight.decisions),
         :ok <- AnimeInventory.same_container_kind(current.folder?, preflight.folder?),
         {:ok, root} <- Settings.library_root(:tv, grab.episodes),
         {:ok, to_import} <-
           AnimeInventory.import_pairs(grab, preflight.assignments, current.folder?),
         {:ok, reports} <- verify_grab_policy(grab, to_import) do
      stage_anime_all(
        to_import,
        root,
        target,
        download_context(current.folder?, reports, grab.release_title),
        collision
      )
    else
      {:error, :inventory_changed} -> {:restart_preflight, :inventory_changed}
      {:error, _reason} = error -> error
    end
  end

  defp attach_preflight_grab({:ok, preflight}, grab, folder?),
    do: {:ok, preflight |> Map.put(:grab, grab) |> Map.put(:folder?, folder?)}

  defp attach_preflight_grab({:needs_mapping, preflight}, grab, _folder?),
    do: {:needs_mapping, Map.put(preflight, :grab, grab)}

  defp verify_grab_policy(%Grab{release_policy_snapshot: snapshot} = grab, to_import)
       when is_map(snapshot) do
    paths = to_import |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    PolicyVerifier.verify_release(paths, snapshot, media_info(),
      waive_unavailable: grab.verification_waived
    )
  end

  defp verify_grab_policy(%Grab{}, _to_import), do: {:ok, %{}}

  # MediaInfo safety net for TV (same as the movie path): drop a file whose actual audio is a
  # confirmed different language from the series' wanted language into `unmatched` (logged, not
  # imported) so its episode re-searches next tick, instead of importing the wrong language. Skipped
  # when no language is wanted (`target` nil) or the probe is disabled (`media_info` unset).
  # A season pack grabbed for the WANTED half of a season also delivers the half we already hold.
  # Those files claim no linked episode, so they used to land in `grab_files` as undecided
  # residuals: an operator hold, one click per file, for episodes we already have (#251). The
  # residual UI exists for files we can't identify — these we can, so drop them. Anything naming
  # an episode we don't hold, naming nothing, or naming another series stays a residual.
  defp drop_already_held(result, _videos, [], _release_title), do: result

  defp drop_already_held({to_import, unmatched}, videos, [held | _] = already_held, release_title) do
    series = held.season.series

    claimed =
      videos
      |> Enum.filter(fn {path, _size} -> path in unmatched end)
      |> match_episodes(already_held)
      |> Enum.group_by(fn {_ep, path, _size} -> path end, fn {ep, _path, _size} -> ep end)
      |> Enum.filter(fn {path, claiming} ->
        fully_held?(path, claiming, series, release_title)
      end)
      |> MapSet.new(fn {path, _claiming} -> path end)

    case Enum.split_with(unmatched, &MapSet.member?(claimed, &1)) do
      {[], ^unmatched} -> {to_import, unmatched}
      {dropped, kept} -> {to_import, log_already_held(dropped, kept)}
    end
  end

  # Every episode the file NAMES has to be one we hold, not just one of them: an `S01E08E09` whose
  # E09 is still wanted is E09's only candidate, and dropping it deletes that file with the
  # download (`move_on_import`). Counted, not compared number-by-number, because a bridged/scene
  # claim's episode_number deliberately differs from the parsed one — sound because
  # `single_arm_claims/1` left one arm and every coordinate writer binds ONE episode per canonical
  # value. `episode_coordinate_memberships` is many-to-many by schema, so a writer binding several
  # would inflate the count past `named`; revisit here if that changes. An unparseable name is not
  # droppable — unreachable (a claim required a parse) but the wrong default to leave lying around.
  defp fully_held?(path, claiming, series, release_title) do
    case Parser.parse(Path.basename(path)).episodes do
      nil ->
        false

      named ->
        names_series?(path, series, release_title) and
          length(Enum.uniq_by(claiming, & &1.id)) >= length(named)
    end
  end

  # `match_arm/2` compares season and episode numbers only — it never looks at the show name — so
  # another series' episode bundled into this release ("Totally.Different.Show.S01E05.mkv" in a
  # pack whose S01E05 we hold) is claimed by OUR episode and would be discarded without the
  # operator ever seeing it (#262). A discard is unrecoverable, so it must not be a guess.
  #
  # `Acquisition.names_title?/2` rather than a fold written here: matching a scene name to a series
  # title is exactly the problem the search guard already solved, down to "S.W.A.T." <=> "SWAT" and
  # "Law & Order" <=> "Law.and.Order". A second implementation would quietly disagree with the
  # guard that accepted this release in the first place, and every disagreement re-opens the
  # operator hold #251 removed. Whatever it rejects stays a residual — the recoverable direction.
  #
  # The series title alone is anchored at token zero, so three ordinary pack layouts never confirm
  # and every one of their files stays an operator hold: a qualifier TMDB lacks
  # ("Shameless.US.S01E05.mkv"), a site/group prefix, and a title-less inner file (#265). The
  # grab's own release title is what supplies the title those files omit or qualify —
  # `names_release?/3` — and the two are ORed: either name confirming the file is enough.
  defp names_series?(path, series, release_title) do
    base = Path.basename(path)

    Acquisition.names_title?(base, series) or
      Acquisition.names_release?(base, release_title, series)
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
    Logger.warning(
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
  # double-episode file yields two entries; `stage_all/5` groups them back to one library file.
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

  defp stage_all(to_import, root, target, download, collision) do
    to_import
    |> Enum.group_by(fn {_ep, source} -> source end, fn {ep, _source} -> ep end)
    |> stage_groups(root, target, download, collision)
  end

  defp stage_anime_all(to_import, root, target, download, collision) do
    to_import
    |> Enum.group_by(
      fn {episode, source} -> {source, episode.season.season_number} end,
      fn {episode, _source} -> episode end
    )
    |> Enum.sort_by(fn {{source, season}, _episodes} -> {source, season} end)
    |> Enum.map(fn {{source, _season}, episodes} -> {source, episodes} end)
    |> stage_groups(root, target, download, collision)
  end

  # The accumulator is `{staged, rows, keeps}`. `keeps` (held path => its staged row) is threaded
  # across every group on purpose: two episodes sharing one `file_path` can decline in one group (a
  # combined incoming file) or in two (the pack ships them separately), and `import_stages.dest` is
  # globally unique either way. Any failure rolls back everything staged so far, or the retry
  # collides with its own `:prepared` rows.
  defp stage_groups(groups, root, target, download, collision) do
    groups
    |> Enum.reduce_while({:ok, {StagedImport.new(), [], %{}}}, fn {source, episodes},
                                                                  {:ok, acc} ->
      episodes = Enum.sort_by(episodes, & &1.episode_number)

      case stage_group(acc, episodes, source, root, target, download, collision) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason, _acc} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, {staged, rows, _keeps}} ->
        {:ok, StagedImport.put_record(staged, rows)}

      {:error, reason, {staged, _rows, _keeps}} ->
        StagedImport.rollback(staged)
        {:error, reason}
    end
  end

  # A staged file is indivisible — one source can cover several episodes (an S01E01E02 file), and
  # it replaces every episode it covers or none of them. So the arbitrated decision is taken here,
  # for the WHOLE group, before anything is staged. Deciding per stage would be wrong twice over:
  # the gate would consult only the group's first episode, and a decline would re-point every row
  # in the group at that one episode's file — leaving the others' files unreferenced for
  # `remove_superseded_episode_files/1` to delete.
  defp stage_group(acc, episodes, source, root, target, download, :arbitrate) do
    case arbitration_quality(source, download.release_title) do
      {:ok, new_q} ->
        if Enum.all?(episodes, &ep_upgrade?(&1, new_q, target, true)),
          do: stage_group(acc, episodes, source, root, target, download, :adopt),
          else: keep_held_files(acc, episodes, source, download)

      {:error, reason} ->
        {:error, reason, acc}
    end
  end

  defp stage_group({staged, rows, keeps}, episodes, source, root, target, download, collision) do
    case stage_episode_file(staged, episodes, source, root, target, download, collision) do
      {:ok, staged, stage} ->
        group = Enum.map(episodes, &{&1.id, stage.dest, stage.quality, true})
        {:ok, {staged, Enum.reverse(group, rows), keeps}}

      {:error, reason} ->
        {:error, reason, {staged, rows, keeps}}
    end
  end

  # Only the four fields `Upgrade.better?/5` ranks on matter here, so this skips the media-info
  # probe `stage_episode_file_at/8` runs — audio and subtitle languages never enter the comparison.
  defp arbitration_quality(source, release_title) do
    with {:ok, source} <- safe_source_file(source),
         {:ok, %{size: size}} <- fs().lstat(source) do
      {:ok,
       ImportedQuality.capture(source, [{source, size}],
         release_title: release_title,
         probe: false
       )}
    end
  end

  # The declined group: every episode that holds a file gets a noop stage pinned to THAT file, so
  # it keeps its own path and recorded quality and still counts as imported — otherwise
  # `commit_grab_imports/4` would bump it as missing. An episode in the group holding nothing gets
  # nothing: the file is one unit and we just declined it, so that episode stays wanted and
  # re-searches. One stage per distinct HELD PATH across the whole import, never one per episode:
  # `import_stages.dest` is globally unique and two episodes legitimately share a `file_path` —
  # that is exactly what a previously imported double-episode file leaves behind. A stage each
  # would collide on the second insert, fail the whole grab, and leave the first one's `:prepared`
  # row holding that dest until its handoff deadline, so retries inside that window would fail
  # identically. The stage fans back out to every episode on that path, as `stage_group/7` already
  # does for placements.
  defp keep_held_files(acc, episodes, source, download) do
    held = Enum.filter(episodes, &(&1.file_path not in [nil, ""]))

    held
    |> Enum.uniq_by(& &1.file_path)
    |> Enum.reduce_while({:ok, acc}, fn ep, {:ok, acc} ->
      keep_held_file(acc, ep, held, source, download)
    end)
  end

  defp keep_held_file({staged, rows, keeps} = acc, ep, held, source, download) do
    case keep_stage(staged, ep, source, download, keeps) do
      {:ok, staged, kept} ->
        held_rows =
          for e <- held, e.file_path == ep.file_path, do: {e.id, kept.dest, kept.quality, false}

        {:cont, {:ok, {staged, held_rows ++ rows, Map.put(keeps, ep.file_path, kept)}}}

      {:error, reason} ->
        {:halt, {:error, reason, acc}}
    end
  end

  # The row's `placed?` is pinned false — a decline is never a placement, even when the held file
  # has vanished and staging lands the DECLINED file at that path. Calling that a placement clears
  # `part_file_paths` (which `remove_superseded_episode_files/1` then DELETES off disk) and skips
  # #274's `no_upgrade` row, which the record's own backfill cannot substitute for — the sweep's
  # `Enum.any?` gate is driven by a sibling episode (#289). Quality stays the record's own unless
  # we truly placed, or `ImportedQuality.for_outcome/4`'s unrecorded arm would stamp the declined
  # file's parse — title backfill and probed track languages — onto a kept file (#128, #275). The
  # one exception is a `:same_file` keep's sidecar list, which follows the subtitles its commit
  # links (#822). `ImportedQuality.declined/3` holds both rules.
  defp keep_stage(staged, ep, source, download, keeps) do
    case Map.fetch(keeps, ep.file_path) do
      {:ok, kept} -> {:ok, staged, kept}
      :error -> fresh_keep_stage(staged, ep, source, download)
    end
  end

  # The decline stages with the download's own `folder?`, so the release's sidecars go wherever the
  # file at `dest` is the release's: the fall-through placement (#291) and `:same_file` (#822). A
  # `:kept` stage links none of them (`StagedImport.after_commit/4`, #784): hardlinking the DECLINED
  # release's subtitles next to the file the episode KEPT is the same lie as recording its quality.
  defp fresh_keep_stage(staged, ep, source, download) do
    decline = fn _new_quality -> false end

    with {:ok, held_root} <- Settings.library_root_for_path(ep.file_path),
         {:ok, staged, stage} <-
           stage_episode_file_at(
             staged,
             [ep],
             source,
             held_root,
             download,
             ep.file_path,
             :adopt,
             decline
           ) do
      kept = %{stage | quality: ImportedQuality.declined(stage.quality, stage.outcome, ep)}
      {:ok, register_episode_effect(staged, [ep], kept, download.folder?), kept}
    end
  end

  defp stage_episode_file(staged, [ep | _] = episodes, source, root, target, download, collision) do
    dest = Naming.episode_dest(episodes, source, root)

    collision =
      if collision == :force and Enum.all?(episodes, &(&1.file_path in [nil, ""])),
        do: :adopt,
        else: collision

    upgrade_fun = fn new_quality -> ep_upgrade?(ep, new_quality, target) end

    with {:ok, staged, stage} <-
           stage_episode_file_at(
             staged,
             episodes,
             source,
             root,
             download,
             dest,
             collision,
             upgrade_fun
           ) do
      {:ok, register_episode_effect(staged, episodes, stage, download.folder?), stage}
    end
  end

  # Committing an episode file scans the TV library and fetches one subtitle for the file; a
  # folder download also hardlinks its sidecars next to it first.
  defp register_episode_effect(staged, episodes, stage, folder?) do
    StagedImport.after_commit(
      staged,
      stage.dest,
      {:episodes, episodes, stage.quality.sidecar_subtitles},
      link_sidecars_from: if(folder?, do: stage.source)
    )
  end

  # `collision` decides what happens when a file already sits at `dest`. Only `:force` (the manual
  # path, and anime) and `:adopt` reach here — `:arbitrate` is settled a level up, in
  # `stage_group/7`, because the choice belongs to the whole group and not to one stage.
  #   :force — swap it, no questions.
  #   :adopt — swap it only when `upgrade_fun` says the incoming file is better (nothing is held,
  #            or the group already decided and passed an `upgrade_fun` that says so).
  defp stage_episode_file_at(
         staged,
         [ep | _],
         source,
         root,
         download,
         dest,
         collision,
         upgrade_fun
       ) do
    with {:ok, source} <- safe_source_file(source),
         {:ok, %{size: size}} <- fs().lstat(source),
         new_q =
           ImportedQuality.capture(source, [{source, size}],
             release_title: download.release_title,
             reports: download.reports
           ),
         {:ok, dest} <- safe_destination(dest, root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         forced? = collision == :force,
         on_collision = if(forced? or upgrade_fun.(new_q), do: :replace, else: :keep),
         {:ok, staged, outcome} <-
           StagedImport.place(staged, source, dest, root,
             on_collision: on_collision,
             extensions: @video_exts
           ) do
      quality =
        ImportedQuality.for_outcome(new_q, outcome, ep,
          dest: dest,
          forced?: forced?,
          sidecars_from: if(download.folder?, do: source)
        )

      {:ok, staged, %{dest: dest, quality: quality, outcome: outcome, source: source}}
    end
  end

  # `arbitrating?` fails closed on an unrecorded quality (Upgrade.arbitration_upgrade?/5, #520)
  # only when the episode still holds a file — a mid-flight deletion can clear file_path/quality
  # while grab_id survives, and a fileless episode has nothing left to protect (better?/5).
  defp ep_upgrade?(ep, new_q, target, arbitrating? \\ false) do
    fail_closed? = arbitrating? and Episode.file_paths(ep) != []
    fun = if fail_closed?, do: &Upgrade.arbitration_upgrade?/5, else: &Upgrade.better?/5

    fun.(
      new_q,
      ImportedQuality.of(ep),
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

  @doc "Requests a library scan and returns the configured media server's result."
  defdelegate scan(kind), to: Cinder.Library.PostImport

  @doc false
  defdelegate refresh(kind, dest), to: Cinder.Library.PostImport

  @doc "Deletes one imported library file and prunes the folders it leaves empty."
  defdelegate delete_file(path), to: Cinder.Library.Deletion

  @doc "Deletes a completed download's source directory after a successful `move_on_import`."
  defdelegate delete_download_source(path), to: Cinder.Library.Deletion

  # Shared by the anime inventory and the residual grab-file inventory. Public (not private): also
  # called from `Cinder.Library.AnimeInventory`.
  @doc false
  def inventory_relative_path(source, _content_path, false), do: {:ok, Path.basename(source)}

  def inventory_relative_path(source, content_path, true) do
    relative_path = Path.relative_to(source, Path.expand(content_path))

    if relative_path == ".." or String.starts_with?(relative_path, "../"),
      do: {:error, :unsafe_source},
      else: {:ok, relative_path}
  end

  # Public (not private): also called from `Cinder.Library.AnimeInventory`.
  @doc false
  def safe_source_file(path, extensions \\ @video_exts) do
    case Settings.import_roots() do
      [] -> {:error, :download_roots_not_configured}
      roots -> path_policy().source_file(path, roots, extensions, filesystem: fs())
    end
  end

  @doc false
  def safe_walk(path) do
    case Settings.import_roots() do
      [] -> {:error, :download_roots_not_configured}
      roots -> path_policy().walk(path, roots: roots, filesystem: fs())
    end
  end

  defp safe_destination(path, root),
    do: path_policy().destination(path, root, filesystem: fs())

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)

  @doc false
  def path_policy, do: Application.get_env(:cinder, :path_policy, PathPolicy)
end
