defmodule Cinder.Subtitles.Fetcher do
  @moduledoc """
  Serializes per-import subtitle fetches through a single process so a bulk import can't burst
  OpenSubtitles.

  `Cinder.Subtitles.fetch_after_import/4` casts each just-imported file here instead of spawning
  one supervised Task per file directly off the import path. Adding a whole series at once
  (dozens of episodes imported in a short window) would otherwise fire dozens of concurrent
  OpenSubtitles requests and trip its rate limit (HTTP 429), leaving those episodes without
  sidecars until the 12h sweep (issue #80). Processing casts one at a time — the GenServer
  mailbox IS the queue — keeps a single request in flight, matching the sequential path the
  `Sweeper` already uses without tripping the limit.

  Each queued fetch still runs on its own isolated (`async_nolink`) task, awaited before the next
  cast is dequeued: that's what serializes the queue while keeping a provider blow-up from taking
  the Fetcher itself down (on top of `Cinder.Subtitles.fetch_now/4`'s own rescue/catch). Always
  on; inert when subtitles are off (a blank `subtitle_languages` makes each fetch a no-op).
  """
  use GenServer

  require Logger

  alias Cinder.Subtitles

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Enqueue a just-imported file for a serialized subtitle fetch. Returns `:ok` immediately."
  @spec enqueue((-> map()), String.t(), :movies | :tv, [String.t()]) :: :ok
  def enqueue(criteria_fun, video_path, kind, release_sidecar_languages)
      when is_function(criteria_fun, 0) do
    GenServer.cast(
      __MODULE__,
      {:fetch, criteria_fun, video_path, kind, release_sidecar_languages}
    )
  end

  @impl true
  def init(:ok) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, task_supervisor}
  end

  @impl true
  def handle_cast(
        {:fetch, criteria_fun, video_path, kind, release_sidecar_languages},
        task_supervisor
      ) do
    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Subtitles.fetch_now(criteria_fun, video_path, kind, release_sidecar_languages)
      end)

    # Synchronous by design: blocking this process on the awaited task is what serializes the
    # queue. `async_nolink` + this rescue keep a runaway crash from ever taking the Fetcher down.
    try do
      Task.await(task, :infinity)
    catch
      :exit, reason ->
        Logger.warning("subtitle fetch task crashed for #{video_path}: #{inspect(reason)}")
    end

    {:noreply, task_supervisor}
  end
end
