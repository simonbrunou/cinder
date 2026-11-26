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
  and the time left before the search deadline in `t:context/0`.
  """

  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.HTTPPolicy
  alias Cinder.Indexers.ConfiguredIndexer

  @typedoc """
  One seam call's query, by the `Cinder.Acquisition.IndexerSource` callback that made it, with
  that callback's arguments.
  """
  @type query ::
          {:search, imdb_id :: String.t()}
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
  deadline in `System.monotonic_time(:millisecond)`.
  """
  @type context :: %{deadline_at: integer()}

  @doc """
  Searches one configured indexer, its secrets in `secrets`, for `query`. Answers the rows and
  the indexer's outcome; see the moduledoc.
  """
  @callback search(ConfiguredIndexer.t(), query(), context()) ::
              {[map()], Report.outcome() | {:failed, :deadline}}

  # Newznab and Torznab give each request 30 s of its own.
  @request_timeout_ms 30_000
  @max_response_bytes 4 * 1024 * 1024

  @doc """
  Sends one adapter request through `Cinder.HTTPPolicy.bounded_request/3` with Req's retry and
  redirects off. The request gets the smaller of its own timeout (`opts[:timeout_ms]`, 30 s by
  default) and the time left before `context.deadline_at`, as its `receive_timeout` and its total
  deadline. With no time left it sends nothing.

  Answers `{:ok, response}` or `{:error, tag}`, a closed tag that never carries a URL, a header or
  a body:

  - `:timeout`: a timeout ended the request while the search deadline had not: its own timeout,
    when that was no longer than the time left, or an earlier connect timeout.
  - `:deadline`: the request timed out at the search deadline, which was shorter than its own
    timeout, or no time was left to send it.
  - `:dns`, `:connection_refused`, `:connection_failed`, `:too_large` or `:bad_response` (a body
    labelled JSON that does not decode), as `Cinder.Acquisition.IndexerSource.Report` defines
    them.
  """
  @spec request(context(), keyword(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, atom()}
  def request(%{deadline_at: deadline_at}, request_options, opts \\ []) do
    own_ms = Keyword.get(opts, :timeout_ms, @request_timeout_ms)
    left_ms = deadline_at - System.monotonic_time(:millisecond)

    if left_ms <= 0 do
      {:error, :deadline}
    else
      request_options
      |> Keyword.merge(receive_timeout: min(own_ms, left_ms), retry: false, redirect: false)
      |> Req.new()
      |> HTTPPolicy.bounded_request(@max_response_bytes, min(own_ms, left_ms))
      |> classify(own_ms > left_ms, deadline_at)
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
