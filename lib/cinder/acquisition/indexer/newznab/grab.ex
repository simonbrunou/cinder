defmodule Cinder.Acquisition.Indexer.Newznab.Grab do
  @moduledoc """
  The grab fetch of `Cinder.Acquisition.Indexer.Newznab` and `Cinder.Acquisition.Indexer.Torznab`
  (#1659): fetches a grab's download link from one configured indexer, read by id at grab time
  (`Cinder.Acquisition.IndexerSource.Native.fetch_download/3`), and records in Native's backoff
  state what the answer says about that indexer.

  ## The fetch

  A plain fetch: Newznab and Torznab put the indexer's key in the link itself, so none is added
  (#1621 point 1). `Cinder.Download.Client.Fetch.attributed/3` fetches the link under the download
  client's options, with the configured indexer's base URL origin as the source origin. That
  origin is read from the row (`Cinder.HTTPPolicy.source_origin/1`); the origin the search
  stored with the link plays no part. A link on that origin is fetched as a trusted source
  request, and so is each redirect that stays on it while every hop before it did. Any other
  link, a cross-origin redirect and every hop after one, a redirect back to the origin included,
  take `Fetch`'s untrusted path: DNS-pinned, public addresses only. A trusted redirect to a path
  ending in `/login` is not followed: its answer is the login sign the check reads, unless five
  redirects came before it, which is `{:error, :too_many_redirects}` and records nothing. A
  redirect to a magnet is `{:magnet, link}` only under the client's `allow_magnet`, as `Fetch`
  answers it. The answer then goes through
  `Cinder.Download.Client.DownloadCheck.check_classified/2` under the client's `max_bytes`, and
  the client gets its first element. The fetch waits for no slot of
  `Cinder.Acquisition.IndexerSource.Native.Lease` and reads no backoff state.

  ## What the grab records

  `Cinder.Acquisition.IndexerSource.Native.IndexerStatus.record/3`, at Native's clock
  (`Cinder.Acquisition.IndexerSource.Native.now/0`) read once before the check, which counts a
  stated wait from that same reading (#1932), for the configured indexer as Native read it
  before the fetch, so the answer of a fetch that started under another `config_version`, or for
  an indexer deleted meanwhile, is dropped. The first row that matches the client's answer wins:

  | Client's answer | Recorded |
  |---|---|
  | `{:error, :indexer_auth_failed}` | `:indexer_auth_failed`: rejected credentials |
  | `{:error, {:indexer_limit, until}}` | `{:limit, until}`: a limit backoff until `until` |
  | `{:error, :indexer_disabled}` | `{:disabled_till, wait}`, the answer's stated wait |
  | `{:error, {:indexer_error, code}}` | `{:indexer_error, code}`: a failure step |
  | `{:error, :challenge_page}` from a trusted answer | `:challenge`: a failure step |
  | `{:error, {tag, status}}`, a trusted answer's 5xx | `{:http_status, status}`: a failure step |
  | `{:error, :https_downgrade}` the origin sent | `:bad_response`: a failure step |
  | anything else | nothing |

  "Trusted" is `Fetch`'s `:trusted`: every hop stayed on the base URL's origin. The check gives
  the first four reasons only for such an answer, so an indexer sign from another host never
  records. A `:https_downgrade` records only when a hop on that origin, after only such hops,
  sent the redirect (`Fetch.attributed/3`'s `from_source`): one sent by a host the indexer
  redirected to, such as a CDN, records nothing. A recognised file, a magnet,
  `:bad_download_file`, any other status and any other fetch error record nothing.
  """

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.Download.Client.{DownloadCheck, Fetch}
  alias Cinder.HTTPPolicy
  alias Cinder.Indexers.ConfiguredIndexer

  @doc "Fetches `url` from `indexer` with the client's `opts`; see the moduledoc."
  @spec fetch_download(ConfiguredIndexer.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:magnet, String.t()} | {:error, term()}
  def fetch_download(%ConfiguredIndexer{} = indexer, url, opts) when is_binary(url) do
    origin = HTTPPolicy.source_origin(indexer.base_url)
    {fetched, from_source} = Fetch.attributed(url, origin, opts)
    checked_and_recorded(indexer, fetched, from_source, opts)
  end

  @doc """
  Checks `fetched`, a `Fetch.attributed/3`-shaped answer beside `from_source`, through
  `DownloadCheck.check_classified/2` under `opts`, records in `indexer`'s backoff state what the
  moduledoc's table says, and answers the check's answer.
  `Cinder.Acquisition.Indexer.Cardigann.Grab` shares the table (#1672).
  """
  @spec checked_and_recorded(
          ConfiguredIndexer.t(),
          {:ok, Fetch.answer()} | {:magnet, String.t()} | {:error, term()},
          boolean(),
          keyword()
        ) :: {:ok, binary()} | {:magnet, String.t()} | {:error, term()}
  def checked_and_recorded(%ConfiguredIndexer{} = indexer, fetched, from_source, opts) do
    now = Native.now()
    {checked, class} = DownloadCheck.check_classified(fetched, Keyword.put(opts, :now, now))

    case recorded(checked, fetched, class, from_source) do
      nil -> :ok
      answer -> IndexerStatus.record(indexer, answer, now)
    end

    checked
  end

  defp recorded({:error, :indexer_auth_failed}, _fetched, _class, _from_source),
    do: :indexer_auth_failed

  defp recorded({:error, {:indexer_limit, until}}, _fetched, _class, _from_source),
    do: {:limit, until}

  defp recorded({:error, :indexer_disabled}, _fetched, {:disabled_till, wait}, _from_source),
    do: {:disabled_till, wait}

  defp recorded({:error, {:indexer_error, code}}, _fetched, _class, _from_source),
    do: {:indexer_error, code}

  defp recorded({:error, :challenge_page}, {:ok, %{trusted: true}}, _class, _from_source),
    do: :challenge

  defp recorded({:error, {_tag, status}}, {:ok, %{trusted: true, status: status}}, _class, _from)
       when status in 500..599,
       do: {:http_status, status}

  defp recorded({:error, :https_downgrade}, _fetched, _class, true = _from_source),
    do: :bad_response

  defp recorded(_checked, _fetched, _class, _from_source), do: nil
end
