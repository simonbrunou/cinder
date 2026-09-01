defmodule Cinder.Books.BibliographyRefresher do
  @moduledoc """
  Periodically applies every `book_author_policies` row against its provider's current
  bibliography — the unattended half of B5b's author monitoring policies. Runs the identical
  `Cinder.Books.preview_author_policy/2` + `Cinder.Books.apply_author_policy/4` pair the admin
  Confirm button uses, so the sweep and the button can never disagree about what counts as "new
  and unambiguous."

  **Never demotes, never deletes.** The only write this module ever reaches is
  `Cinder.Books.monitor_target/4` (via `apply_author_policy/4`), which only ever arms a target —
  it has no path that touches an existing target's status. `Cinder.Books.import_resolution/1`'s
  "only write what the provider actually returned" rule (unchanged) already means a provider that
  stops listing a work causes no local write at all, let alone a delete. A provider outage during
  a tick therefore leaves every existing target byte-identical.

  **Bounded, same as a preview.** `preview_author_policy/2`'s own cap
  (`@max_bibliography_candidates`, 50) bounds this module too, since `refresh_author/3` reuses it
  unchanged: one tick costs at most 1 + 50 provider requests per policied author, not one per
  candidate in the whole bibliography. A bibliography larger than the cap is worked through
  gradually — each tick's `eligible` set already excludes anything a prior tick monitored, so the
  capped window rotates forward on its own tick over tick.

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`) — self-rescheduling,
  stateless, crash-recoverable. Interval is module config
  (`config :cinder, #{inspect(__MODULE__)}, interval: <ms>`), default 12 hours (mirrors
  `Cinder.Books.Refresher` exactly).
  """
  import Ecto.Query

  require Logger

  alias Cinder.Books
  alias Cinder.Books.BookAuthorPolicy
  alias Cinder.Repo

  @default_interval :timer.hours(12)

  use Cinder.Download.PollerSkeleton,
    log_prefix: "books bibliography refresher",
    stateful: false,
    first_interval: :timer.minutes(1)

  defp do_poll do
    for policy <- Repo.all(from p in BookAuthorPolicy, preload: [:author, :profile]) do
      isolate("author policy #{policy.author_id}", fn -> refresh_author(policy) end)
    end

    :ok
  end

  @doc false
  # Public for the tests: one policy's refresh, without the tick around it.
  def refresh_author(%BookAuthorPolicy{author: author, policy: policy, profile: profile}) do
    case Books.preview_author_policy(author, policy) do
      {:ok, %{eligible: eligible}} ->
        apply_eligible(author, policy, profile, eligible)

      {:error, reason} ->
        Logger.debug(
          "books bibliography refresher: author #{author.id} not refreshed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp apply_eligible(_author, _policy, _profile, []), do: :ok

  defp apply_eligible(author, policy, profile, eligible) do
    case Books.apply_author_policy(author, policy, profile, eligible) do
      {:ok, 0} ->
        :ok

      {:ok, created_count} ->
        Logger.info(
          "books bibliography refresher: author #{author.id} monitored #{created_count} new work(s)"
        )

        :ok
    end
  end
end
