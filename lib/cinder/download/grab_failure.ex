defmodule Cinder.Download.GrabFailure do
  @moduledoc """
  Sorts a reserved grab's submission failures for `Cinder.Download`, and decides when a grab
  reserved through an indexer may no longer fetch through it (#1656). It reads and writes no
  download intent: `Cinder.Download` drops or retries the intent on its answer.

  ## Which failures drop the grab

  `drops?/1` answers true for the permanent submission errors (`permanent/0`), among them
  `:bad_download_file`, a fetched body that is neither an NZB nor a torrent (#1658), and for two
  indexer failures:

    * `:indexer_changed`: a local change since the search (`check/1`, `guard_fetch/2`). Nothing
      blocks the release, the movie search pass takes no strike and the TV sweep spends no search
      attempt for it, and a book target is held under it.
    * `:indexer_auth_failed`: the indexer rejected Cinder's credentials when the link was
      fetched, through the source the grab recorded while it is still the selected one
      (`guard_fetch/2` turns it into `:indexer_changed` otherwise). Nothing blocks the release, a
      grab call that returns it counts it as a failed grab, and a book target is held under it.
      It is dropped rather than retried, since a retry would send the rejected key again.

  Every other failure keeps the intent for a retry, of one of three kinds (`retry_class/1`, #1658):

    * `:limit`, `{:indexer_limit, until}` (`Cinder.Download.Client.DownloadCheck`): the indexer
      asked Cinder to wait. The intent counts no attempt, a movie takes no strike, and the next
      attempt waits until `until` or the intent's own delay, whichever is later.
    * `:capped`: the indexer or a host on the link's way failed to send the file. Every fetch
      status the check keeps (`{:nzb_fetch_status, status}`, `{:torrent_fetch_status, status}`),
      `{:indexer_error, code}`, `:indexer_disabled`, `:challenge_page`, `:https_downgrade`,
      `:too_many_redirects`, and each `{:cardigann_grab, tag}` of a Cardigann grab
      (`Cinder.Acquisition.Indexer.Cardigann.Grab`, #1672). Each attempt counts, with a strike
      for a movie still in the search pass. The attempt that reaches `retry_cap/0` drops the
      grab with no block: a movie or TV item searches again while its search budget lasts, and a
      book target still monitored is held under `:grab_retries_exhausted`.
    * `:uncapped`: anything else, such as a transport error or another failure of the client's
      own API, retries with no cap, as before #1658. `:response_too_large` is one, since a
      client's own API reply past its size cap gives it too, after the client may have queued
      the job under the intent's operation key: the next pass looks that key up before it adds.

  The attempt count is the intent's one count, which every kind but `:limit` adds to, so earlier
  uncapped failures bring a capped one closer to the cap.
  """

  alias Cinder.Acquisition.IndexerSource
  alias Cinder.Indexers

  @permanent [
    :unsupported_download_url,
    :bad_torrent,
    :invalid_intent_release,
    :add_rejected,
    :bad_download_file
  ]
  @indexer_failures [:indexer_changed, :indexer_auth_failed]
  @fetch_status_tags [:nzb_fetch_status, :torrent_fetch_status]
  @capped [
    :indexer_disabled,
    :challenge_page,
    :https_downgrade,
    :too_many_redirects
  ]
  @retry_cap 5
  @retry_base_seconds 5
  @retry_max_seconds 300

  @doc "How `reason`, a failure `drops?/1` keeps, is retried; see the moduledoc."
  @spec retry_class(term()) :: :limit | :capped | :uncapped
  def retry_class({:indexer_limit, %DateTime{}}), do: :limit

  def retry_class({tag, status}) when tag in @fetch_status_tags and is_integer(status),
    do: :capped

  def retry_class({:indexer_error, code}) when is_integer(code), do: :capped
  def retry_class({:cardigann_grab, tag}) when is_atom(tag), do: :capped
  def retry_class(reason) when reason in @capped, do: :capped
  def retry_class(_reason), do: :uncapped

  @doc "The attempt count at which a capped failure drops the grab."
  @spec retry_cap() :: pos_integer()
  def retry_cap, do: @retry_cap

  @doc """
  The seconds an intent waits before attempt number `attempt` (1 for the first retry): 5 s,
  doubling each attempt, at most 300 s.
  """
  @spec retry_delay(pos_integer()) :: pos_integer()
  def retry_delay(attempt) when is_integer(attempt) and attempt >= 1,
    do: min(@retry_base_seconds * Integer.pow(2, min(attempt - 1, 6)), @retry_max_seconds)

  @doc """
  The `last_error` an intent stores for `reason`: its inspected form for an atom or a tag with an
  atom or an integer, the tag alone for any other tagged pair, and `"client_error"` for anything
  else, an exception struct included. A downloader error can hold a response body, a request URL
  or an exception struct, so only the stable class is kept.
  """
  @spec retry_error(term()) :: String.t()
  def retry_error(reason) when is_atom(reason), do: inspect(reason)

  def retry_error({tag, value}) when is_atom(tag) and (is_atom(value) or is_integer(value)),
    do: inspect({tag, value})

  def retry_error({tag, _value}) when is_atom(tag), do: inspect(tag)
  def retry_error(_reason), do: "client_error"

  @typedoc "A download client's `fetch:` function (`Cinder.Download.fetch_function/2`)."
  @type fetch :: (String.t(), String.t() | nil, keyword() -> term())

  @doc "The submission errors that drop a reservation for good (`Cinder.Download.permanent_submission_errors/0`)."
  @spec permanent() :: [atom()]
  def permanent, do: @permanent

  @doc "Whether `reason` drops the reserved grab rather than retrying it."
  @spec drops?(term()) :: boolean()
  def drops?(reason), do: reason in @permanent or reason in @indexer_failures

  @doc """
  Whether `reason` is a fact about the release itself, which a held book target blocks by title:
  every permanent submission error. An indexer failure says nothing about the release.
  """
  @spec blocks_book_release?(term()) :: boolean()
  def blocks_book_release?(reason), do: reason in @permanent

  @doc """
  Whether `reason` blocks a TV release the search picked for its series: every permanent
  submission error but `:invalid_intent_release`, which says a stored link could not be read
  back, not that the release is bad (#1492).
  """
  @spec refused_release?(term()) :: boolean()
  def refused_release?(reason), do: reason in @permanent and reason != :invalid_intent_release

  @doc """
  Whether a grab with `provenance` (`Cinder.Download.fetch_source/1`'s) may still fetch through
  its indexer: `:ok`, or `{:error, :indexer_changed}`.

  Only a native grab is checked. It is changed when it recorded no indexer id or no credentials
  version, when its configured indexer was deleted or its secrets no longer decrypt, or when its
  credentials version is older than the configured indexer's. Whether the configured indexer is
  enabled plays no part: a disabled one passes when none of those holds.
  """
  @spec check(keyword()) :: :ok | {:error, :indexer_changed}
  def check(provenance) do
    case Keyword.fetch!(provenance, :indexer_source) do
      "native" -> check_native(provenance[:indexer_id], provenance[:credentials_version])
      _other -> :ok
    end
  end

  defp check_native(id, version) when is_integer(id) and is_integer(version) do
    case Indexers.fetch_with_secrets(id) do
      {:ok, %{credentials_version: current}} when version >= current -> :ok
      _changed -> {:error, :indexer_changed}
    end
  end

  defp check_native(_id, _version), do: {:error, :indexer_changed}

  @doc """
  Wraps `fetch`, which reaches the source `module` a grab recorded, for a source switch in flight:
  when `module` is not the selected source (`IndexerSource.configured/0`, read as the fetch
  fails) and the fetch fails with an error outside `permanent/0`, the wrapper answers
  `{:error, :indexer_changed}` in its place. Every other answer passes through. Each download
  client returns its fetch's error unchanged.
  """
  @spec guard_fetch(fetch(), module()) :: fetch()
  def guard_fetch(fetch, module) do
    fn url, source_origin, opts -> switch_answer(fetch.(url, source_origin, opts), module) end
  end

  defp switch_answer({:error, reason} = error, module) do
    if reason in @permanent or module == IndexerSource.configured(),
      do: error,
      else: {:error, :indexer_changed}
  end

  defp switch_answer(answer, _module), do: answer
end
