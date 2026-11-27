defmodule Cinder.Indexers.ParityRun.LinkCheck do
  @moduledoc """
  The link check of a parity run (`Cinder.Indexers.ParityRun`, #1624 point 14): once per
  configured indexer, its top acceptable row is fetched through
  `Cinder.Acquisition.IndexerSource.Native.fetch_download/3`, as a download client's grab
  fetches it, and nothing is sent to a download client.

  ## The row

  The searches are read in run order. In each, the first try's Native calls are cut to the
  indexer's own rows and judged again by the search's caller (`Cinder.Indexers.Parity.Picks`).
  A search whose first try holds no Native row of the indexer is not judged. The row is the
  first one, in search order, that a pick names: a search whose pick is a release, a season, an
  anime assignment or an accepted book names the indexer's Native row with the pick's title and
  size (the first release of a season or an anime pick, the top accepted book) and a link. A
  pick with no such row names none, and the next search is read.

  When no pick names a row, the row is the indexer's first Native row with a link in those first
  tries, in search order, then call order, then the call's row order (#1971). This is the
  triage reading of #1624 point 14's "top acceptable row": the caller's pick when there is one,
  else that row. Its check is fetched as below and answers `{:unpicked, check}`, and an
  `{:unpicked, :passed}` counts as a pass (`Cinder.Indexers.Parity`). On #1944's probe the
  caller picked none of Torrent9's season rows, whose names carry no year and no resolution.

  An indexer with no row to fetch answers `{:not_run, reason}` (#1954): `:no_rows` when no
  search's first try holds a Native row of it, else `{:picks, picks}`, one `{index, tag}` per
  search whose first try held one, in run order, `index` its place in `searches` from 0. `tag`
  is `:no_link` when the caller picked a row but none of the indexer's rows with that title and
  size has a link, else the pick's key as `pick_tag/1` reduces it. The check runs before any
  retry, so it reads first tries only.

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

  @typedoc "What a fetched row's check answers. See the moduledoc."
  @type fetched :: :passed | {:failed, term()}

  @typedoc "Why a link check did not run. See the moduledoc."
  @type not_run :: :no_rows | {:picks, [{non_neg_integer(), pick_tag()}]}

  @typedoc "A pick key that gives no row to fetch, as a closed tag. See `pick_tag/1`."
  @type pick_tag ::
          :no_link
          | :no_match
          | :no_language_match
          | :waiting
          | {:season | :anime | :books, :none}
          | {:error, atom() | {atom(), integer()}}
          | :other

  @doc """
  The link check of `indexer` over `searches` (the run's searches, each with its `tries`):
  `:passed` or `{:failed, tag}` for the picked row, either of those as `{:unpicked, check}` for
  an unpicked row, or `{:not_run, reason}`. `fetch_opts` joins the fetch options (a test's
  `plug:` and `resolver:`).
  """
  @spec check(ConfiguredIndexer.t(), [map()], Budget.t(), keyword()) ::
          fetched() | {:unpicked, fetched()} | {:not_run, not_run()}
  def check(%ConfiguredIndexer{} = indexer, searches, budget, fetch_opts \\ []) do
    case top_row(indexer.id, searches) do
      {:row, row} -> fetch(indexer, row, budget, fetch_opts)
      {:unpicked, row} -> {:unpicked, fetch(indexer, row, budget, fetch_opts)}
      {:not_run, reason} -> {:not_run, reason}
    end
  end

  @doc """
  A pick key (`Cinder.Indexers.Parity.Picks.key/2`) that gives no row to fetch, as a closed tag:
  `:no_match` and `:no_language_match` stay, a group wait is `:waiting`, a season, anime or book
  pick with nothing in it is `{kind, :none}`, an error keeps its tag (`Picks.tag/1`), and any
  other key is `:other`. A tag never holds a title, a link or a wait's ids and time.
  """
  @spec pick_tag(term()) :: pick_tag()
  def pick_tag(key) when key in [:no_match, :no_language_match], do: key
  def pick_tag({:waiting, _wait}), do: :waiting
  def pick_tag({:season, []}), do: {:season, :none}
  def pick_tag({:anime, [], _wait}), do: {:anime, :none}
  def pick_tag({:books, [], nil}), do: {:books, :none}
  def pick_tag({:error, reason}), do: {:error, Picks.tag(reason)}
  def pick_tag(_key), do: :other

  # The picked row, else the first own row with a link (#1971), else why there is none.
  defp top_row(cid, searches) do
    searches
    |> Enum.with_index()
    |> Enum.reduce_while({[], nil}, fn {search, index}, {picks, unpicked} ->
      case own_pick(search, cid) do
        nil -> {:cont, {picks, unpicked}}
        {:row, row} -> {:halt, {:row, row}}
        {{:none, tag}, rows} -> {:cont, {[{index, tag} | picks], unpicked || linked_row(rows)}}
      end
    end)
    |> case do
      {:row, row} -> {:row, row}
      {_picks, %{} = row} -> {:unpicked, row}
      {[], nil} -> {:not_run, :no_rows}
      {picks, nil} -> {:not_run, {:picks, Enum.reverse(picks)}}
    end
  end

  # The caller's pick over the indexer's own rows of the search's first try: `{:row, row}`,
  # `{{:none, tag}, rows}` with those rows, or nil when the try holds no such row.
  defp own_pick(%{tries: [%{native: native} | _]} = search, cid) do
    calls = Enum.map(native.calls, &own_rows(&1, cid))

    case Enum.flat_map(calls, &(Rows.rows(&1.outcome) || [])) do
      [] ->
        nil

      rows ->
        search |> Picks.replay(search.opts, calls) |> elem(0) |> row_of(rows) |> with_rows(rows)
    end
  end

  defp own_pick(_search, _cid), do: nil

  # A pick that names no row comes with the rows it was judged over, for the unpicked row.
  defp with_rows({:row, row}, _rows), do: {:row, row}
  defp with_rows(none, rows), do: {none, rows}

  defp linked_row(rows), do: Enum.find(rows, & &1.download_url)

  defp row_of(key, rows) do
    case picked(key) do
      nil -> {:none, pick_tag(key)}
      {title, size} -> linked(rows, title, size)
    end
  end

  defp linked(rows, title, size) do
    case Enum.find(rows, &(&1.title == title and (&1.size || 0) == size and &1.download_url)) do
      nil -> {:none, :no_link}
      row -> {:row, row}
    end
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
