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
         before = Books.work_identity_snapshot(work.id),
         {:ok, refreshed} <- store(work, resolution) do
      record_drift(before, Books.work_identity_snapshot(refreshed.id))
      :ok
    end
  end

  # Best-effort, additive only — a `book_ops_log` write failure never affects the refresh
  # `store/2` already committed. Only `title` and the contributor NAME SET (not its size: two
  # authors becoming a different two authors at equal cardinality is exactly the drift this
  # exists to catch, and a count comparison would miss it) drift is watched, per the plan's own
  # scope. Both `before` and `refreshed` can be `nil` (the work vanished mid-refresh, or never
  # existed — `work_identity_snapshot/1` returns `nil` rather than raising); either case skips
  # the comparison instead of crashing this best-effort tail.
  defp record_drift(nil, _refreshed), do: :ok
  defp record_drift(_before, nil), do: :ok

  defp record_drift(before, refreshed) do
    for detail <- [title_drift(before, refreshed), contributor_drift(before, refreshed)],
        not is_nil(detail) do
      Books.log_metadata_drift(detail)
    end

    :ok
  end

  # Trimmed and case-folded so a provider re-sending the same name/title with different
  # whitespace or capitalization is never reported as drift; `nil` and `""` normalize identically
  # so a field going from unset to blank (or back) is not drift either.
  defp normalize_text(nil), do: ""
  defp normalize_text(text), do: text |> String.trim() |> String.downcase()

  defp title_drift(%{title: old}, %{title: new}) do
    if normalize_text(old) == normalize_text(new), do: nil, else: "title: #{old} → #{new}"
  end

  defp contributor_drift(%{contributors: before}, %{contributors: after_}) do
    before_norm = MapSet.new(before, &normalize_text/1)
    after_norm = MapSet.new(after_, &normalize_text/1)

    if MapSet.equal?(before_norm, after_norm) do
      nil
    else
      added = Enum.uniq(after_) |> Enum.reject(&MapSet.member?(before_norm, normalize_text(&1)))
      removed = Enum.uniq(before) |> Enum.reject(&MapSet.member?(after_norm, normalize_text(&1)))
      "contributors: " <> contributor_change_detail(Enum.sort(added), Enum.sort(removed))
    end
  end

  # A same-cardinality swap (the exact case a count-only comparison used to miss) reads as a
  # rename: "Old Name → New Name". Anything else spells out what was added/removed so the log
  # names people, not integers.
  defp contributor_change_detail([added], [removed]), do: "#{removed} → #{added}"

  defp contributor_change_detail(added, removed) do
    [
      if(added != [], do: "added #{Enum.join(added, ", ")}"),
      if(removed != [], do: "removed #{Enum.join(removed, ", ")}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

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
