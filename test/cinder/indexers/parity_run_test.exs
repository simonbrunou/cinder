defmodule Cinder.Indexers.ParityRunTest do
  # End to end through `Cinder.Indexers.ParityRun.run/1` (#1684): configured Newznab and Torznab
  # indexers behind the `Cinder.NewznabStub` plug (`Cinder.NewznabFixtures.route/1`), Prowlarr's
  # search behind `Cinder.ProwlarrStub` and its history and status behind
  # `Cinder.ProwlarrApiStub`, with the real callers and the real engine. Each test reads the
  # report the run prints and the requests the stubs received.
  #
  # No download client mock has an expectation, so a call to one raises and the run prints
  # `Parity run failed: raised Mox.UnexpectedCallError`: every passing run shows that the link
  # check sent nothing to a download client.
  #
  # Not async: the run registers one name per node, and Native's clock is global config.
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import Cinder.NewznabFixtures
  import ExUnit.CaptureIO
  import Mox

  alias Cinder.Acquisition.Indexer
  alias Cinder.Acquisition.IndexerSource.{Native, Prowlarr, Report}
  alias Cinder.Catalog.BlockedRelease
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Indexers.Parity.Picks
  alias Cinder.Indexers.ParityRun
  alias Cinder.Indexers.ParityRun.{Budget, Corpus, IndexerSet, LinkCheck}
  alias Cinder.Indexers.ProwlarrApi.HTTP
  alias Cinder.ProwlarrHistoryFixtures
  alias Cinder.Repo

  @key "SYNTHETICKEY123"
  @public_address {93, 184, 216, 34}
  @magnet "magnet:?xt=urn:btih:#{String.duplicate("a", 40)}&dn=Movie"

  defmodule LeakyRelease do
    @moduledoc false
    defstruct [:title, :download_url]
  end

  setup do
    stub_with(Cinder.Indexers.ProwlarrApiMock, HTTP)
    history = start_supervised!({Agent, fn -> [] end}, id: :history)
    statuses = start_supervised!({Agent, fn -> [] end}, id: :statuses)
    %{history: history, statuses: statuses}
  end

  # --- the world ---

  # Movie search by IMDb id alone, so `:movie_imdb` is the one kind the indexer takes and a run
  # of that kind alone covers every cell.
  @caps caps(
          modes: %{"movie-search" => ~s(available="yes" supportedParams="q,imdbid")},
          categories: [2000, 2040]
        )

  # Links `indexer` to Prowlarr indexer `pid`, as the Prowlarr import writes it (#1673).
  defp link!(indexer, pid) do
    Repo.update_all(Ecto.Query.where(ConfiguredIndexer, id: ^indexer.id),
      set: [prowlarr_indexer_id: pid]
    )

    %{indexer | prowlarr_indexer_id: pid}
  end

  # Stubs both sides from `specs`, one per host: `%{pid, protocol, rows, get}`, plus `caps:` and
  # `category:` (2040 by default) when given. `rows.(side, n)`
  # answers the `n`th search request (from 1) that side sends the indexer, `[{title, size}]`;
  # `get` answers its link fetch (a body, or `{status, body}`). Prowlarr answers each asked id
  # with that id's host's rows, and writes one history entry per asked id. Every request reports
  # itself to the test process.
  defp world(specs, history) do
    counter = start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    next = fn key ->
      Agent.get_and_update(
        counter,
        &Map.get_and_update(&1, key, fn n -> {(n || 0) + 1, (n || 0) + 1} end)
      )
    end

    by_pid = Map.new(specs, fn {host, spec} -> {spec.pid, {host, spec}} end)
    test_pid = self()

    route(
      Map.new(specs, fn {host, spec} ->
        {host,
         fn conn, query ->
           link? = String.starts_with?(conn.request_path, "/dl/")
           send(test_pid, {:timed, if(link?, do: :link, else: :request), host, mono()})
           native_answer(link?, query, host, spec, next)
         end}
      end)
    )

    prowlarr_search(history, fn _params, ids ->
      for id <- ids,
          {host, _spec} <- List.wrap(Map.get(by_pid, id)),
          do: send(test_pid, {:timed, :request, host, mono()})

      for id <- ids,
          {host, spec} <- List.wrap(Map.get(by_pid, id)),
          {title, size} <- spec.rows.(:prowlarr, next.({:prowlarr, host})),
          do: prowlarr_row(title, size, id, spec)
    end)
  end

  defp native_answer(true, _query, _host, spec, _next), do: Map.fetch!(spec, :get)

  defp native_answer(false, %{"t" => "caps"}, _host, spec, _next), do: Map.get(spec, :caps, @caps)

  defp native_answer(false, _query, host, spec, next) do
    rss(
      for {title, size} <- spec.rows.(:native, next.({:native, host})),
          do: native_item(host, spec, title, size)
    )
  end

  defp native_item(host, %{protocol: protocol} = spec, title, size) do
    link =
      case protocol do
        :usenet ->
          {:nzb, "https://#{host}/dl/#{:erlang.phash2(title)}?apikey=#{key()}"}

        :torrent ->
          {:torrent, "https://#{host}/dl/#{:erlang.phash2(title)}.torrent?apikey=#{key()}"}

        :magnet ->
          {:magnet, @magnet}
      end

    item(title, link, size: size, category: Map.get(spec, :category, 2040))
  end

  defp prowlarr_row(title, size, pid, %{protocol: protocol} = spec) do
    link =
      if protocol == :magnet,
        do: %{"magnetUrl" => @magnet},
        else: %{
          "downloadUrl" =>
            "http://prowlarr:9696/#{pid}/download?link=#{:erlang.phash2(title)}&apikey=#{@key}"
        }

    Map.merge(link, %{
      "title" => title,
      "size" => size,
      "protocol" => if(protocol == :usenet, do: "usenet", else: "torrent"),
      "indexerId" => pid,
      "indexer" => "idx #{pid}",
      "publishDate" => "2026-11-25T10:30:00Z",
      "categories" => [%{"id" => Map.get(spec, :category, 2040)}]
    })
  end

  # Prowlarr's search: answers each request with `answer.(params, ids)` and writes one
  # successful history entry per asked indexer id for which `queried?.(params, id)` holds, dated
  # now in whole seconds, as Prowlarr's `HistoryService` and `STJUtcConverter` write it
  # (`b0b5774`). Reports `{:prowlarr_search, params, ids}` to the test process.
  defp prowlarr_search(history, answer, queried? \\ fn _params, _id -> true end) do
    test_pid = self()

    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      pairs = conn.query_string |> URI.query_decoder() |> Enum.to_list()
      ids = for {"indexerIds", id} <- pairs, do: String.to_integer(id)
      params = Map.new(pairs)
      send(test_pid, {:prowlarr_search, params, ids})
      results = answer.(params, ids)
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      added =
        for id <- ids,
            queried?.(params, id),
            do: entry(id, now, Enum.count(results, &(&1["indexerId"] == id)), params)

      Agent.update(history, &(added ++ &1))

      Req.Test.json(conn, results)
    end)
  end

  defp entry(indexer_id, date, count, params) do
    %{
      "id" => System.unique_integer([:positive]),
      "indexerId" => indexer_id,
      "date" => date,
      "downloadId" => nil,
      "successful" => true,
      "eventType" => "indexerQuery",
      "data" =>
        Map.merge(written(params), %{
          "queryResults" => Integer.to_string(count),
          "url" => "https://indexer.example/api?apikey=#{@key}",
          "host" => "cinder.example",
          "source" => "Prowlarr",
          "cached" => "0"
        })
    }
  end

  # What Prowlarr 3.1's `HistoryService` writes for a search request's `query`, `type` and
  # `categories` (`Cinder.ProwlarrHistoryFixtures`).
  defp written(params) do
    %{"query" => query, "type" => type} = params
    {term, fields} = ProwlarrHistoryFixtures.written(query, type)

    Map.merge(fields, %{
      "query" => term,
      "queryType" => type,
      "categories" => Map.get(params, "categories", "")
    })
  end

  # Prowlarr's history and status reads: the entries the search stub wrote, and the statuses
  # agent's list, which `statuses.(n)` can replace per read (from 1).
  defp prowlarr_api(history, statuses) do
    test_pid = self()

    Req.Test.stub(Cinder.ProwlarrApiStub, fn conn ->
      case conn.request_path do
        "/api/v1/history" ->
          records = Agent.get(history, & &1)

          json(conn, %{
            "page" => 1,
            "pageSize" => 500,
            "totalRecords" => length(records),
            "records" => Enum.sort_by(records, & &1["date"], :desc)
          })

        "/api/v1/indexerstatus" ->
          send(test_pid, :prowlarr_status)
          json(conn, Agent.get(statuses, & &1))
      end
    end)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json", "utf-8")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp run!(opts) do
    defaults = [
      seed: 1,
      retry_spacing_s: 0,
      indexer_spacing_ms: 0,
      history_wait_ms: 0,
      fetch_opts: [
        plug: {Req.Test, Cinder.NewznabStub},
        resolver: fn _host -> {:ok, [@public_address]} end
      ]
    ]

    capture_io(fn -> send(self(), {:result, ParityRun.run(Keyword.merge(defaults, opts))}) end)
  end

  defp prowlarr_ids do
    receive_all(fn
      {:prowlarr_search, _params, ids} -> ids
    end)
  end

  defp receive_all(fun, acc \\ []) do
    receive do
      {:prowlarr_search, _params, _ids} = message -> receive_all(fun, [fun.(message) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp search_count(host), do: length(searches(host))

  defp same(title, size), do: fn _side, _n -> [{title, size}] end

  # The report's reason line for `indexer`'s link check, whole.
  defp assert_link_line(report, indexer, text) do
    line = "  newznab nzb.example (##{indexer.id}) link check: #{text}"
    assert line in String.split(report, "\n"), report
  end

  defp inception, do: movie_fixture(%{imdb_id: "tt1375666", title: "Inception", year: 2010})

  defp nzb(pid, rows),
    do: %{pid: pid, protocol: :usenet, rows: rows, get: Cinder.NzbFixture.minimal()}

  @title "Inception.2010.1080p.WEB-DL-GRP"
  @size 9_000_000_000

  # --- a run that passes ---

  test "a movie found alike by one Newznab indexer on both sides, with its NZB link, passes",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    world(%{"nzb.example" => nzb(7, same(@title, @size))}, history)
    prowlarr_api(history, statuses)

    report = run!(counts: %{movie_imdb: 1}, indexers: [indexer.id])

    assert_received {:result, :ok}
    assert report =~ "Verdict: pass"
    assert report =~ "link check passed"
    assert prowlarr_ids() == [[7]]
    refute report =~ @key
    refute report =~ key()
  end

  test "two Newznab indexers and a Torznab one, each found alike on both sides, pass",
       %{history: history, statuses: statuses} do
    a = :newznab |> indexer!("a.example") |> link!(7)
    b = :newznab |> indexer!("b.example") |> link!(8)
    t = :torznab |> indexer!("t.example") |> link!(9)
    inception()

    world(
      %{
        "a.example" => nzb(7, same("Inception.2010.1080p.WEB-DL-A", @size)),
        "b.example" => nzb(8, same("Inception.2010.720p.WEB-DL-B", 4_000_000_000)),
        "t.example" => %{
          pid: 9,
          protocol: :torrent,
          rows: same("Inception.2010.1080p.BluRay-T", 8_000_000_000),
          get: Cinder.TorrentFixture.minimal()
        }
      },
      history
    )

    prowlarr_api(history, statuses)

    report = run!(counts: %{movie_imdb: 1}, indexers: [a.id, b.id, t.id])

    assert_received {:result, :ok}
    assert report =~ "Verdict: pass"
    assert prowlarr_ids() == [[7, 8, 9]]
  end

  test "a magnet row passes its link check with no fetch", %{history: history, statuses: statuses} do
    t = :torznab |> indexer!("t.example") |> link!(9)
    inception()

    world(
      %{"t.example" => %{pid: 9, protocol: :magnet, rows: same(@title, @size), get: "unused"}},
      history
    )

    prowlarr_api(history, statuses)

    report = run!(counts: %{movie_imdb: 1}, indexers: [t.id])

    assert_received {:result, :ok}
    assert report =~ "link check passed"
  end

  # --- the link check's failures ---

  for {name, get, tag} <- [
        {"a 401", {401, "Unauthorized apikey=#{@key}"}, "indexer_auth_failed"},
        {"an HTML page",
         {200, [{"content-type", "text/html"}],
          ~s(<html><body><a href="https://nzb.example/?apikey=#{@key}">Hi</a></body></html>)},
         "challenge_page"},
        {"a body that is no NZB",
         {200, [{"content-type", "application/x-nzb"}], "not an nzb apikey=#{@key}"},
         "bad_download_file"}
      ] do
    test "a link answering #{name} fails the link check with #{tag}",
         %{history: history, statuses: statuses} do
      indexer = :newznab |> indexer!("nzb.example") |> link!(7)
      inception()

      world(
        %{"nzb.example" => %{nzb(7, same(@title, @size)) | get: unquote(Macro.escape(get))}},
        history
      )

      prowlarr_api(history, statuses)

      report = run!(counts: %{movie_imdb: 1}, indexers: [indexer.id])

      assert_received {:result, :ok}
      assert report =~ "link check failed #{unquote(tag)}"
      refute report =~ "Verdict: pass"
      refute report =~ @key
    end
  end

  # The byte caps of SABnzbd (20 MiB) and qBittorrent (10 MiB): a body of the cap passes, one
  # byte more fails as the client's own fetch refuses it.
  for {protocol, cap} <- [usenet: 20 * 1024 * 1024, torrent: 10 * 1024 * 1024],
      {bytes, outcome} <- [{cap, "link check passed"}, {cap + 1, "failed response_too_large"}] do
    test "a #{protocol} link of #{bytes} bytes: #{outcome}",
         %{history: history, statuses: statuses} do
      type = if unquote(protocol) == :usenet, do: :newznab, else: :torznab
      indexer = type |> indexer!("dl.example") |> link!(7)
      inception()
      body = padded(unquote(protocol), unquote(bytes))
      assert byte_size(body) == unquote(bytes)

      world(
        %{
          "dl.example" => %{
            pid: 7,
            protocol: unquote(protocol),
            rows: same(@title, @size),
            get: body
          }
        },
        history
      )

      prowlarr_api(history, statuses)

      report = run!(counts: %{movie_imdb: 1}, indexers: [indexer.id])

      assert_received {:result, :ok}
      assert report =~ unquote(outcome)
    end
  end

  # A valid NZB or torrent of exactly `bytes` bytes.
  defp padded(:usenet, bytes) do
    nzb = Cinder.NzbFixture.minimal()
    nzb <> String.duplicate(" ", bytes - byte_size(nzb))
  end

  defp padded(:torrent, bytes) do
    open = String.slice(Cinder.TorrentFixture.minimal(), 0..-2//1) <> "3:zzz"
    pad = bytes - byte_size(open) - 1
    # The padding string's length prefix takes some of the bytes too.
    len = pad - String.length("#{pad}:")
    len = if String.length("#{len}:") + len == pad, do: len, else: len + 1
    open <> "#{len}:" <> String.duplicate("z", len) <> "e"
  end

  # --- a link check that does not run (#1954) ---

  test "an indexer with no Native row in any search reads not_run with no_rows, and is not fetched",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    world(%{"nzb.example" => nzb(7, fn _side, _n -> [] end)}, history)
    prowlarr_api(history, statuses)

    report = run!(counts: %{movie_imdb: 1}, indexers: [indexer.id])

    assert_received {:result, :ok}
    assert_link_line(report, indexer, "not_run (no Native row in any first try)")
    # Native's one search, and no link fetch.
    assert search_count("nzb.example") == 1
  end

  # The link check runs before any retry: a Native row that only the second try returns gives it
  # no row, and the reason says first try.
  test "a Native row only a retry returns leaves the link check at no_rows",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()

    rows = fn
      :native, 1 -> []
      _side, _n -> [{@title, @size}]
    end

    world(%{"nzb.example" => nzb(7, rows)}, history)
    prowlarr_api(history, statuses)

    report = run!(counts: %{movie_imdb: 1}, indexers: [indexer.id])

    assert_received {:result, :ok}
    assert report =~ "try 2: ok"
    assert_link_line(report, indexer, "not_run (no Native row in any first try)")
    # Native's two searches, and no link fetch.
    assert search_count("nzb.example") == 2
  end

  # #1971, Torrent9's case on #1944's probe: the first search's Native call answers no row, the
  # second's one the caller's title guard drops. Both sides return that row, so the indexer has
  # evidence, and the link check fetches it, unpicked, so the run passes. (Before #1971 the check
  # read `not_run (pick over its own first-try rows: #1 no_match)`.)
  test "an indexer whose own rows the caller picks nothing from passes on its first row with a link",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    movie_fixture(%{imdb_id: "tt0816692", title: "Interstellar", year: 2014})

    rows = fn
      _side, 1 -> []
      _side, _n -> [{"Unrelated.Film.2001.1080p.WEB-DL-GRP", @size}]
    end

    world(%{"nzb.example" => nzb(7, rows)}, history)
    prowlarr_api(history, statuses)

    report = run!(counts: %{movie_imdb: 2}, indexers: [indexer.id])

    assert_received {:result, :ok}
    lines = String.split(report, "\n")
    assert "Verdict: pass" in lines, report
    name = "newznab nzb.example (##{indexer.id})"
    assert "  #{name}: matching rows found, link check passed (unpicked row)" in lines, report
    refute report =~ "Unrelated"
  end

  # --- the opts both sides get ---

  test "a block scoped to the Prowlarr indexer also skips the title on Native's side",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    series = series_fixture(%{title: "The Office", year: nil, tvdb_id: 73_244})
    season = season_fixture(series, %{season_number: 1})
    episode_fixture(season, %{episode_number: 1})
    episode_fixture(season, %{episode_number: 2})
    blocked = "The.Office.S01.1080p.WEB-DL-BAD"
    kept = "The.Office.S01.1080p.WEB-DL-OK"

    Repo.insert!(%BlockedRelease{
      series_id: series.id,
      release_title: blocked,
      reason: "stalled",
      indexer_source: "prowlarr",
      indexer_id: 7
    })

    rows = fn _side, _n -> [{blocked, 1_600_000_000}, {kept, 1_500_000_000}] end

    world(
      %{
        "nzb.example" =>
          7
          |> nzb(rows)
          |> Map.merge(%{
            category: 5040,
            caps:
              caps(
                modes: %{"tv-search" => ~s(available="yes" supportedParams="q,season,ep,tvdbid")},
                categories: [5000, 5040]
              )
          })
      },
      history
    )

    prowlarr_api(history, statuses)

    report = run!(counts: %{season: 1}, indexers: [indexer.id])

    # The TV kinds this run leaves out read uncovered, so the verdict is inconclusive; without
    # the twin, Native would pick the blocked title and the season cell would fail.
    assert_received {:result, :ok}
    assert report =~ "season: covered"
    assert report =~ "matching rows found, link check passed"
    refute report =~ "fail"
  end

  # --- a kind the library cannot draw (#1915) ---

  # A standard series with season 1 alone, and an indexer whose TV caps take `:season`,
  # `:season_zero` and `:anime_episodes`. The library holds no season 0 and no anime series.
  defp season_one_world(history, statuses) do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    series = series_fixture(%{title: "The Office", year: nil, tvdb_id: 73_244})
    season = season_fixture(series, %{season_number: 1})
    episode_fixture(season, %{episode_number: 1})
    episode_fixture(season, %{episode_number: 2})

    world(
      %{
        "nzb.example" =>
          7
          |> nzb(same("The.Office.S01.1080p.WEB-DL-OK", 1_500_000_000))
          |> Map.merge(%{
            category: 5040,
            caps:
              caps(
                modes: %{"tv-search" => ~s(available="yes" supportedParams="q,season,ep,tvdbid")},
                categories: [5000, 5040]
              )
          })
      },
      history
    )

    prowlarr_api(history, statuses)
    indexer
  end

  test "a planned kind the library has no candidate for is not asked, and the run passes",
       %{history: history, statuses: statuses} do
    indexer = season_one_world(history, statuses)

    report =
      run!(counts: %{season: 1, season_zero: 1, anime_episodes: 1}, indexers: [indexer.id])

    lines = String.split(report, "\n")
    assert_received {:result, :ok}
    assert report =~ "season 1, season_zero 1, anime_episodes 1, ebook 0, audiobook 0; drawn: 1\n"
    assert "Verdict: pass" in lines
    assert "not drawn: season_zero (no candidate in the library)" in lines
    assert "not drawn: anime_episodes (no candidate in the library)" in lines
    name = "#{indexer.name} (##{indexer.id})"
    assert "  #{name} season: covered" in lines
    assert "  #{name} season_zero: not asked (no candidate in the library)" in lines
    assert "  #{name} anime_episodes: not asked (no candidate in the library)" in lines
  end

  test "a kind the counts leave out is not planned and still reads uncovered",
       %{history: history, statuses: statuses} do
    indexer = season_one_world(history, statuses)

    report = run!(counts: %{season: 1, season_zero: 0}, indexers: [indexer.id])

    lines = String.split(report, "\n")
    assert_received {:result, :ok}
    assert "Verdict: inconclusive" in lines
    name = "#{indexer.name} (##{indexer.id})"
    assert "  #{name} season: covered" in lines
    assert "  #{name} season_zero: uncovered (no_search)" in lines
    assert "  #{name} anime_episodes: uncovered (no_search)" in lines
    refute report =~ "not drawn"
    refute report =~ "no candidate"
  end

  # --- the Prowlarr queries of a TV search with a TVDB id (#1933) ---

  @office "The.Office.S01.1080p.WEB-DL-OK"

  # A Torrent9-shaped indexer, whose tv-search lists `q`, `season` and `ep` but not `tvdbid`,
  # and Prowlarr as 3.1's `HttpIndexerBase.Fetch(TvSearchCriteria)` treats it: the
  # `{TvdbId:..}` search asks it nothing and writes no history entry, the title search finds
  # the season.
  test "a TV search with a TVDB id covers an indexer whose caps lack tvdbid with one Prowlarr query",
       %{history: history, statuses: statuses} do
    [indexer] =
      Cinder.CardigannFixtures.setup!(
        [{"t9.yml", Cinder.CardigannFixtures.torrent9_like()}],
        [{"t9.yml", Cinder.CardigannFixtures.torrent9_base(), %{}}]
      )

    indexer = link!(indexer, 7)
    series = series_fixture(%{title: "The Office", year: nil, tvdb_id: 73_244})
    season = season_fixture(series, %{season_number: 1})
    episode_fixture(season, %{episode_number: 1})
    episode_fixture(season, %{episode_number: 2})

    Cinder.CardigannFixtures.route(%{
      "t9.test" => fn conn, _query ->
        case conn.request_path do
          "/torrent/" <> _id ->
            Cinder.CardigannFixtures.torrent9_details(link: @magnet)

          _search ->
            Cinder.CardigannFixtures.torrent9_page([
              %{title: @office, href: "/torrent/1", size: "1 GB", icon: "tv", date: "01/01/2025"}
            ])
        end
      end
    })

    id_search? = &String.starts_with?(&1["query"], "{TvdbId:")

    row = %{
      "title" => @office,
      "size" => 1_073_741_824,
      "magnetUrl" => @magnet,
      "protocol" => "torrent",
      "indexerId" => 7,
      "indexer" => "t9",
      "publishDate" => "2026-11-25T10:30:00Z",
      "categories" => [%{"id" => 5000}]
    }

    prowlarr_search(
      history,
      fn params, _ids -> if id_search?.(params), do: [], else: [row] end,
      fn params, _id -> not id_search?.(params) end
    )

    prowlarr_api(history, statuses)

    report =
      run!(
        counts: %{season: 1},
        indexers: [indexer.id],
        fetch_opts: [
          plug: {Req.Test, Cinder.CardigannStub},
          resolver: fn _host -> {:ok, [@public_address]} end
        ]
      )

    assert_received {:result, :ok}
    queries = receive_all(fn {:prowlarr_search, params, [7]} -> params["query"] end)
    assert Enum.sort(queries) == ["The Office {Season:1}", "{TvdbId:73244}{Season:1}"]
    lines = String.split(report, "\n")
    name = "#{indexer.name} (##{indexer.id})"
    assert "  #{name} season: covered" in lines, report
    assert "        history: #{name} 1 queries, 1 results" in lines, report
    assert "  #{name}: matching rows found, link check passed" in lines, report
    refute report =~ "prowlarr_not_asked"
  end

  # --- the seed ---

  test "the same seed draws the same corpus and side order, another seed another order" do
    for n <- 1..6,
        do: movie_fixture(%{imdb_id: "tt000000#{n}", title: "Movie #{n}", year: 2000 + n})

    labels = fn seed ->
      Enum.map(Corpus.draw(seed, %{movie_title: 3}, DateTime.utc_now()), & &1.label)
    end

    assert labels.(5) == labels.(5)
    assert length(labels.(5)) == 3
    assert Enum.any?(1..20, &(labels.(&1) != labels.(5)))
  end

  test "both sides judge with the same opts and the same now:",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    world(%{"nzb.example" => nzb(7, same(@title, @size))}, history)
    prowlarr_api(history, statuses)
    test_pid = self()

    picks = fn kind, target, opts, source ->
      send(test_pid, {:side_opts, opts})
      Picks.run(kind, target, opts, source)
    end

    run!(counts: %{movie_imdb: 1}, indexers: [indexer.id], picks: picks)

    assert_received {:result, :ok}
    assert_received {:side_opts, first}
    assert_received {:side_opts, second}
    refute_received {:side_opts, _third}
    assert first == second
    assert %DateTime{} = first[:now]
  end

  test "the seed picks the side that goes first, then the sides alternate",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    movie_fixture(%{imdb_id: "tt0816692", title: "Interstellar", year: 2014})
    world(%{"nzb.example" => nzb(7, fn _side, _n -> [] end)}, history)
    prowlarr_api(history, statuses)

    odd = run!(seed: 1, counts: %{movie_imdb: 2}, indexers: [indexer.id])
    even = run!(seed: 2, counts: %{movie_imdb: 2}, indexers: [indexer.id])

    assert odd =~ ~r/#0 .*first: native.*\n(.*\n)*.*#1 .*first: prowlarr/
    assert even =~ ~r/#0 .*first: prowlarr.*\n(.*\n)*.*#1 .*first: native/
  end

  test "counts draws exactly that many searches of each kind, and no other kind" do
    for n <- 1..4,
        do: movie_fixture(%{imdb_id: "tt100000#{n}", title: "Movie #{n}", year: 2000 + n})

    drawn = Corpus.draw(3, %{movie_title: 2, movie_imdb: 1}, DateTime.utc_now())

    assert Enum.frequencies_by(drawn, & &1.kind) == %{movie_title: 2, movie_imdb: 1}
    assert Corpus.planned_counts(200) == Map.new(Corpus.kinds(), &{&1, 1})
    assert Corpus.planned_counts(199) == Map.new(Corpus.kinds(), &{&1, 0})
    assert Corpus.planned_counts(328) == Map.new(Corpus.kinds(), &{&1, 2})
  end

  test "an imported title is drawn before one that is not" do
    imported = movie_fixture(%{title: "Imported", year: 2001, status: :available})
    movie_fixture(%{title: "Wanted", year: 2002})

    for seed <- 1..10 do
      assert [%{label: label}] = Corpus.draw(seed, %{movie_title: 1}, DateTime.utc_now())
      assert label =~ "movie ##{imported.id} Imported"
    end
  end

  # #1971: Torrent9 answers a season of a series that airs now (#1944's probe). The bound is the
  # household date of the run's `now`, 30 days back included; an episode dated after it has not
  # aired. A `now` years ahead of the clock shows that the draw reads every date at the run's
  # `now`: read at today's date, "Airing Show"'s one episode has not aired.
  test "a season with an episode aired in the 30 days before the run is drawn before an imported one" do
    now = ~U[2031-03-15 12:00:00Z]
    today = Cinder.Settings.household_date(now)

    imported = series_fixture(%{title: "Imported Show", tvdb_id: 1})
    episode_fixture(season_fixture(imported), %{file_path: "/tv/imported/s01e01.mkv"})

    airing = fn title, tvdb_id, dates ->
      season = season_fixture(series_fixture(%{title: title, tvdb_id: tvdb_id}))

      for {date, n} <- Enum.with_index(dates, 1),
          do: episode_fixture(season, %{episode_number: n, air_date: date})
    end

    airing.("Airing Show", 2, [Date.add(today, -30)])
    airing.("Airing Today", 5, [today])
    airing.("Ended Show", 3, [~D[2001-01-01], Date.add(today, -31)])
    airing.("Coming Show", 4, [~D[2001-01-01], Date.add(today, 1)])

    labels = fn seed -> Enum.map(Corpus.draw(seed, %{season: 5}, now), & &1.label) end

    firsts =
      for seed <- 1..20 do
        assert [first, second, third | _] = labels.(seed)
        assert Enum.sort([first =~ "Airing Show", second =~ "Airing Show"]) == [false, true]
        assert first =~ "Airing" and second =~ "Airing"
        assert third =~ "Imported Show"
        first
      end

    # The seed shuffles the seasons that air now, as it does the other groups.
    assert length(Enum.uniq(firsts)) == 2
  end

  test "a run searches the anime episodes, then the seasons, then the movies" do
    inception()
    episode_fixture(season_fixture(series_fixture(%{title: "Some Show"})))

    anime =
      series_fixture(%{
        title: "Some Anime",
        tvdb_id: 9,
        media_profile: :anime,
        preferred_language: "original",
        original_language: "ja"
      })

    episode_fixture(season_fixture(anime))

    counts = %{anime_episodes: 1, season: 1, movie_title: 1, movie_imdb: 1}

    assert Enum.map(Corpus.draw(1, counts, DateTime.utc_now()), & &1.kind) ==
             [:anime_episodes, :season, :movie_title, :movie_imdb]
  end

  test "an anime series whose policy does not resolve takes no draw" do
    broken =
      series_fixture(%{
        title: "Broken Anime",
        media_profile: :anime,
        preferred_language: "dual",
        original_language: nil
      })

    episode_fixture(season_fixture(broken, %{season_number: 1}), %{
      episode_number: 1,
      file_path: "/tv/broken/s01e01.mkv"
    })

    good =
      series_fixture(%{
        title: "Good Anime",
        media_profile: :anime,
        preferred_language: "original",
        original_language: "ja"
      })

    episode_fixture(season_fixture(good, %{season_number: 1}), %{
      episode_number: 1,
      file_path: "/tv/good/s01e01.mkv"
    })

    for seed <- 1..10 do
      assert [%{label: label}] = Corpus.draw(seed, %{anime_episodes: 1}, DateTime.utc_now())
      assert label =~ "Good Anime"
    end
  end

  # --- the budget, the limits and the deadline ---

  test "a spent budget stops the indexer: Prowlarr asks it no more and later searches read inconclusive",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    movie_fixture(%{imdb_id: "tt0816692", title: "Interstellar", year: 2014})
    world(%{"nzb.example" => nzb(7, fn _side, _n -> [] end)}, history)
    prowlarr_api(history, statuses)

    report = run!(budget: 2, counts: %{movie_imdb: 2}, indexers: [indexer.id])

    assert_received {:result, :ok}
    assert report =~ "inconclusive budget"
    assert report =~ "Requests spent: newznab nzb.example (##{indexer.id}) 2"
    assert_link_line(report, indexer, "not_run (stopped budget)")
    # Native goes first (seed 1) and spends both requests: the caps fetch and its search. So
    # Prowlarr's request would carry no id, and none is sent.
    assert search_count("nzb.example") == 1
    assert prowlarr_ids() == []
  end

  test "by default a run plans for 200 requests per indexer, a 2700 s deadline, a 660 s retry spacing, a 10000 ms indexer spacing and a 5000 ms history wait",
       %{history: history, statuses: statuses} do
    :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    world(%{"nzb.example" => nzb(7, same(@title, @size))}, history)
    prowlarr_api(history, statuses)

    # The header's last line raises, so the run stops before its first search and waits for
    # none of these limits.
    print = fn line ->
      IO.puts(line)
      if line =~ "Planned searches", do: raise("stop")
    end

    report =
      capture_io(fn -> send(self(), {:result, ParityRun.run(seed: 1, print: print)}) end)

    assert_received {:result, {:error, :raised}}

    assert report =~
             "Limits: 200 requests per indexer, deadline 2700 s, retry spacing 660 s, " <>
               "indexer spacing 10000 ms, history wait 5000 ms\n"

    assert report =~
             "Planned searches: movie_imdb 1, movie_title 1, season 1, season_zero 1, " <>
               "anime_episodes 1, ebook 1, audiobook 1;"
  end

  # The Newznab link check reserves one request plus at most five redirects before it fetches.
  test "a Newznab link check spends six requests of a full allowance",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    world(%{"nzb.example" => nzb(7, same(@title, @size))}, history)
    prowlarr_api(history, statuses)

    report = run!(counts: %{movie_imdb: 1}, indexers: [indexer.id])

    assert_received {:result, :ok}
    # The caps fetch, Native's search, Prowlarr's search for the indexer, then 1 + 5.
    assert report =~ "Requests spent: newznab nzb.example (##{indexer.id}) 9\n"
  end

  # Budget 3 on a Cardigann indexer: the first try spends 2 (Native's page, Prowlarr's search),
  # the link check's detail page the third, and its torrent request is refused, between the
  # tries. Prowlarr answers another row, so the search is tried again.
  test "a budget refused between two tries stops the indexer in the second, and the link check reads budget",
       %{history: history, statuses: statuses} do
    # A download block that follows the details page's torrent link: two requests per grab.
    definition =
      put_in(Cinder.CardigannFixtures.torrent9_like(), ["download", "selectors"], [
        %{"selector" => "a.dl", "attribute" => "href"}
      ])

    [indexer] =
      Cinder.CardigannFixtures.setup!(
        [{"t9.yml", definition}],
        [{"t9.yml", Cinder.CardigannFixtures.torrent9_base(), %{}}]
      )

    indexer = link!(indexer, 7)
    inception()

    Cinder.CardigannFixtures.route(%{
      "t9.test" => fn conn, _query ->
        case conn.request_path do
          "/torrent/" <> _id ->
            Cinder.CardigannFixtures.torrent9_details(link: "/get_torrent/1.torrent")

          "/get_torrent/" <> _id ->
            Cinder.TorrentFixture.minimal()

          _search ->
            Cinder.CardigannFixtures.torrent9_page([
              %{
                title: @title,
                href: "/torrent/1",
                size: "9 GB",
                icon: "film",
                date: "01/01/2025"
              }
            ])
        end
      end
    })

    other = %{
      "title" => "Inception.2010.720p.WEB-DL-OTHER",
      "size" => 4_000_000_000,
      "downloadUrl" => "http://prowlarr:9696/7/download?link=1&apikey=#{@key}",
      "protocol" => "torrent",
      "indexerId" => 7,
      "indexer" => "t9",
      "publishDate" => "2026-11-25T10:30:00Z",
      "categories" => [%{"id" => 2040}]
    }

    prowlarr_search(history, fn _params, ids -> if ids == [7], do: [other], else: [] end)
    prowlarr_api(history, statuses)

    report =
      run!(
        budget: 3,
        counts: %{movie_title: 1},
        indexers: [indexer.id],
        fetch_opts: [
          plug: {Req.Test, Cinder.CardigannStub},
          resolver: fn _host -> {:ok, [@public_address]} end
        ]
      )

    assert_received {:result, :ok}
    assert report =~ "try 2"
    assert report =~ "inconclusive budget"
    assert report =~ "link check failed budget"
    refute report =~ "Verdict: fail"
    refute report =~ @key
  end

  # A plain 429 is a limit (`{:limit, wait}`); Prowlarr's "Indexer is disabled till" 429, from an
  # indexer that points at a Prowlarr, reads `{:http_status, 429}` (`NewznabAnswer` rules 2, 3).
  for {name, body} <- [
        {"a limit", "Too Many Requests for apikey=#{@key}"},
        {"a disabled-till answer",
         ~s(<?xml version="1.0"?><error code="429" description="Indexer is disabled till 2026-11-27 10:00 apikey=#{@key}"/>)}
      ] do
    test "an HTTP 429 from Native, #{name}, stops the indexer for the rest of the run",
         %{history: history, statuses: statuses} do
      indexer = :newznab |> indexer!("nzb.example") |> link!(7)
      inception()
      movie_fixture(%{imdb_id: "tt0816692", title: "Interstellar", year: 2014})

      route(%{
        "nzb.example" => fn _conn, query ->
          if query["t"] == "caps", do: @caps, else: {429, unquote(body)}
        end
      })

      prowlarr_search(history, fn _params, _ids -> [] end)
      prowlarr_api(history, statuses)

      report = run!(counts: %{movie_imdb: 2}, indexers: [indexer.id])

      assert_received {:result, :ok}
      assert report =~ "inconclusive rate_limited"
      assert_link_line(report, indexer, "not_run (stopped rate_limited)")
      assert length(prowlarr_ids()) == 1
      refute report =~ @key
    end
  end

  test "a Prowlarr backoff that a failure during the search set stops the indexer",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    movie_fixture(%{imdb_id: "tt0816692", title: "Interstellar", year: 2014})
    world(%{"nzb.example" => nzb(7, fn _side, _n -> [] end)}, history)

    prowlarr_search(history, fn _params, _ids ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Agent.update(statuses, fn _ ->
        [
          %{
            "indexerId" => 7,
            "disabledTill" => DateTime.to_iso8601(DateTime.add(now, 600)),
            "mostRecentFailure" => DateTime.to_iso8601(now)
          }
        ]
      end)

      []
    end)

    prowlarr_api(history, statuses)

    report = run!(counts: %{movie_imdb: 2}, indexers: [indexer.id])

    assert_received {:result, :ok}
    assert report =~ "inconclusive rate_limited"
    assert length(prowlarr_ids()) == 1
  end

  defp failure_fields(:hour_ago, now),
    do: %{"mostRecentFailure" => DateTime.to_iso8601(DateTime.add(now, -3600))}

  defp failure_fields(:none, _now), do: %{}

  # The engine reads a backoff that holds during a window as uncovered (`:prowlarr_backoff`); the
  # run stops an indexer only for one a failure during its search set.
  for {name, failure} <- [{"set before the run", :hour_ago}, {"with no failure date", :none}] do
    test "a Prowlarr backoff #{name} does not stop the indexer",
         %{history: history, statuses: statuses} do
      indexer = :newznab |> indexer!("nzb.example") |> link!(7)
      inception()
      movie_fixture(%{imdb_id: "tt0816692", title: "Interstellar", year: 2014})
      world(%{"nzb.example" => nzb(7, same(@title, @size))}, history)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      failure = failure_fields(unquote(failure), now)

      Agent.update(statuses, fn _ ->
        [
          Map.merge(
            %{"indexerId" => 7, "disabledTill" => DateTime.to_iso8601(DateTime.add(now, 600))},
            failure
          )
        ]
      end)

      prowlarr_api(history, statuses)

      report = run!(counts: %{movie_imdb: 2}, indexers: [indexer.id])

      assert_received {:result, :ok}
      assert report =~ "uncovered prowlarr_backoff"
      refute report =~ "rate_limited"
      assert length(prowlarr_ids()) == 2
    end
  end

  test "a run past its deadline sends no search and reads inconclusive",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    world(%{"nzb.example" => nzb(7, same(@title, @size))}, history)
    prowlarr_api(history, statuses)

    report = run!(deadline_s: 0, counts: %{movie_imdb: 1}, indexers: [indexer.id])

    assert_received {:result, :ok}
    refute report =~ "Verdict: pass"
    assert_link_line(report, indexer, "not_run (deadline passed)")
    assert search_count("nzb.example") == 0
    assert prowlarr_ids() == []
  end

  # #1954: Native goes first (seed 1), and its caps fetch and search spend the allowance of 2, so
  # Prowlarr's request is refused and the try stops the indexer. The second side then waits
  # 2.1 s, past the 2 s deadline; the 2 s are headroom for the run to reach its first try.
  test "an indexer the run stopped reads its stop, also once the deadline has passed",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    world(%{"nzb.example" => nzb(7, fn _side, _n -> [] end)}, history)
    prowlarr_api(history, statuses)
    calls = start_supervised!({Agent, fn -> 0 end}, id: :calls)

    slow = fn kind, target, opts, source ->
      pick = Picks.run(kind, target, opts, source)
      if Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) == 2, do: Process.sleep(2_100)
      pick
    end

    report =
      run!(
        budget: 2,
        deadline_s: 2,
        picks: slow,
        counts: %{movie_imdb: 1},
        indexers: [indexer.id]
      )

    assert_received {:result, :ok}
    assert_link_line(report, indexer, "not_run (stopped budget)")
    assert search_count("nzb.example") == 1
    assert prowlarr_ids() == []
  end

  # --- the retry ---

  test "a search whose first try differs is tried once more", %{
    history: history,
    statuses: statuses
  } do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()

    rows = fn
      :prowlarr, 1 -> [{"Inception.2010.720p.WEB-DL-OTHER", 4_000_000_000}]
      _side, _n -> [{@title, @size}]
    end

    world(%{"nzb.example" => nzb(7, rows)}, history)
    prowlarr_api(history, statuses)

    {elapsed_us, report} =
      :timer.tc(fn ->
        run!(retry_spacing_s: 1, counts: %{movie_imdb: 1}, indexers: [indexer.id])
      end)

    assert_received {:result, :ok}
    # The difference is listed under the first try only, and the second decides.
    assert report =~ ~r/try 1: .*\n(.*\n)*?\s+difference: /
    assert report =~ "try 2: ok"
    refute report =~ "confirmed difference"
    assert length(prowlarr_ids()) == 2
    # The retry starts a spacing of 1 s after the first try ended.
    assert elapsed_us >= 1_000_000
  end

  test "a retry spacing past the deadline waits for the deadline only, and runs no retry",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()

    rows = fn
      :prowlarr, 1 -> [{"Inception.2010.720p.WEB-DL-OTHER", 4_000_000_000}]
      _side, _n -> [{@title, @size}]
    end

    world(%{"nzb.example" => nzb(7, rows)}, history)
    prowlarr_api(history, statuses)

    {elapsed_us, report} =
      :timer.tc(fn ->
        run!(
          deadline_s: 1,
          retry_spacing_s: 3_600,
          counts: %{movie_imdb: 1},
          indexers: [indexer.id]
        )
      end)

    assert_received {:result, :ok}
    refute report =~ "try 2"
    assert length(prowlarr_ids()) == 1
    assert elapsed_us < 30_000_000
  end

  # --- the set ---

  test "an indexer with no Prowlarr link is reported, and Prowlarr is asked nothing for it",
       %{history: history, statuses: statuses} do
    indexer = indexer!(:newznab, "nzb.example")
    inception()
    world(%{"nzb.example" => nzb(7, same(@title, @size))}, history)
    prowlarr_api(history, statuses)

    report = run!(counts: %{movie_imdb: 1}, indexers: [indexer.name])

    assert_received {:result, :ok}
    assert report =~ "no_prowlarr_indexer"
    assert prowlarr_ids() == []
  end

  test "the default set leaves out an unlinked, a disabled and a not-supported indexer",
       %{history: history, statuses: statuses} do
    kept = :newznab |> indexer!("nzb.example") |> link!(7)
    indexer!(:newznab, "unlinked.example")
    :newznab |> indexer!("off.example", %{enabled: false}) |> link!(8)
    :newznab |> indexer!("fs.example", %{flaresolverr: true}) |> link!(9)
    inception()
    world(%{"nzb.example" => nzb(7, same(@title, @size))}, history)
    prowlarr_api(history, statuses)

    report = run!(counts: %{movie_imdb: 1})

    assert_received {:result, :ok}
    assert report =~ "Indexers: newznab nzb.example (##{kept.id})\n"
    assert prowlarr_ids() == [[7]]
  end

  test "a named set limits both sides to it", %{history: history, statuses: statuses} do
    a = :newznab |> indexer!("a.example") |> link!(7)
    :newznab |> indexer!("b.example") |> link!(8)
    inception()

    world(
      %{"a.example" => nzb(7, same(@title, @size)), "b.example" => nzb(8, same(@title, @size))},
      history
    )

    prowlarr_api(history, statuses)

    report = run!(counts: %{movie_imdb: 1}, indexers: [a.name])

    assert_received {:result, :ok}
    assert report =~ "Indexers: newznab a.example (##{a.id})\n"
    assert prowlarr_ids() == [[7]]
    assert search_count("b.example") == 0
  end

  test "a name that matches no configured indexer refuses the run" do
    report = run!(indexers: ["nope"])

    assert_received {:result, {:error, :unknown_indexer}}
    assert report == "Parity run failed: unknown_indexer\n"
  end

  # --- the guards ---

  test "an inspect that shows a release's link refuses the run before any request" do
    report = run!(release_structs: [LeakyRelease])

    assert_received {:result, {:error, :inspect_shows_download_url}}
    assert report == "Parity run failed: inspect_shows_download_url\n"
    refute_received :prowlarr_status
  end

  test "a second run while one holds the node is refused" do
    test_pid = self()

    holder =
      start_supervised!(
        {Task,
         fn ->
           Process.register(self(), ParityRun)
           send(test_pid, :held)
           receive do: (:done -> :ok)
         end},
        id: make_ref()
      )

    assert_receive :held
    report = run!([])
    send(holder, :done)

    assert_received {:result, {:error, :already_running}}
    assert report == "Parity run failed: already_running\n"
  end

  test "a raise prints the exception's module and no link or key",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    world(%{"nzb.example" => nzb(7, same(@title, @size))}, history)
    prowlarr_api(history, statuses)

    # The first print, the header's, raises with a link and a key in its message: the run's own
    # process raising, as no HTTP stub can (each request runs in a task of its own).
    raised = start_supervised!({Agent, fn -> false end}, id: :raised)

    print = fn line ->
      if Agent.get_and_update(raised, &{&1, true}),
        do: IO.puts(line),
        else: raise("boom https://nzb.example/?apikey=#{@key}")
    end

    report = run!(counts: %{movie_imdb: 1}, indexers: [indexer.id], print: print)

    assert_received {:result, {:error, :raised}}
    assert report =~ "Parity run failed: raised RuntimeError\n"
    refute report =~ @key
    refute report =~ key()
  end

  test "Prowlarr with no URL or key refuses the run" do
    Cinder.ConfigCase.put_config(Prowlarr, api_key: nil)

    report = run!([])

    assert_received {:result, {:error, :prowlarr_not_configured}}
    assert report == "Parity run failed: prowlarr_not_configured\n"
  end

  test "a run leaves the app env as it found it", %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    world(%{"nzb.example" => nzb(7, same(@title, @size))}, history)
    prowlarr_api(history, statuses)
    before = Application.get_all_env(:cinder)

    run!(counts: %{movie_imdb: 1}, indexers: [indexer.id])

    assert_received {:result, :ok}
    assert Application.get_all_env(:cinder) == before
  end

  # --- the seams ---

  # --- a link check over hand-built first tries ---

  @unrelated "Unrelated.Film.2001.1080p.WEB-DL-GRP"

  # A first try of a movie-by-title search for Inception (2010) whose one Native call answers
  # `rows`, which the indexer's report reads as asked.
  defp link_search(indexer, rows) do
    report = Report.put(Report.new(), {"native", indexer.id}, indexer.name, :asked)

    %{
      kind: :movie_title,
      target: %{
        context: %{
          imdb_id: nil,
          title: "Inception",
          year: 2010,
          aliases: [],
          localized_titles: []
        }
      },
      opts: [now: ~U[2026-11-25 10:00:00Z]],
      tries: [
        %{
          native: %{
            calls: [
              %{
                callback: :search_movie_query,
                args: ["Inception 2010", []],
                outcome: {:ok, rows, report}
              }
            ]
          }
        }
      ]
    }
  end

  # A free-text Native torrent row of `indexer` (Torznab's `search_movie_query` asks free text).
  defp link_row(indexer, url, title) do
    %{
      title: title,
      size: @size,
      download_url: url,
      protocol: :torrent,
      seeders: 50,
      indexer_id: indexer.id,
      indexer_name: indexer.name,
      indexer_source: "native",
      credentials_version: indexer.credentials_version,
      published_at: ~U[2026-11-01 10:00:00Z],
      category_ids: [2040],
      query_origins: [:free_text]
    }
  end

  # Answers each link fetch to `hosts` with `body` and reports `{:fetched, host, path}`; returns
  # the fetch opts that reach the stub.
  defp fetched_route(hosts, body \\ Cinder.TorrentFixture.minimal()) do
    test_pid = self()

    answer = fn conn, _query ->
      send(test_pid, {:fetched, conn.host, conn.request_path})
      body
    end

    route(Map.new(hosts, &{&1, answer}))
    [plug: {Req.Test, Cinder.NewznabStub}, resolver: fn _host -> {:ok, [@public_address]} end]
  end

  # --- the spacing (#1969) ---

  defp mono, do: System.monotonic_time(:millisecond)

  # Marks each side's start, which comes after its spacing wait, in the stubs' timeline.
  defp timed_picks do
    test_pid = self()

    fn kind, target, opts, source ->
      send(test_pid, {:timed, :side, nil, mono()})
      Picks.run(kind, target, opts, source)
    end
  end

  defp timed(acc \\ []) do
    receive do
      {:timed, kind, host, at} -> timed([{kind, host, at} | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.sort_by(fn {kind, _host, at} -> {at, kind != :side} end)
    end
  end

  # Each side's start, in order.
  defp side_marks(events), do: for({:side, _host, at} <- events, do: at)

  # Per host, each gap in ms from one side's last request to the next side's first one, over the
  # sides that sent the host a request, and the link check's fetches apart. A request belongs to
  # the last side marked before it; the stubs time each request as it arrives.
  defp side_gaps(events) do
    {_side, by_host} =
      Enum.reduce(events, {0, %{}}, fn
        {:side, _host, _at}, {side, acc} ->
          {side + 1, acc}

        {:request, host, at}, {side, acc} ->
          {side, Map.update(acc, host, [{side, at}], &[{side, at} | &1])}

        {:link, _host, _at}, acc ->
          acc
      end)

    Map.new(by_host, fn {host, requests} ->
      gaps =
        for [{side, at}, {next_side, next_at}] <-
              requests |> Enum.reverse() |> Enum.chunk_every(2, 1, :discard),
            side != next_side,
            do: next_at - at

      {host, gaps}
    end)
  end

  defp attach_paced do
    test_pid = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:cinder, :parity_run, :paced],
      fn _event, _measurements, metadata, _config ->
        send(
          test_pid,
          {:paced, metadata.kind, metadata.side, metadata.indexers, metadata.waiting}
        )
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp paced(acc \\ []) do
    receive do
      {:paced, kind, side, indexers, waiting} -> paced([{kind, side, indexers, waiting} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp anime!(title, tvdb_id) do
    series =
      series_fixture(%{
        title: title,
        tvdb_id: tvdb_id,
        media_profile: :anime,
        preferred_language: "original",
        original_language: "ja"
      })

    episode_fixture(season_fixture(series))
  end

  # #1969's done-when: run 3's counts on two indexers that every kind reaches. Every side sends
  # both a request, so each boundary between two sides, within a search and between searches, is
  # one gap per indexer.
  test "a run of run 3's counts keeps a spacing on each indexer between every two sides",
       %{history: history, statuses: statuses} do
    for n <- 1..10,
        do: movie_fixture(%{imdb_id: "tt200000#{n}", title: "Movie #{n}", year: 2000 + n})

    for n <- 1..5,
        do:
          episode_fixture(season_fixture(series_fixture(%{title: "Show #{n}", tvdb_id: 100 + n})))

    zero = series_fixture(%{title: "Specials Show", tvdb_id: 200})
    episode_fixture(season_fixture(zero, %{season_number: 0}))
    anime!("Anime One", 301)
    anime!("Anime Two", 302)
    Cinder.BooksFixtures.monitored_book_target(:ebook)
    Cinder.BooksFixtures.monitored_book_target(:audiobook)

    a = :newznab |> indexer!("nzb.example") |> link!(7)
    b = :newznab |> indexer!("nzb2.example") |> link!(8)
    empty = fn _side, _n -> [] end

    world(
      %{
        "nzb.example" => Map.put(nzb(7, empty), :caps, :default),
        "nzb2.example" => Map.put(nzb(8, empty), :caps, :default)
      },
      history
    )

    prowlarr_api(history, statuses)

    counts = %{
      anime_episodes: 2,
      movie_title: 10,
      season: 5,
      movie_imdb: 1,
      season_zero: 1,
      ebook: 1,
      audiobook: 1
    }

    report =
      run!(counts: counts, indexers: [a.id, b.id], indexer_spacing_ms: 50, picks: timed_picks())

    assert_received {:result, :ok}
    assert report =~ "drawn: 21", report
    gaps = side_gaps(timed())

    for host <- ["nzb.example", "nzb2.example"] do
      host_gaps = Map.fetch!(gaps, host)
      # 21 searches of two sides each: 41 boundaries, retries aside.
      assert length(host_gaps) >= 41, inspect({host, host_gaps})
      assert Enum.all?(host_gaps, &(&1 >= 50)), inspect({host, host_gaps})
    end
  end

  test "a search its kind cannot reach an indexer by is not held back by that indexer's spacing",
       %{history: history, statuses: statuses} do
    attach_paced()
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    Cinder.BooksFixtures.monitored_book_target(:ebook)
    world(%{"nzb.example" => nzb(7, same(@title, @size))}, history)
    prowlarr_api(history, statuses)

    # The deadline leaves the book search 4 s to start after the movie search's 6 s wait, and
    # step 5 waits out the movie search's spacing only to the deadline.
    run!(
      counts: %{movie_imdb: 1, ebook: 1},
      indexers: [indexer.id],
      indexer_spacing_ms: 6_000,
      deadline_s: 10,
      picks: timed_picks()
    )

    assert_received {:result, :ok}
    id = indexer.id
    events = timed()

    # Seed 1: Native goes first in the movie search, and its caps fetch stores the row that the
    # later plans read. The caps take movies alone, so the book search's sides wait for nothing.
    assert [
             {:movie_imdb, :native, [^id], []},
             {:movie_imdb, :prowlarr, [^id], _movie_waiting},
             {:ebook, :prowlarr, [], []},
             {:ebook, :native, [], []}
           ] = paced()

    # The movie search's Prowlarr side came a spacing after its Native side. The book search's
    # first side started well within a spacing of it: no sleep waited for the movie's spacing.
    assert %{"nzb.example" => [movie_gap | _rest]} = side_gaps(events)
    assert movie_gap >= 6_000
    assert [_movie_native, movie_prowlarr, book_first, _book_second] = side_marks(events)
    assert book_first - movie_prowlarr < 3_000
    # The movie search's request alone: step 5 reached the deadline, so no link check ran.
    assert ["movie"] = Enum.map(searches("nzb.example"), & &1["t"])
  end

  # The caps take audiobooks (3030) and no e-book: Prowlarr's e-book request still names the
  # indexer and charges it, but Prowlarr would not ask it, so the audiobook search after it waits
  # for no spacing of that request.
  test "a side that names an indexer it cannot reach starts no spacing for it",
       %{history: history, statuses: statuses} do
    attach_paced()
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    Cinder.BooksFixtures.monitored_book_target(:ebook)
    Cinder.BooksFixtures.monitored_book_target(:audiobook)

    audio_caps =
      caps(modes: %{"search" => ~s(available="yes" supportedParams="q")}, categories: [3030])

    world(%{"nzb.example" => Map.put(nzb(7, fn _side, _n -> [] end), :caps, audio_caps)}, history)
    prowlarr_api(history, statuses)
    context = %{deadline_at: System.monotonic_time(:millisecond) + 5_000}
    refute match?({:failed, _tag}, Indexer.Newznab.plan(indexer, {:search, "tt1"}, context))

    run!(
      counts: %{ebook: 1, audiobook: 1},
      indexers: [indexer.id],
      indexer_spacing_ms: 2_000,
      picks: timed_picks()
    )

    assert_received {:result, :ok}
    id = indexer.id
    events = timed()

    assert [
             {:ebook, :native, [], []},
             {:ebook, :prowlarr, [], []},
             {:audiobook, :prowlarr, [^id], []},
             {:audiobook, :native, [^id], _native_waiting}
           ] = paced()

    # The e-book request charged the indexer but did not reach it, so it started no spacing and
    # the audiobook search's Prowlarr side found none running. That side sent the indexer a
    # request, so the audiobook search's Native side came a spacing later.
    assert %{"nzb.example" => gaps} = side_gaps(events)
    assert List.last(gaps) >= 2_000
    # Each book search's Prowlarr side names the indexer, the e-book one's too.
    assert [[7] | _rest] = ids = prowlarr_ids()
    assert length(ids) >= 2 and Enum.all?(ids, &(&1 == [7]))
  end

  test "Native's side counts an indexer with no stored caps as reached by an e-book search",
       %{history: history, statuses: statuses} do
    attach_paced()
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    Cinder.BooksFixtures.monitored_book_target(:ebook)
    world(%{"nzb.example" => nzb(7, fn _side, _n -> [] end)}, history)
    prowlarr_api(history, statuses)

    run!(counts: %{ebook: 1}, indexers: [indexer.id], indexer_spacing_ms: 1_000)

    assert_received {:result, :ok}
    id = indexer.id
    # Native goes first with no caps row; its fetch stores one that tells Prowlarr's side the
    # movie-only caps take no book, so that side waits for nothing.
    assert [{:ebook, :native, [^id], []}, {:ebook, :prowlarr, [], []}] = paced()
  end

  # Prowlarr's first answer differs, so the search is tried again after the link check: the
  # fetch waits for the first try's spacing, and the retry for the fetch's.
  test "the link check waits for the spacing after the last side, and a retry for the link check's",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()

    rows = fn
      :prowlarr, 1 -> [{"Inception.2010.720p.WEB-DL-OTHER", 4_000_000_000}]
      _side, _n -> [{@title, @size}]
    end

    world(%{"nzb.example" => nzb(7, rows)}, history)
    prowlarr_api(history, statuses)

    report = run!(counts: %{movie_imdb: 1}, indexers: [indexer.id], indexer_spacing_ms: 2_000)

    assert_received {:result, :ok}
    assert report =~ "link check passed", report
    assert report =~ "try 2: ok", report

    {before, [{:link, "nzb.example", link_at} | retry]} =
      Enum.split_while(timed(), &(elem(&1, 0) != :link))

    assert {:request, "nzb.example", last_at} = List.last(before)
    assert link_at - last_at >= 2_000
    assert [{:request, "nzb.example", retry_at} | _rest] = retry
    assert retry_at - link_at >= 2_000
  end

  # Deadline 3 s, spacing 2 s: the first search's second side starts about 2 s in, before the
  # deadline. The next search starts before the deadline too, but its first side would wait until
  # about 4 s, so it has no try.
  test "a try whose first side's wait would end past the deadline has no try",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    movie_fixture(%{imdb_id: "tt0816692", title: "Interstellar", year: 2014})
    world(%{"nzb.example" => nzb(7, fn _side, _n -> [] end)}, history)
    prowlarr_api(history, statuses)

    run!(
      counts: %{movie_imdb: 2},
      indexers: [indexer.id],
      deadline_s: 3,
      indexer_spacing_ms: 2_000,
      picks: timed_picks()
    )

    assert_received {:result, :ok}
    events = timed()
    assert [_one, _two] = Enum.filter(events, &match?({:side, _, _}, &1))
    assert %{"nzb.example" => [gap]} = side_gaps(events)
    assert gap >= 2_000
    assert length(prowlarr_ids()) == 1
  end

  # Deadline 2 s, spacing 3 s: the second side's wait ends about 1 s past the deadline.
  test "a started try's second side waits its whole spacing, past the deadline too",
       %{history: history, statuses: statuses} do
    indexer = :newznab |> indexer!("nzb.example") |> link!(7)
    inception()
    world(%{"nzb.example" => nzb(7, fn _side, _n -> [] end)}, history)
    prowlarr_api(history, statuses)

    run!(
      counts: %{movie_imdb: 1},
      indexers: [indexer.id],
      deadline_s: 2,
      indexer_spacing_ms: 3_000,
      picks: timed_picks()
    )

    assert_received {:result, :ok}
    events = timed()
    assert [_one, _two] = Enum.filter(events, &match?({:side, _, _}, &1))
    assert %{"nzb.example" => [gap]} = side_gaps(events)
    assert gap >= 3_000
  end

  test "Prowlarr's side waits for no indexer it has no link for",
       %{history: history, statuses: statuses} do
    attach_paced()
    linked = :newznab |> indexer!("nzb.example") |> link!(7)
    unlinked = indexer!(:newznab, "nzb2.example")
    inception()

    world(
      %{
        "nzb.example" => nzb(7, same(@title, @size)),
        "nzb2.example" => nzb(8, same(@title, @size))
      },
      history
    )

    prowlarr_api(history, statuses)

    run!(counts: %{movie_imdb: 1}, indexers: [linked.id, unlinked.id])

    assert_received {:result, :ok}
    both = Enum.sort([linked.id, unlinked.id])
    linked_id = linked.id

    assert [{:movie_imdb, :native, native, []}, {:movie_imdb, :prowlarr, [^linked_id], []}] =
             paced()

    assert Enum.sort(native) == both
  end

  describe "the seams" do
    test "Indexer.request charges the context's budget per send and sends nothing it refuses" do
      route(%{"nzb.example" => fn _conn, _query -> rss() end})

      options = [
        url: "https://nzb.example/api?t=search&q=x",
        plug: {Req.Test, Cinder.NewznabStub}
      ]

      budget = Budget.new([1], 1)
      deadline_at = System.monotonic_time(:millisecond) + 5_000
      context = %{deadline_at: deadline_at, budget: fn -> Budget.take(budget, 1) end}

      assert {:ok, %Req.Response{status: 200}} = Indexer.request(context, options)
      assert Indexer.request(context, options) == {:error, :deadline}
      assert length(searches("nzb.example")) == 1
      assert Budget.refused(budget) == [1]
    end

    test "Native.search_run asks only the named indexers and spends the budget per request" do
      a = indexer!(:newznab, "a.example")
      b = indexer!(:newznab, "b.example")
      route(%{"a.example" => fn _c, _q -> :default end, "b.example" => fn _c, _q -> :default end})
      # Both have an allowance, so only `only` keeps b out.
      budget = Budget.new([a.id, b.id], 50)

      assert {:ok, [], _report} =
               Native.search_run({:search_movie_query, "x", []}, %{
                 only: [a.id],
                 budget: &Budget.take(budget, &1)
               })

      assert search_count("b.example") == 0
      # The caps fetch and the search.
      assert Budget.spent(budget, a.id) == 2
      assert Budget.spent(budget, b.id) == 0
    end

    test "an indexer's kinds follow its caps, and a caps fetch that fails keeps every kind" do
      movies = indexer!(:newznab, "movies.example")
      broken = indexer!(:newznab, "broken.example")

      route(%{
        "movies.example" => fn _conn, _query -> @caps end,
        "broken.example" => fn _conn, _query -> {500, "oops"} end
      })

      budget = Budget.new([movies.id, broken.id], 10)

      context = fn indexer ->
        %{
          deadline_at: System.monotonic_time(:millisecond) + 5_000,
          budget: fn -> Budget.take(budget, indexer.id) end
        }
      end

      assert IndexerSet.caps(movies, Corpus.kinds(), context.(movies)).kinds == [:movie_imdb]
      assert IndexerSet.caps(broken, Corpus.kinds(), context.(broken)).kinds == Corpus.kinds()
      assert Budget.spent(budget, movies.id) == 1
      assert Budget.spent(budget, broken.id) == 1
    end

    test "a kind's reach plans from the stored caps alone, and an indexer with no row is reached" do
      movies = indexer!(:newznab, "movies.example")
      text = indexer!(:newznab, "text.example")

      text_caps =
        caps(modes: %{"search" => ~s(available="yes" supportedParams="q")}, categories: [2000])

      route(%{
        "movies.example" => fn _conn, _query -> @caps end,
        "text.example" => fn _conn, _query -> text_caps end
      })

      for side <- [:native, :prowlarr],
          do: assert(Enum.all?(Corpus.kinds(), &IndexerSet.reaches?(movies, &1, side)))

      refute_received {:newznab_request, _host, _query}
      assert Repo.all(Native.IndexerCaps) == []

      for indexer <- [movies, text] do
        context = %{deadline_at: System.monotonic_time(:millisecond) + 5_000}

        # A plan that fetches the caps stores their row.
        refute match?(
                 {:failed, _tag},
                 Indexer.Newznab.plan(indexer, {:search, "tt1"}, context)
               )
      end

      reached = fn indexer, side ->
        Enum.filter(Corpus.kinds(), &IndexerSet.reaches?(indexer, &1, side))
      end

      assert reached.(movies, :native) == [:movie_imdb]
      # An indexer whose caps take no `imdbid` gets a movie by id as a text search (`Newznab`'s
      # `search_movie` request), so that kind reaches it too.
      assert reached.(text, :native) == [:movie_imdb, :movie_title]

      # Prowlarr's TV searches and its movie by IMDb id name no categories, so they reach every
      # indexer; its book searches name 7020 or 3030, which these caps do not list.
      for indexer <- [movies, text],
          do:
            assert(
              reached.(indexer, :prowlarr) ==
                [:movie_imdb, :movie_title, :season, :season_zero, :anime_episodes]
            )
    end

    test "a Cardigann indexer's reach reads its running copy's modes and categories, with no request" do
      no_books = fn definition ->
        definition
        |> update_in(["caps", "categorymappings"], fn mappings ->
          Enum.reject(mappings, &(&1["cat"] == "Books"))
        end)
        |> update_in(["caps", "modes"], &Map.delete(&1, "book-search"))
      end

      [t9] =
        Cinder.CardigannFixtures.setup!(
          [{"t9.yml", Cinder.CardigannFixtures.torrent9_like(no_books)}],
          [{"t9.yml", Cinder.CardigannFixtures.torrent9_base(), %{}}]
        )

      for side <- [:native, :prowlarr] do
        assert {side, Enum.filter(Corpus.kinds(), &IndexerSet.reaches?(t9, &1, side))} ==
                 {side, [:movie_imdb, :movie_title, :season, :season_zero, :anime_episodes]}
      end

      refute_received {:cardigann_request, _host, _path, _query, _headers}
    end

    # #1933: Prowlarr sends a TV search with a TVDB id only to an indexer whose caps list it.
    test "an indexer's tvdb_search reads whether its TV search caps list tvdbid, and fetches no caps of its own" do
      tv = fn params ->
        caps(
          modes: %{"tv-search" => ~s(available="yes" supportedParams="#{params}")},
          categories: [5000, 5040]
        )
      end

      with_id = indexer!(:newznab, "with-id.example")
      without_id = indexer!(:newznab, "without-id.example")
      broken = indexer!(:newznab, "broken.example")

      route(%{
        "with-id.example" => fn _conn, _query -> tv.("q,season,ep,tvdbid") end,
        "without-id.example" => fn _conn, _query -> tv.("q,season,ep") end,
        "broken.example" => fn _conn, _query -> {500, "oops"} end
      })

      ids = [with_id.id, without_id.id, broken.id]
      budget = Budget.new(ids, 10)

      context = fn indexer ->
        %{
          deadline_at: System.monotonic_time(:millisecond) + 5_000,
          budget: fn -> Budget.take(budget, indexer.id) end
        }
      end

      caps = fn indexer -> IndexerSet.caps(indexer, Corpus.kinds(), context.(indexer)) end

      assert %{tvdb_search: true, kinds: [:season, :season_zero, :anime_episodes]} =
               caps.(with_id)

      assert %{tvdb_search: false, kinds: [:season, :season_zero, :anime_episodes]} =
               caps.(without_id)

      assert caps.(broken) == %{kinds: Corpus.kinds(), tvdb_search: nil}
      # One caps fetch each answers both.
      for id <- ids, do: assert(Budget.spent(budget, id) == 1)

      # An indexer deleted before its caps fetch: each plan fetches the caps, which no row keeps,
      # and the read of `tvdb_search` fetches nothing more.
      gone = indexer!(:newznab, "gone.example")
      route(%{"gone.example" => fn _conn, _query -> tv.("q,season,ep,tvdbid") end})
      Repo.delete!(gone)

      gone_budget = Budget.new([gone.id], 20)

      gone_context = %{
        deadline_at: System.monotonic_time(:millisecond) + 5_000,
        budget: fn -> Budget.take(gone_budget, gone.id) end
      }

      assert IndexerSet.caps(gone, Corpus.kinds(), gone_context) ==
               %{kinds: [:season, :season_zero, :anime_episodes], tvdb_search: nil}

      # One fetch per plan: the IMDb probe, then movie_title, season, season_zero, the first
      # anime probe (it plans a request) and both probes of each book kind.
      assert Budget.spent(gone_budget, gone.id) == 9

      edited = fn id, modes ->
        Cinder.CardigannFixtures.torrent9_like(fn definition ->
          definition |> Map.put("id", id) |> update_in(["caps", "modes"], modes)
        end)
      end

      with_tvdbid =
        edited.("cindertestt9id", &Map.put(&1, "tv-search", ["q", "season", "ep", "tvdbid"]))

      no_tv = edited.("cindertestt9notv", &Map.delete(&1, "tv-search"))
      base = Cinder.CardigannFixtures.torrent9_base()

      [t9, t9_id, t9_no_tv] =
        Cinder.CardigannFixtures.setup!(
          [
            {"t9.yml", Cinder.CardigannFixtures.torrent9_like()},
            {"t9id.yml", with_tvdbid},
            {"t9notv.yml", no_tv}
          ],
          [{"t9.yml", base, %{}}, {"t9id.yml", base, %{}}, {"t9notv.yml", base, %{}}]
        )

      assert %{tvdb_search: false} = IndexerSet.caps(t9, Corpus.kinds(), %{})
      assert %{tvdb_search: true} = IndexerSet.caps(t9_id, Corpus.kinds(), %{})
      assert %{tvdb_search: false} = IndexerSet.caps(t9_no_tv, Corpus.kinds(), %{})
    end

    test "a Cardigann grab charges the budget per page request and sends nothing it refuses" do
      [indexer] =
        Cinder.CardigannFixtures.setup!(
          [{"t9.yml", Cinder.CardigannFixtures.torrent9_like()}],
          [{"t9.yml", Cinder.CardigannFixtures.torrent9_base(), %{}}]
        )

      Cinder.CardigannFixtures.route(%{
        "t9.test" => fn _conn, _query ->
          Cinder.CardigannFixtures.torrent9_details(link: @magnet)
        end
      })

      budget = Budget.new([indexer.id], 1)

      opts = [
        max_bytes: 1024 * 1024,
        error_tag: :torrent_fetch_status,
        allow_magnet: true,
        indexer_source: "native",
        indexer_id: indexer.id,
        credentials_version: indexer.credentials_version,
        budget: fn -> Budget.take(budget, indexer.id) end
      ]

      assert Native.fetch_download("https://t9.test/torrent/1", nil, opts) == {:magnet, @magnet}
      assert {:error, _reason} = Native.fetch_download("https://t9.test/torrent/1", nil, opts)
      assert Cinder.CardigannFixtures.requests() == [{"t9.test", "/torrent/1", %{}}]
      assert Budget.refused(budget) == [indexer.id]
    end

    test "a Cardigann link check with no allowance left answers budget and sends nothing" do
      [indexer] =
        Cinder.CardigannFixtures.setup!(
          [{"t9.yml", Cinder.CardigannFixtures.torrent9_like()}],
          [{"t9.yml", Cinder.CardigannFixtures.torrent9_base(), %{}}]
        )

      Cinder.CardigannFixtures.route(%{
        "t9.test" => fn _conn, _query ->
          Cinder.CardigannFixtures.torrent9_details(link: @magnet)
        end
      })

      row = %{
        title: @title,
        size: @size,
        download_url: "https://t9.test/torrent/1",
        protocol: :torrent,
        seeders: 50,
        indexer_id: indexer.id,
        indexer_name: indexer.name,
        indexer_source: "native",
        credentials_version: indexer.credentials_version,
        published_at: ~U[2026-11-01 10:00:00Z],
        category_ids: [2040]
      }

      report = Report.put(Report.new(), {"native", indexer.id}, indexer.name, :asked)

      call = %{
        callback: :search_movie_query,
        args: ["Inception 2010", []],
        outcome: {:ok, [row], report}
      }

      search = %{
        kind: :movie_title,
        target: %{
          context: %{
            imdb_id: nil,
            title: "Inception",
            year: 2010,
            aliases: [],
            localized_titles: []
          }
        },
        opts: [now: ~U[2026-11-25 10:00:00Z]],
        tries: [%{native: %{calls: [call]}}]
      }

      spent = Budget.new([indexer.id], 1)
      Budget.take(spent, indexer.id)

      assert LinkCheck.check(indexer, [search], spent) == {:failed, :budget}
      assert Cinder.CardigannFixtures.requests() == []
      # The same row with one request left is fetched, so the refusal above is the budget's.
      assert LinkCheck.check(indexer, [search], Budget.new([indexer.id], 1)) == :passed
      assert Cinder.CardigannFixtures.requests() == [{"t9.test", "/torrent/1", %{}}]
    end

    # #1954 and #1971: search #0 holds only another indexer's row, so it gives no pick; in
    # search #1 the caller picks the indexer's own row, which has no link; in search #2 the title
    # guard drops its own row, which has no link either. No row of the indexer has a link, so the
    # check names each pick and fetches nothing.
    test "a link check with no own row with a link reads not_run with each pick, by the search's index" do
      indexer = indexer!(:torznab, "t.example")
      other = indexer!(:torznab, "other.example")
      fetched = fetched_route(["t.example", "other.example"])

      searches = [
        link_search(indexer, [link_row(other, "https://other.example/dl/0.torrent", @title)]),
        link_search(indexer, [link_row(indexer, nil, @title)]),
        link_search(indexer, [link_row(indexer, nil, @unrelated)])
      ]

      assert LinkCheck.check(indexer, searches, Budget.new([indexer.id], 10), fetched) ==
               {:not_run, {:picks, [{1, :no_link}, {2, :no_match}]}}

      refute_received {:fetched, _host, _path}
    end

    # #1971: the caller picks none of the indexer's rows (#1 no link, #2 and #3 dropped by the
    # title guard), so the check fetches its first own row with a link in search order, #2's,
    # with the same fetch and budget, and says the row was unpicked.
    test "a link check whose caller picks no row with a link fetches the first own row with a link" do
      indexer = indexer!(:torznab, "t.example")
      other = indexer!(:torznab, "other.example")
      fetched = fetched_route(["t.example", "other.example"])

      searches = [
        link_search(indexer, [link_row(other, "https://other.example/dl/0.torrent", @title)]),
        link_search(indexer, [link_row(indexer, nil, @title)]),
        link_search(indexer, [link_row(indexer, "https://t.example/dl/2.torrent", @unrelated)]),
        link_search(indexer, [link_row(indexer, "https://t.example/dl/3.torrent", @unrelated)])
      ]

      assert LinkCheck.check(indexer, searches, Budget.new([indexer.id], 10), fetched) ==
               {:unpicked, :passed}

      assert_received {:fetched, "t.example", "/dl/2.torrent"}
      refute_received {:fetched, _host, _path}

      # The same pass rule: a body that is no torrent fails, still from the unpicked row.
      fetched = fetched_route(["t.example"], "not a torrent")

      assert LinkCheck.check(indexer, searches, Budget.new([indexer.id], 10), fetched) ==
               {:unpicked, {:failed, :bad_download_file}}

      # The same budget: no request left sends nothing.
      spent = Budget.new([indexer.id], 1)
      Budget.take(spent, indexer.id)

      assert LinkCheck.check(indexer, searches, spent, fetched) ==
               {:unpicked, {:failed, :budget}}

      assert_received {:fetched, "t.example", "/dl/2.torrent"}
      refute_received {:fetched, _host, _path}
    end

    # #1971: search #0 holds an own row with a link that the caller drops, search #1 the row it
    # picks. A pick wins over an earlier unpicked row.
    test "a link check fetches the caller's pick over an earlier unpicked row with a link" do
      indexer = indexer!(:torznab, "t.example")
      fetched = fetched_route(["t.example"])

      searches = [
        link_search(indexer, [link_row(indexer, "https://t.example/dl/0.torrent", @unrelated)]),
        link_search(indexer, [link_row(indexer, "https://t.example/dl/1.torrent", @title)])
      ]

      assert LinkCheck.check(indexer, searches, Budget.new([indexer.id], 10), fetched) == :passed
      assert_received {:fetched, "t.example", "/dl/1.torrent"}
      refute_received {:fetched, _host, _path}
    end

    test "a pick key that gives no row reads as a closed tag" do
      wait = {[3], ~U[2026-11-25 10:00:00Z]}

      table = [
        {:no_match, :no_match},
        {:no_language_match, :no_language_match},
        {{:waiting, wait}, :waiting},
        {{:season, []}, {:season, :none}},
        {{:anime, [], wait}, {:anime, :none}},
        {{:books, [], nil}, {:books, :none}},
        {{:error, :raised}, {:error, :raised}},
        {{:error, {:http_status, 500}}, {:error, {:http_status, 500}}},
        {{:error, {:raw, "https://x.example/?apikey=#{@key}"}}, {:error, :raw}},
        {{:release, {"Inception apikey=#{@key}", 1, {1}}}, :other},
        {"https://x.example/?apikey=#{@key}", :other}
      ]

      wrong =
        for {key, tag} <- table,
            cell = {key, LinkCheck.pick_tag(key)},
            cell != {key, tag},
            do: cell

      assert wrong == []
    end

    test "Prowlarr.restricted sends one indexerIds per allowed id, none outside it, and no request for no id",
         %{history: history} do
      prowlarr_search(history, fn _params, _ids -> [] end)

      Prowlarr.restricted(fn -> [7, 9] end, fn -> Prowlarr.search("tt1375666") end)
      assert_received {:prowlarr_search, _params, [7, 9]}

      assert Prowlarr.restricted(fn -> [] end, fn -> Prowlarr.search("tt1375666") end) ==
               {:ok, []}

      refute_received {:prowlarr_search, _, _}

      Prowlarr.search("tt1375666")
      assert_received {:prowlarr_search, _params, []}
    end
  end
end
