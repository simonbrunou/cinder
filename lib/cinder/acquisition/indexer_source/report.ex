defmodule Cinder.Acquisition.IndexerSource.Report do
  @moduledoc """
  What one search did with each indexer: the per-indexer search report an indexer source may
  return beside its rows (`{:ok, rows, report}`, `Cinder.Acquisition.IndexerSource`).

  A report records, per indexer keyed `{source, id}` (the `indexer_source` string and `indexer_id`
  integer a release carries), the indexer's display name and one outcome:

  - `:asked`: the indexer took the query and answered.
  - `{:not_asked, reason}`: the search left it out before asking.
    - `:caps`: its capabilities or categories cannot take the query.
    - `{:not_supported, feature}`: it needs a type or definition feature Cinder has not built.
      `feature` is an atom or a non-empty tuple of atoms, as
      `Cinder.Indexers.Definitions.Loader` names them.
  - `{:skipped, reason}`: the search could have asked it and did not.
    - `{:backoff, until}`: a failure or limit backoff runs until the `DateTime` `until`.
    - `:deadline`: the search deadline cut it, or its query never left the spacing queue.
  - `{:failed, reason}`: the search asked it and got no usable answer.
    - `:timeout`.
    - `:dns` and `:connection_refused`, kept apart from `:connection_failed` (TLS and any other
      connection error).
    - `{:http_status, status}`, an integer HTTP status.
    - `:bad_response`: a body that does not parse, such as an HTML page on HTTP 200.
    - `:too_large`.
    - `{:indexer_error, code}`: an integer Newznab `<error>` code that is neither a limit nor a
      credentials code.
    - `{:limit, until}`: the indexer reported a limit, which lasts until the `DateTime` `until`,
      or nil when the answer stated no wait (#1653). Nothing gives a nil limit a default yet:
      #1654 adds one.
    - `:rejected_credentials`: a failure, not a skip.
    - `:challenge`: a Cloudflare challenge or a FlareSolverr failure.
    - `:crashed`: the search process or parser worker died, or a regex limit hit.

  This set is closed: `put/4` raises `ArgumentError` on any other outcome, so a new reason needs
  a change here first. Every reason is an atom or a tuple of atoms, integers and `DateTime`s, and
  never carries a URL, a header or a body.

  A report also counts failed seam calls. When some seam call of a search answered,
  `combine/1` counts each of its calls that returned an error, unless the error is
  `{:indexers_backing_off, retry_at}` or `:no_indexers`. That count is all a caller knows under
  the Prowlarr source, which reports no indexers. A source must return its own report with no
  failed call counted.

  A search is incomplete (`incomplete?/1`, `GLOSSARY.md` "Incomplete search") when a seam call
  failed or an indexer failed. A skipped or not-asked indexer never makes it incomplete.
  """

  alias Cinder.Acquisition.IndexerSource

  defstruct indexers: %{}, failed_calls: 0

  @type key :: {source :: String.t(), id :: integer()}
  @type feature :: atom() | tuple()
  @type not_asked_reason :: :caps | {:not_supported, feature()}
  @type skip_reason :: {:backoff, DateTime.t()} | :deadline
  @type failure_reason ::
          :timeout
          | :dns
          | :connection_refused
          | :connection_failed
          | {:http_status, 100..599}
          | :bad_response
          | :too_large
          | {:indexer_error, integer()}
          | {:limit, DateTime.t() | nil}
          | :rejected_credentials
          | :challenge
          | :crashed
  @type outcome ::
          :asked
          | {:not_asked, not_asked_reason()}
          | {:skipped, skip_reason()}
          | {:failed, failure_reason()}
  @type entry :: %{name: String.t(), outcome: outcome()}
  @type t :: %__MODULE__{indexers: %{key() => entry()}, failed_calls: non_neg_integer()}

  @failure_atoms [
    :timeout,
    :dns,
    :connection_refused,
    :connection_failed,
    :bad_response,
    :too_large,
    :rejected_credentials,
    :challenge,
    :crashed
  ]

  @rank %{not_asked: 0, asked: 1, skipped: 2, failed: 3}

  @doc "An empty report: no indexer, no failed seam call."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Records `outcome` for the indexer `key`, named `name`. A second outcome for the same indexer
  merges by `merge/2`'s rule. Raises `ArgumentError` on an outcome outside the closed set.
  """
  @spec put(t(), key(), String.t(), outcome()) :: t()
  def put(%__MODULE__{} = report, {source, id} = key, name, outcome)
      when is_binary(source) and is_integer(id) and is_binary(name) do
    unless outcome?(outcome),
      do: raise(ArgumentError, "not an indexer outcome of the closed set: #{inspect(outcome)}")

    merge(report, %__MODULE__{indexers: %{key => %{name: name, outcome: outcome}}})
  end

  @doc "Whether `outcome` is one of the closed set of outcomes (see the moduledoc)."
  @spec outcome?(term()) :: boolean()
  def outcome?(:asked), do: true
  def outcome?({:not_asked, :caps}), do: true
  def outcome?({:not_asked, {:not_supported, feature}}), do: feature?(feature)
  def outcome?({:skipped, {:backoff, %DateTime{}}}), do: true
  def outcome?({:skipped, :deadline}), do: true
  def outcome?({:failed, reason}) when reason in @failure_atoms, do: true

  def outcome?({:failed, {:http_status, status}})
      when is_integer(status) and status in 100..599,
      do: true

  def outcome?({:failed, {:indexer_error, code}}) when is_integer(code), do: true
  def outcome?({:failed, {:limit, %DateTime{}}}), do: true
  def outcome?({:failed, {:limit, nil}}), do: true
  def outcome?(_outcome), do: false

  defp feature?(feature) when is_atom(feature), do: true

  defp feature?(feature) when is_tuple(feature) and tuple_size(feature) > 0,
    do: feature |> Tuple.to_list() |> Enum.all?(&is_atom/1)

  defp feature?(_feature), do: false

  @doc """
  Merges the report of a later seam call (`b`) into an earlier one (`a`). Per indexer, failed
  wins over skipped, skipped over asked and asked over not asked; on a tie `a`'s entry stays. The
  failed-call counts add.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    indexers =
      Map.merge(a.indexers, b.indexers, fn _key, first, later ->
        if rank(later) > rank(first), do: later, else: first
      end)

    %__MODULE__{indexers: indexers, failed_calls: a.failed_calls + b.failed_calls}
  end

  defp rank(%{outcome: :asked}), do: @rank.asked
  defp rank(%{outcome: {class, _reason}}), do: Map.fetch!(@rank, class)

  @doc """
  Whether the search the report describes is incomplete: a seam call failed or an indexer
  failed.
  """
  @spec incomplete?(t()) :: boolean()
  def incomplete?(%__MODULE__{failed_calls: calls}) when calls > 0, do: true

  def incomplete?(%__MODULE__{indexers: indexers}),
    do: Enum.any?(indexers, &match?({_key, %{outcome: {:failed, _reason}}}, &1))

  @doc """
  One seam call's answer in the shape every caller reads: `{:ok, rows}` becomes
  `{:ok, rows, report}` with an empty report, and `{:ok, rows, report}` and `{:error, reason}`
  stay as they are. Raises `FunctionClauseError` on any other shape.
  """
  @spec from_result(IndexerSource.result()) :: {:ok, [map()], t()} | {:error, term()}
  def from_result({:ok, rows}) when is_list(rows), do: {:ok, rows, new()}
  def from_result({:ok, rows, %__MODULE__{} = report}) when is_list(rows), do: {:ok, rows, report}
  def from_result({:error, _reason} = error), do: error

  @doc """
  Combines the answers of one search's seam calls, in call order, each in `from_result/1`'s
  shape with its rows already read.

  When some call answered, returns `{:ok, row_lists, report}`: each answering call's rows in call
  order, and every answer's report merged in call order. A `{:no_indexer_answered, report}` error
  adds that report's indexers and one failed call, any other error adds one failed call, and
  `{:indexers_backing_off, retry_at}` or `:no_indexers` adds nothing.

  When no call answered, returns the first error that is neither
  `{:indexers_backing_off, retry_at}` nor `:no_indexers`. When that error is
  `{:no_indexer_answered, report}`, its report is every such error's report merged in call
  order, with no failed call added; any other error comes back as it is. With no such error,
  the `{:indexers_backing_off, retry_at}` with the earliest `retry_at` wins, then
  `:no_indexers`. No call at all gives an empty answer.
  """
  @spec combine([{:ok, rows, t()} | {:error, term()}]) ::
          {:ok, [rows], t()} | {:error, term()}
        when rows: list()
  def combine(answers) do
    case for({:ok, rows, _report} <- answers, do: rows) do
      [] when answers != [] -> no_answer(for {:error, reason} <- answers, do: reason)
      row_lists -> {:ok, row_lists, Enum.reduce(answers, new(), &add_answer(&2, &1))}
    end
  end

  defp add_answer(acc, {:ok, _rows, report}), do: merge(acc, report)

  defp add_answer(acc, {:error, {:no_indexer_answered, %__MODULE__{} = report}}),
    do: add_failed_call(merge(acc, report))

  defp add_answer(acc, {:error, reason}),
    do: if(asked_none?(reason), do: acc, else: add_failed_call(acc))

  defp add_failed_call(report), do: %{report | failed_calls: report.failed_calls + 1}

  # The two errors of a seam call that asked no indexer: every one was backing off, or none is
  # enabled.
  defp asked_none?({:indexers_backing_off, %DateTime{}}), do: true
  defp asked_none?(:no_indexers), do: true
  defp asked_none?(_reason), do: false

  defp no_answer(reasons) do
    case Enum.find(reasons, &(not asked_none?(&1))) do
      {:no_indexer_answered, %__MODULE__{}} ->
        merged =
          for({:no_indexer_answered, %__MODULE__{} = report} <- reasons, do: report)
          |> Enum.reduce(&merge(&2, &1))

        {:error, {:no_indexer_answered, merged}}

      nil ->
        {:error, earliest_backoff(reasons)}

      reason ->
        {:error, reason}
    end
  end

  defp earliest_backoff(reasons) do
    case for({:indexers_backing_off, %DateTime{}} = backoff <- reasons, do: backoff) do
      [] -> :no_indexers
      backoffs -> Enum.min_by(backoffs, fn {_error, retry_at} -> retry_at end, DateTime)
    end
  end
end
