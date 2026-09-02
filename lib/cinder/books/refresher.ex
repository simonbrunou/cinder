defmodule Cinder.Books.Refresher do
  @moduledoc """
  Periodically re-fetches every monitored work from the provider that identified it and folds the
  result back through `Cinder.Books.import_resolution/1`, so a late-filled release date or a newly
  listed edition becomes visible without an operator asking.

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`) — self-rescheduling, stateless,
  `:start_poller`-gated so the suite never auto-runs it. The interval is module config:
  `config :cinder, #{inspect(__MODULE__)}, interval: <ms>`.

  **Outage safety.** A provider that errors produces no write at all, and a payload that omits a
  field leaves the stored value alone (`import_resolution/1` writes only what was returned). A tick
  during an outage therefore leaves the catalog byte-identical instead of degrading it toward the
  emptiest response anyone ever returned.

  Every failure path here *returns* `{:error, reason}`; nothing raises. `isolate/2` only logs what
  it rescues, so an exception would reappear on every tick forever rather than parking.
  """
  require Logger

  alias Cinder.Books
  alias Cinder.Books.Identity

  @default_interval :timer.hours(12)
  use Cinder.Download.PollerSkeleton,
    log_prefix: "books refresher",
    stateful: false,
    first_interval: :timer.minutes(1)

  defp do_poll do
    for work <- Books.list_works_for_refresh() do
      isolate("book work #{work.id}", fn -> refresh_one(work) end)
    end

    :ok
  end

  @doc false
  # Public for the tests: one work's refresh, without the tick around it.
  def refresh_one(work) do
    with {:ok, reference} <- work_reference(work),
         {:ok, resolution} <- resolve(reference),
         before = Books.get_work(work.id),
         {:ok, refreshed} <- store(work, resolution) do
      record_drift(before, Books.get_work(refreshed.id))
      :ok
    end
  end

  # Best-effort, additive only — a `book_ops_log` write failure never affects the refresh
  # `store/2` already committed. Only `title` and the contributor-name-*set* (dedup by name,
  # not raw credit-row count — `Cinder.Books.import_work_in_tx/2`'s own `put_credits/3`
  # dedups by `{foreign_id, role}` before writing) drift is watched, per the plan's own scope.
  defp record_drift(before, refreshed) do
    for detail <- [title_drift(before, refreshed), contributor_drift(before, refreshed)],
        not is_nil(detail) do
      Books.log_metadata_drift(detail)
    end

    :ok
  end

  defp title_drift(%{title: same}, %{title: same}), do: nil
  defp title_drift(%{title: old}, %{title: new}), do: "title: #{old} → #{new}"

  defp contributor_drift(before, refreshed) do
    old_count = contributor_name_count(before)
    new_count = contributor_name_count(refreshed)
    if old_count == new_count, do: nil, else: "contributors: #{old_count} → #{new_count}"
  end

  defp contributor_name_count(work),
    do: work.credits |> Enum.map(& &1.author.name) |> Enum.uniq() |> length()

  # `book_identifiers` also holds isbn/asin rows, which name an edition rather than a work, and
  # `Cinder.Books.Metadata` only fetches works — so only a work-kind row can drive a refresh.
  defp work_reference(work) do
    case Enum.find(work.identifiers, &(&1.kind == "work")) do
      nil -> {:error, :no_provider_identity}
      identifier -> {:ok, Identity.reference_for(identifier.provider, identifier.foreign_id)}
    end
  end

  defp resolve(reference) do
    case Identity.resolve(reference) do
      {:ok, resolution} ->
        {:ok, resolution}

      other ->
        Logger.info("books refresher: #{reference} not refreshed: #{inspect(other)}")
        {:error, :unresolved}
    end
  end

  defp store(work, resolution) do
    case Books.import_resolution(resolution) do
      {:ok, refreshed} ->
        {:ok, refreshed}

      {:error, reason} ->
        Logger.warning("books refresher: work #{work.id} import failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
