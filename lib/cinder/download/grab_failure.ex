defmodule Cinder.Download.GrabFailure do
  @moduledoc """
  Sorts a reserved grab's submission failures for `Cinder.Download`, and decides when a grab
  reserved through an indexer may no longer fetch through it (#1656). It reads and writes no
  download intent: `Cinder.Download` drops or retries the intent on its answer.

  ## Which failures drop the grab

  `drops?/1` answers true for the permanent submission errors (`permanent/0`) and for two
  indexer failures:

    * `:indexer_changed`: a local change since the search (`check/1`, `guard_fetch/2`). Nothing
      blocks the release, the movie search pass takes no strike and the TV sweep spends no search
      attempt for it, and a book target is held under it.
    * `:indexer_auth_failed`: the indexer rejected Cinder's credentials when the link was
      fetched, through the source the grab recorded while it is still the selected one
      (`guard_fetch/2` turns it into `:indexer_changed` otherwise). Nothing blocks the release, a
      grab call that returns it counts it as a failed grab, and a book target is held under it.
      It is dropped rather than retried, since a retry would send the rejected key again.

  Every other failure keeps the intent for a retry.
  """

  alias Cinder.Acquisition.IndexerSource
  alias Cinder.Indexers

  @permanent [:unsupported_download_url, :bad_torrent, :invalid_intent_release, :add_rejected]
  @indexer_failures [:indexer_changed, :indexer_auth_failed]

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
