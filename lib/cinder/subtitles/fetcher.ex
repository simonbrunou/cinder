defmodule Cinder.Subtitles.Fetcher do
  @moduledoc """
  Serializes per-import subtitle fetches through a single process so a bulk import can't burst
  OpenSubtitles.

  `Cinder.Subtitles.fetch_after_import/2` casts each just-imported file here instead of spawning one
  supervised Task per file. Adding a whole series at once (dozens of episodes imported in a short
  window) would otherwise fire dozens of concurrent OpenSubtitles requests and trip its rate limit
  (HTTP 429), leaving those episodes without sidecars until the 12h sweep (issue #80). Processing
  casts one at a time — the GenServer mailbox IS the queue — keeps a single request in flight,
  matching the sequential path the `Sweeper` already uses without tripping the limit.

  Best-effort by construction: each fetch runs inside `Cinder.Subtitles.fetch_now/2`'s own
  rescue/catch, so a provider blow-up logs and the next queued fetch still runs. Always on (like the
  Task.Supervisor it replaces); inert when subtitles are off (a blank `subtitle_languages` makes each
  fetch a no-op).
  """
  use GenServer

  alias Cinder.Subtitles

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Enqueue a just-imported file for a serialized subtitle fetch. Returns `:ok` immediately."
  @spec enqueue((-> map()), String.t()) :: :ok
  def enqueue(criteria_fun, dest_path) when is_function(criteria_fun, 0) do
    GenServer.cast(__MODULE__, {:fetch, criteria_fun, dest_path})
  end

  @impl true
  def init(:ok), do: {:ok, :ok}

  @impl true
  def handle_cast({:fetch, criteria_fun, dest_path}, state) do
    # Synchronous by design: blocking this process on the fetch is what serializes the queue.
    Subtitles.fetch_now(criteria_fun, dest_path)
    {:noreply, state}
  end
end
