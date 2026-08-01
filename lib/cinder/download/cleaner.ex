defmodule Cinder.Download.Cleaner do
  @moduledoc """
  Reaps download-client entries Cinder submitted but no longer owns — the junk a crashed,
  cancelled or aborted flow leaves wedged in the client queue with nothing left to finish it.

  Every download Cinder submits is marked with its operation key (a `cinder-<key>` tag on
  torrents, a job-name suffix on usenet), and `Client.list_managed/0` reports **only** those. A
  household's hand-added downloads are invisible to this sweep by construction, not by a filter
  that could be got wrong.

  An entry is an **orphan** when its operation key matches no `download_intents` row *and* its id
  is not the live `download_id` of a movie or a grab. Orphans are removed with their files.

  ## The completed-download guard

  Only entries still `:downloading` or `:error` are ever considered. A **`:completed` entry is
  never touched, orphan or not** — Cinder deliberately never auto-removes finished torrents so
  seeding survives (`Cinder.Download.remove_after_import/3`, `Cinder.Catalog.Grabs`), and a sweep
  that reaped completed-but-unclaimed entries would quietly undo that. This is the deliberate
  narrowing versus cleanuparr's download cleaner: ratio/seed-time cleanup is out of scope here, and
  the leak that actually accumulates — partials nothing will ever finish — is what this reaps.

  **On by default** — the shipped `config/config.exs` sets `enabled: true`. (`enabled?/0`'s own
  fallback is `false`, so an install with no config block at all stays off — fail-safe, mirroring
  `Cinder.Download.StallReaper`.)

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`): stateless, self-rescheduling,
  crash-recoverable. Interval is module config
  (`config :cinder, #{inspect(__MODULE__)}, interval: <ms>`).
  """
  import Ecto.Query

  alias Cinder.Catalog.{Grab, Movie}
  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Repo

  @default_interval :timer.hours(1)

  # Never :completed — see the guard in the moduledoc.
  @reapable_states [:downloading, :error]

  use Cinder.Download.PollerSkeleton,
    log_prefix: "cleaner",
    stateful: false,
    first_interval: :timer.minutes(5)

  @doc "Whether the orphan sweep is enabled (`config :cinder, #{inspect(__MODULE__)}, enabled: true`)."
  def enabled?, do: Keyword.get(config(), :enabled, false)

  defp do_poll do
    if enabled?() do
      Enum.each(Download.available_protocols(), &isolate("#{&1} orphans", fn -> sweep(&1) end))
    end

    :ok
  end

  defp sweep(protocol) do
    with {:ok, client} <- Download.client_for(protocol),
         {:ok, entries} <- client.list_managed() do
      entries
      |> Enum.filter(&(&1.state in @reapable_states))
      |> unclaimed()
      |> Enum.each(&reap(client, &1))
    else
      # No client configured for this protocol — nothing to sweep.
      :error ->
        :ok

      {:error, reason} ->
        Logger.warning("cleaner could not list #{protocol} downloads: #{inspect(reason)}")
    end
  end

  # Two batched lookups rather than one query per entry: the client list is small (a household
  # queue), but a per-entry query would be a round trip each on every tick.
  defp unclaimed([]), do: []

  defp unclaimed(entries) do
    keys = claimed_keys(Enum.map(entries, & &1.operation_key))
    ids = claimed_ids(Enum.map(entries, & &1.id))

    Enum.reject(
      entries,
      &(MapSet.member?(keys, &1.operation_key) or MapSet.member?(ids, &1.id))
    )
  end

  defp claimed_keys(keys) do
    MapSet.new(
      Repo.all(from i in Intent, where: i.operation_key in ^keys, select: i.operation_key)
    )
  end

  # A movie or grab still pointing at the download owns it even with no intent row left — the
  # intent is deleted once the pipeline has taken ownership, so this is the second half of "ours".
  defp claimed_ids(ids) do
    movie_ids = Repo.all(from m in Movie, where: m.download_id in ^ids, select: m.download_id)
    grab_ids = Repo.all(from g in Grab, where: g.download_id in ^ids, select: g.download_id)

    MapSet.new(movie_ids ++ grab_ids)
  end

  defp reap(client, entry) do
    Logger.warning(
      "cleaner removing orphaned #{entry.state} download #{entry.id} " <>
        "(operation #{entry.operation_key} has no owner)"
    )

    Download.best_effort_remove(client, entry.id)
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])
end
