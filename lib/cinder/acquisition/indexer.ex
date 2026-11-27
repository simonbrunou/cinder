defmodule Cinder.Acquisition.Indexer do
  @moduledoc """
  The per-type indexer seam: the behaviour each indexer type implements (Newznab, Torznab,
  Cardigann) for `Cinder.Acquisition.IndexerSource.Native`, which searches each configured indexer
  through the adapter of its type. Native reads the adapter of each type from the app env key
  `:indexer_adapters`, a map of type atom to module, at runtime; a type with no adapter is not
  asked.

  ## What an adapter answers

  `search/3` answers `{rows, outcome}` for one configured indexer: the rows it has, and the
  indexer's outcome, one of `Cinder.Acquisition.IndexerSource.Report`'s closed set (`:asked`,
  `{:failed, reason}`, `{:skipped, :deadline}` or `{:not_asked, reason}`). A query-level error
  or a path that fails after earlier ones answered keeps the rows it already has. `{:failed,
  :deadline}`, the tag `request/3` gives a request the search deadline cut, reads as `{:skipped,
  :deadline}`.

  Each row carries exactly one query origin: `query_origins` is `[:id_scoped]` or `[:free_text]`.
  An adapter sets neither the indexer's identity (`indexer_id`, `indexer_name`,
  `indexer_source`) nor `credentials_version`: Native stamps them.

  ## Requests

  Every adapter request goes through `request/3`, which gives it the smaller of its own timeout
  and the time left before the search deadline in `t:context/0`, and one retry after an HTTP 502,
  503, 504 or 408.

  Every search request and caps fetch runs inside `leased/4`, which holds the indexer's slot of
  `Cinder.Acquisition.IndexerSource.Native.Lease` while the adapter sends the request and records
  its answer.

  A grab's link fetch (`fetch_download/3`) holds no slot (#1659, #1619 point 8). Newznab and
  Torznab fetch through `Cinder.Download.Client.Fetch` under the download client's options, with
  neither `request/3`'s budget nor its retry. A Cardigann grab sends each request through
  `request/3` under the grab's own deadline, with `retry: false`
  (`Cinder.Acquisition.Indexer.Cardigann.Grab`, #1672).
  """

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerStatus, Lease}
  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.HTTPPolicy
  alias Cinder.Indexers.ConfiguredIndexer

  @typedoc """
  One seam call's query, by the `Cinder.Acquisition.IndexerSource` callback that made it, with
  that callback's arguments.
  """
  @type query ::
          {:search, imdb_id :: String.t()}
          | {:search_movie, imdb_id :: String.t(), query :: String.t(), opts :: keyword()}
          | {:search_movie_query, query :: String.t(), opts :: keyword()}
          | {:search_tv_query, query :: String.t(), opts :: keyword()}
          | {:search_tv, tvdb_id :: integer() | nil, title :: String.t(),
             season :: non_neg_integer()}
          | {:search_ebook, author :: String.t() | nil, title :: String.t(), opts :: keyword()}
          | {:search_ebook_query, query :: String.t(), opts :: keyword()}
          | {:search_audiobook, author :: String.t() | nil, title :: String.t(),
             opts :: keyword()}
          | {:search_audiobook_query, query :: String.t(), opts :: keyword()}

  @typedoc """
  What Native hands an adapter about the seam call: `deadline_at`, the end of its total
  deadline in `System.monotonic_time(:millisecond)`, and `priority`, `:interactive` for a
  manual search (`Cinder.Acquisition.IndexerSource.interactive/1`), else `:background`. A
  context with no `priority` is background.

  `budget`, set only by a parity run (`Cinder.Indexers.ParityRun`: its searches through
  `Cinder.Acquisition.IndexerSource.Native.search_run/2`, its caps reads, and its Cardigann link
  checks through `Cinder.Acquisition.Indexer.Cardigann.Grab`), is a 0-arity function `request/3`
  calls before each send: `:ok` lets the send go, anything else stops it unsent. A context with
  no `budget` sends with no such check.
  """
  @type context :: %{
          required(:deadline_at) => integer(),
          optional(:priority) => Lease.priority(),
          optional(:budget) => (-> :ok | :refused)
        }

  @doc """
  Searches one configured indexer, its secrets in `secrets`, for `query`. Answers the rows and
  the indexer's outcome; see the moduledoc.
  """
  @callback search(ConfiguredIndexer.t(), query(), context()) ::
              {[map()], Report.outcome() | {:failed, :deadline}}

  @doc """
  The per-indexer Test of one configured indexer (#1657): asks it whatever its backoff state
  holds, in `context`'s class, and calls `record` with the Test's answer (`:test_success`, or
  the failure class or tag) while it still holds the indexer's slot. Answers `{:ran, value}`
  with `record`'s value, or `{:not_run, outcome}` when no request left the slot queue, with
  nothing recorded.
  """
  @callback test(
              ConfiguredIndexer.t(),
              context(),
              record :: (IndexerStatus.answer() -> term())
            ) :: {:ran, term()} | {:not_run, Report.outcome()}

  @doc """
  Fetches a grab's download link `url` from one configured indexer, read by id at grab time, for
  the download client whose fetch options are `opts` (#1659). Answers as
  `Cinder.Download.Client.Fetch.bytes/3` does. An adapter without it reads "not supported" for
  a grab (`Cinder.Acquisition.IndexerSource.Native.fetch_download/3`).
  """
  @callback fetch_download(ConfiguredIndexer.t(), url :: String.t(), opts :: keyword()) ::
              {:ok, binary()} | {:magnet, String.t()} | {:error, term()}

  @optional_callbacks fetch_download: 3

  # Newznab and Torznab give each request 30 s of its own.
  @request_timeout_ms 30_000
  @max_response_bytes 4 * 1024 * 1024

  # #1619 point 2: these statuses get one retry before the answer counts.
  @retry_statuses [502, 503, 504, 408]

  @doc """
  Runs `fun` while holding `indexer`'s slot of `Cinder.Acquisition.IndexerSource.Native.Lease`,
  waiting in the queue of `context`'s priority until `context.deadline_at` at most, and answers
  `{:ran, value}` with `fun`'s value. `fun` sends one request through `request/3` and records its
  answer in `Cinder.Acquisition.IndexerSource.Native.IndexerStatus`, so the next request to the
  indexer sees that answer.

  Once the slot is granted, the indexer's backoff state is read again
  (`IndexerStatus.read/1` and `IndexerStatus.gate/2` at Native's `clock`): an answer recorded
  while this request waited can have started a backoff or rejected the credentials. Answers
  `{:not_run, outcome}`, with `fun` never called and nothing recorded:

  - `{:skipped, :deadline}`: the slot was not granted before the deadline, or the lease is down.
  - `{:skipped, {:backoff, until}}` or `{:failed, :rejected_credentials}`: the gate's answer.

  `gate: false` skips that read, for a Test's caps refetch (#1657), which asks an indexer
  whatever its state. `delay_ms:` is the indexer's own spacing, which wins over the lease's
  when longer (a Cardigann definition's `requestDelay`, #1671).
  """
  @spec leased(ConfiguredIndexer.t(), context(), (-> value), keyword()) ::
          {:ran, value} | {:not_run, Report.outcome()}
        when value: term()
  def leased(%ConfiguredIndexer{} = indexer, context, fun, opts \\ []) do
    gate =
      if Keyword.get(opts, :gate, true),
        do: fn -> IndexerStatus.gate(IndexerStatus.read([indexer])[indexer.id], Native.now()) end,
        else: fn -> :ask end

    Lease.run(
      indexer.id,
      [
        deadline_at: context.deadline_at,
        priority: Map.get(context, :priority, :background),
        delay_ms: Keyword.get(opts, :delay_ms, 0),
        gate: gate
      ],
      fun
    )
  end

  @doc "The largest response body in bytes `request/3` reads unless `:max_bytes` sets one, 4 MiB."
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @max_response_bytes

  @doc """
  Sends one adapter request through `Cinder.HTTPPolicy.bounded_request/3` with Req's retry and
  redirects off. The request gets the smaller of its own timeout (`opts[:timeout_ms]`, 30 s by
  default) and the time left before `context.deadline_at`, as its `receive_timeout` and its total
  deadline. With no time left it sends nothing. Its body is read up to `opts[:max_bytes]`,
  `max_response_bytes/0` by default.

  With `context.budget` set, each send, the retry included, first calls it, and a send it
  refuses is never sent and answers `{:error, :deadline}`, as a send with no time left does: an
  adapter reads it as the cut it already handles, and records nothing for it.

  An HTTP 502, 503, 504 or 408 answer gets one retry, sent `retry_delay_ms` after it (2 s unless
  `config :cinder, #{inspect(__MODULE__)}` sets it), and the retry's answer is the answer. When
  that delay is not shorter than the time left before the deadline, the retry is never sent and
  the request answers `{:error, :deadline}`. No other answer is retried.

  Answers `{:ok, response}` or `{:error, tag}`, a closed tag that never carries a URL, a header or
  a body:

  - `:timeout`: a timeout ended the request while the search deadline had not: its own timeout,
    when that was no longer than the time left, or an earlier connect timeout.
  - `:deadline`: the request timed out at the search deadline, which was shorter than its own
    timeout, or no time was left to send it or its retry.
  - `:dns`, `:connection_refused`, `:connection_failed`, `:too_large` or `:bad_response` (a body
    labelled JSON that does not decode), as `Cinder.Acquisition.IndexerSource.Report` defines
    them.

  With `raw_body: true` the response's `content-type` header is moved out of the headers, into
  the response's private `:cinder_content_type`, before `Cinder.HTTPPolicy.bounded_request/3`
  reads it, so a body labelled JSON comes back as its bytes, whatever its status, and never
  reads `:bad_response` here. The Newznab and Torznab adapters read every body themselves
  (`Cinder.Acquisition.Indexer.NewznabAnswer`), and a Cardigann grab reads the label back for
  `Cinder.Download.Client.DownloadCheck` (#1672).

  With `retry: false` no answer is retried: a Cardigann grab's requests (#1672).

  With `redact_path: true` the request's URL path stays out of `Cinder.HTTPPolicy`'s request
  telemetry (`Cinder.HTTPPolicy.redact_path/1`): a Cardigann path can hold a setting's value.
  """
  @spec request(context(), keyword(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, atom()}
  def request(context, request_options, opts \\ []) do
    retry? = Keyword.get(opts, :retry, true)

    case send_once(context, request_options, opts) do
      {:ok, %Req.Response{status: status}} when retry? and status in @retry_statuses ->
        retry(context, request_options, opts)

      answer ->
        answer
    end
  end

  # The one retry: sent `retry_delay_ms` after the first answer when more time than that is left
  # before the deadline; otherwise it is never sent and reads as the deadline.
  defp retry(%{deadline_at: deadline_at} = context, request_options, opts) do
    delay_ms = retry_delay_ms()

    if deadline_at - System.monotonic_time(:millisecond) > delay_ms do
      Process.sleep(delay_ms)
      send_once(context, request_options, opts)
    else
      {:error, :deadline}
    end
  end

  defp retry_delay_ms,
    do: :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(:retry_delay_ms, 2_000)

  defp send_once(%{deadline_at: deadline_at} = context, request_options, opts) do
    own_ms = Keyword.get(opts, :timeout_ms, @request_timeout_ms)
    left_ms = deadline_at - System.monotonic_time(:millisecond)

    if left_ms <= 0 or not charged?(context) do
      {:error, :deadline}
    else
      request_options
      |> Keyword.merge(receive_timeout: min(own_ms, left_ms), retry: false, redirect: false)
      |> Req.new()
      |> raw_body(Keyword.get(opts, :raw_body, false))
      |> redact_path(Keyword.get(opts, :redact_path, false))
      |> HTTPPolicy.bounded_request(
        Keyword.get(opts, :max_bytes, @max_response_bytes),
        min(own_ms, left_ms)
      )
      |> classify(own_ms > left_ms, deadline_at)
    end
  end

  # A parity run's budget (`t:context/0`): a send it refuses is never sent.
  defp charged?(%{budget: budget}) when is_function(budget, 0), do: budget.() == :ok
  defp charged?(_context), do: true

  defp raw_body(request, true),
    do: Req.Request.append_response_steps(request, raw_body: &drop_content_type/1)

  defp raw_body(request, false), do: request

  defp redact_path(request, true), do: HTTPPolicy.redact_path(request)
  defp redact_path(request, false), do: request

  defp drop_content_type({request, response}) do
    case Req.Response.get_header(response, "content-type") do
      [] ->
        {request, response}

      values ->
        response = Req.Response.delete_header(response, "content-type")
        {request, Req.Response.put_private(response, :cinder_content_type, values)}
    end
  end

  defp classify({:ok, response}, _cut_by_deadline?, _deadline_at), do: {:ok, response}

  defp classify({:error, reason}, cut_by_deadline?, deadline_at) do
    if timeout?(reason),
      do: {:error, timeout_tag(cut_by_deadline?, deadline_at)},
      else: {:error, error_tag(reason)}
  end

  # A timeout is the deadline's only when the deadline set the budget and has passed: a connect
  # timeout that fires earlier is the request's own.
  defp timeout_tag(true, deadline_at) do
    if System.monotonic_time(:millisecond) >= deadline_at, do: :deadline, else: :timeout
  end

  defp timeout_tag(false, _deadline_at), do: :timeout

  defp timeout?(:request_timeout), do: true
  defp timeout?(%Req.TransportError{reason: :timeout}), do: true
  defp timeout?(%Req.HTTPError{reason: :timeout}), do: true
  defp timeout?(_reason), do: false

  defp error_tag(%Req.TransportError{reason: :nxdomain}), do: :dns
  defp error_tag(%Req.TransportError{reason: :econnrefused}), do: :connection_refused
  defp error_tag(:response_too_large), do: :too_large
  defp error_tag(:invalid_json), do: :bad_response
  defp error_tag(_reason), do: :connection_failed
end
