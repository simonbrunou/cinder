defmodule Cinder.Indexers.ParityRun.LinkCheck do
  @moduledoc """
  The link check of a parity run (`Cinder.Indexers.ParityRun`, #1624 point 14): once per
  configured indexer, its top acceptable row is fetched through
  `Cinder.Acquisition.IndexerSource.Native.fetch_download/3`, as a download client's grab
  fetches it, and nothing is sent to a download client.

  ## The row

  The searches are read in run order. In each, the first try's Native calls are cut to the
  indexer's own rows and judged again by the search's caller (`Cinder.Indexers.Parity.Picks`):
  the first search whose pick is a release, a season, an anime assignment or an accepted book
  gives the row, the Native row of that indexer with the pick's title and size (the first
  release of a season or an anime pick, the top accepted book). An indexer with no such row
  answers `:not_run`.

  ## The fetch

  - A magnet row is not fetched: it passes when `Cinder.Download.Torrent.sanitize_magnet/2`
    reads it, with no tracker kept and no lookup, else `{:failed, :bad_magnet}`.
  - Otherwise the fetch opts carry the row's provenance as `Cinder.Download` adds an intent's
    (`indexer_source` `"native"`, the configured indexer id and the row's `credentials_version`),
    and a download client's byte cap and error tag for the row's protocol: SABnzbd's 20 MiB and
    `:nzb_fetch_status` for Usenet, qBittorrent's 10 MiB, `:torrent_fetch_status` and
    `allow_magnet: true` for a torrent.
  - The fetch spends the run's budget. A Cardigann grab spends one request per send through its
    requests' context. A Newznab or Torznab grab goes through `Cinder.Download.Client.Fetch`,
    which counts no sends, so it spends its most before it starts: one request plus each
    redirect it may follow, five or the allowance left after the first, whichever is fewer. An
    indexer with no request left answers `{:failed, :budget}` and is not fetched, and so does a
    Cardigann grab whose allowance runs out between two of its sends: the fetch answers
    `{:error, :deadline}`, the cut `Cinder.Acquisition.Indexer.request/3` gives a refused send,
    and the allowance shows the refusal.
  - `{:ok, bytes}` passes: `fetch_download/3` answers it only for a body the shared check
    (`Cinder.Download.Client.DownloadCheck`, #1658) reads as an NZB or a torrent. A
    `{:magnet, link}` passes as a magnet row does. Every error answers `{:failed, tag}`, its
    closed tag (`Cinder.Indexers.Parity.Picks.tag/1`).

  Each fetch counts as a grab on the indexer's account.
  """

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Download.Torrent
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Indexers.Parity.{Picks, Rows}
  alias Cinder.Indexers.ParityRun.Budget

  @max_redirects 5
  @nzb_bytes 20 * 1024 * 1024
  @torrent_bytes 10 * 1024 * 1024

  @doc """
  The link check of `indexer` over `searches` (the run's searches, each with its `tries`):
  `:passed`, `{:failed, tag}` or `:not_run`. `fetch_opts` joins the fetch options (a test's
  `plug:` and `resolver:`).
  """
  @spec check(ConfiguredIndexer.t(), [map()], Budget.t(), keyword()) ::
          :passed | {:failed, term()} | :not_run
  def check(%ConfiguredIndexer{} = indexer, searches, budget, fetch_opts \\ []) do
    case top_row(indexer.id, searches) do
      nil -> :not_run
      row -> fetch(indexer, row, budget, fetch_opts)
    end
  end

  defp top_row(cid, searches) do
    Enum.find_value(searches, fn
      %{tries: [%{native: native} | _]} = search ->
        calls = Enum.map(native.calls, &own_rows(&1, cid))
        {key, _outcome} = Picks.replay(search, search.opts, calls)

        with {title, size} <- picked(key) do
          calls
          |> Enum.flat_map(&(Rows.rows(&1.outcome) || []))
          |> Enum.find(&(&1.title == title and (&1.size || 0) == size and &1.download_url))
        end

      _search ->
        nil
    end)
  end

  defp own_rows(call, cid),
    do: %{call | outcome: Rows.map_rows(call.outcome, &Rows.only_cid(&1, :native, cid, %{}))}

  defp picked({:release, {title, size, _rank}}), do: {title, size}
  defp picked({:season, [{{title, size, _rank}, _numbers} | _]}), do: {title, size}
  defp picked({:anime, [{{title, size, _rank}, _ids} | _], _waiting}), do: {title, size}
  defp picked({:books, _accepted, {title, size}}), do: {title, size}
  defp picked(_none), do: nil

  defp fetch(indexer, %{download_url: url} = row, budget, fetch_opts) do
    if Torrent.magnet?(url) do
      magnet(url)
    else
      refused_before? = indexer.id in Budget.refused(budget)

      with {:ok, opts} <- spend(indexer, budget, row_opts(indexer, row) ++ fetch_opts) do
        answer = Native.fetch_download(url, nil, opts)
        refused_or_fetched(answer, refused_before? or indexer.id not in Budget.refused(budget))
      end
    end
  end

  # A send the allowance refused answers the cut of a send with no time left: when this fetch
  # put the indexer among the refused, the cut is the budget's.
  defp refused_or_fetched({:error, :deadline}, false), do: {:failed, :budget}
  defp refused_or_fetched(answer, _not_refused_here), do: fetched(answer)

  defp fetched({:ok, _bytes}), do: :passed
  defp fetched({:magnet, link}), do: magnet(link)
  defp fetched({:error, reason}), do: {:failed, Picks.tag(reason)}

  defp magnet(link) do
    case Torrent.sanitize_magnet(link, fn _hosts -> MapSet.new() end) do
      {:ok, _magnet} -> :passed
      {:error, reason} -> {:failed, reason}
    end
  end

  defp row_opts(indexer, row) do
    provenance = [
      indexer_source: "native",
      indexer_id: indexer.id,
      credentials_version: Map.get(row, :credentials_version)
    ]

    case Map.get(row, :protocol) do
      :usenet ->
        provenance ++ [max_bytes: @nzb_bytes, error_tag: :nzb_fetch_status]

      _torrent ->
        provenance ++
          [max_bytes: @torrent_bytes, error_tag: :torrent_fetch_status, allow_magnet: true]
    end
  end

  defp spend(%ConfiguredIndexer{type: :cardigann, id: id}, budget, opts) do
    if Budget.left(budget, id) > 0,
      do: {:ok, Keyword.put(opts, :budget, fn -> Budget.take(budget, id) end)},
      else: {:failed, :budget}
  end

  defp spend(%ConfiguredIndexer{id: id}, budget, opts) do
    redirects = min(@max_redirects, Budget.left(budget, id) - 1)

    if redirects >= 0 and Budget.take(budget, id, redirects + 1) == :ok,
      do: {:ok, Keyword.put(opts, :redirects, redirects)},
      else: {:failed, :budget}
  end
end
