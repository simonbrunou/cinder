defmodule Cinder.Library.StagedImport do
  @moduledoc """
  A staged import: library files placed at their final paths but still reversible until the
  catalog write that records them commits (GLOSSARY.md). Every movie, episode and book import
  goes through it.

  A stager (`Cinder.Library`, `Cinder.Library.EbookImport`, `Cinder.Library.AudiobookImport`)
  builds the handle with `new/0`, `place/5`, `after_commit/4` and `put_record/2`. Everyone else
  treats it as opaque: they pass it to `commit/2` with their Catalog or Books write, or abandon it
  with `rollback/1`. The one value a caller reads is the stager's **record** (`record/1`), the
  payload in its writer's own argument shape.

  ## Commit

  `commit/2` calls `writer.(record, stage_ids)`. The writer must mark those ids committed with
  `Cinder.Library.ImportStage.mark_committed!/1` inside its own transaction; that call aborts the
  transaction when a stage is no longer `:prepared`. Then the journal, not the writer's return
  value, settles each stage: one the writer marked runs its post-commit effects (claimed once per
  journal row) and is committed; every other stage is rolled back, last placed first. Settling
  runs even when the writer raises, and the raise propagates afterwards. Commit and rollback
  failures are logged, never returned: `reconcile/0` finishes them.

  The effects (sidecar hardlinks from the download, a media-server scan, a subtitle fetch) are
  done when `commit/2` returns, so a caller's own post-import work (removing the download source
  or superseded files, notifying) simply goes after it.

  ## The household import lock

  `run/1` holds the one lock a poller's import holds from its first `place/5` to its settle, the
  same lock `reconcile/0` takes. Without it, crash recovery could roll back a `:prepared` stage
  whose handoff deadline expired while a long multi-file copy was still building the next one.
  `Cinder.Download.Cleaner` takes it too, so it never reaps a download whose import has released
  its owner but is still settling. The residual-file Part decision from `/activity` does not take
  it yet (#783).
  """
  require Logger

  alias Cinder.Library.{ImportStage, PostImport, Sidecars, StageEngine}

  defstruct stages: [], record: nil

  @opaque t :: %__MODULE__{stages: [stage()], record: term()}

  @typep stage :: %{
           id: pos_integer(),
           dest: String.t(),
           outcome: StageEngine.outcome(),
           effect: effect() | nil,
           link_sidecars_from: String.t() | nil
         }

  @typedoc """
  What a staged file's commit runs, besides linking the download's sidecars. The list is the
  sidecar languages the stager recorded for the file.
  """
  @type effect ::
          {:movie, Cinder.Catalog.Movie.t(), [String.t()] | nil}
          | {:movie_part, Cinder.Catalog.Movie.t(), [String.t()] | nil}
          | {:episodes, [Cinder.Catalog.Episode.t()], [String.t()] | nil}

  @lock_held {__MODULE__, :lock_held}

  @doc """
  Runs `fun` holding the household import lock.

  Re-entrant within one process: a nested `run/1` just calls `fun`. `:global.trans/2` with the
  same lock id would release the lock when the inner call returned, while the outer import still
  needs it.
  """
  @spec run((-> result)) :: result when result: term()
  def run(fun) when is_function(fun, 0) do
    if Process.get(@lock_held) do
      fun.()
    else
      :global.trans({{__MODULE__, :household}, self()}, fn ->
        Process.put(@lock_held, true)

        try do
          fun.()
        after
          Process.delete(@lock_held)
        end
      end)
    end
  end

  @doc "Converges every journal row a crash or an earlier filesystem error left, under the lock."
  @spec reconcile() :: :ok
  def reconcile do
    run(fn -> Enum.each(ImportStage.list(), &StageEngine.reconcile_stage(&1.id, :auto)) end)
  end

  @doc "An empty staged import, for a stager to place files into."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Places `source` at `dest` under `root` and adds it to the staged import.

  `opts`: `on_collision: :keep | :replace` (default `:keep`) for another regular file already at
  `dest`, and `extensions:` (required), the source's allow-list. Returns the outcome
  (`t:Cinder.Library.StageEngine.outcome/0`) so the stager can settle the quality to record.
  A failure leaves the handle as it was; the stager decides whether to roll back what it already
  placed.
  """
  @spec place(t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, t(), StageEngine.outcome()} | {:error, term()}
  def place(%__MODULE__{} = staged, source, dest, root, opts) do
    on_collision = Keyword.get(opts, :on_collision, :keep)
    extensions = Keyword.fetch!(opts, :extensions)

    with {:ok, id, outcome} <- StageEngine.stage(source, dest, root, on_collision, extensions) do
      stage = %{id: id, dest: dest, outcome: outcome, effect: nil, link_sidecars_from: nil}
      {:ok, %{staged | stages: staged.stages ++ [stage]}, outcome}
    end
  end

  @doc """
  Registers what committing the file staged at `dest` runs: `effect` (see `t:effect/0`), and with
  `link_sidecars_from: source` a hardlink of `source`'s sidecar subtitles next to `dest`, made
  first. A stage that kept another file at `dest` (`:kept`) links none: those subtitles were
  timed for `source`, not for the file that stayed (#784). The first registration for a `dest`
  wins. A staged file with none commits silently, as every book does.
  """
  @spec after_commit(t(), String.t(), effect() | nil, keyword()) :: t()
  def after_commit(%__MODULE__{} = staged, dest, effect, opts \\ []) do
    from = Keyword.get(opts, :link_sidecars_from)

    stages =
      Enum.map(staged.stages, fn
        %{dest: ^dest, effect: nil, link_sidecars_from: nil, outcome: :kept} = stage ->
          %{stage | effect: effect}

        %{dest: ^dest, effect: nil, link_sidecars_from: nil} = stage ->
          %{stage | effect: effect, link_sidecars_from: from}

        stage ->
          stage
      end)

    %{staged | stages: stages}
  end

  @doc "Sets the record `commit/2` hands its writer."
  @spec put_record(t(), term()) :: t()
  def put_record(%__MODULE__{} = staged, record), do: %{staged | record: record}

  @doc "The stager's record: the payload in its writer's own argument shape."
  @spec record(t()) :: term()
  def record(%__MODULE__{record: record}), do: record

  @doc """
  Calls `writer.(record, stage_ids)`, settles every staged file by what the writer committed, and
  returns the writer's value. See the moduledoc.
  """
  @spec commit(t(), (term(), [pos_integer()] -> result)) :: result when result: term()
  def commit(%__MODULE__{} = staged, writer) when is_function(writer, 2) do
    writer.(staged.record, Enum.map(staged.stages, & &1.id))
  after
    settle(staged)
  end

  @doc "Abandons the staged import without writing anything: every staged file is rolled back."
  @spec rollback(t()) :: :ok
  def rollback(%__MODULE__{} = staged) do
    staged.stages |> Enum.reverse() |> Enum.each(&rollback_stage/1)
  end

  defp settle(staged) do
    staged.stages
    |> Enum.reject(&commit_stage/1)
    |> Enum.reverse()
    |> Enum.each(&rollback_stage/1)
  end

  # True once the stage is settled, false when nothing committed it and it must roll back. The
  # effects claim succeeds only on a committed row, so an uncommitted stage never runs them.
  defp commit_stage(stage) do
    run_effects(stage)

    case StageEngine.commit(stage.id) do
      {:error, :import_stage_not_committed} ->
        false

      result ->
        log_pending(result, "commit", stage)
        true
    end
  end

  defp rollback_stage(stage) do
    stage.id |> StageEngine.rollback() |> log_pending("rollback", stage)
  end

  defp run_effects(%{effect: nil, link_sidecars_from: nil}), do: :ok

  defp run_effects(stage) do
    if match?({:claimed, _row}, ImportStage.claim_effects(stage.id)) do
      placed =
        if stage.link_sidecars_from,
          do: Sidecars.link(stage.link_sidecars_from, stage.dest),
          else: []

      run_effect(stage.effect, stage.dest, placed)
    end

    :ok
  end

  defp run_effect(nil, _dest, _placed), do: :ok

  defp run_effect({:movie, movie, sidecar_languages}, dest, placed) do
    PostImport.refresh(:movies, dest)
    fetch_movie_subtitles(movie, dest, release_sidecars(sidecar_languages, placed))
  end

  # Parts skip the scan because the media-server scan is library-kind-wide.
  defp run_effect({:movie_part, movie, sidecar_languages}, dest, placed),
    do: fetch_movie_subtitles(movie, dest, release_sidecars(sidecar_languages, placed))

  defp run_effect({:episodes, episodes, sidecar_languages}, dest, placed) do
    PostImport.refresh(:tv, dest)

    PostImport.fetch_episode_subtitles(
      episodes,
      dest,
      release_sidecars(sidecar_languages, placed)
    )
  end

  # The subtitle task marks a recorded language's sidecar as Cinder-managed only when this commit
  # placed that file or the manifest already tracks it, so a subtitle the user put next to the
  # video stays theirs (#918).
  defp release_sidecars(sidecar_languages, placed),
    do: [languages: sidecar_languages, placed: placed]

  defp fetch_movie_subtitles(movie, dest, release_sidecars) do
    PostImport.fetch_subtitles(
      fn -> Cinder.Subtitles.movie_criteria(movie) end,
      dest,
      :movies,
      release_sidecars
    )
  end

  defp log_pending(:ok, _action, _stage), do: :ok

  defp log_pending({:error, reason}, action, stage) do
    Logger.warning(
      "staged import #{action} for #{stage.dest} remains pending: #{inspect(reason)}"
    )
  end
end
