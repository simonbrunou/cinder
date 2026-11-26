defmodule Cinder.Acquisition.Indexer.NewznabSearchTest do
  # The per-type contract loop (#1624 point 2, #1653) over the Newznab and Torznab adapters, each
  # configured indexer behind the `Cinder.NewznabStub` plug (`Cinder.NewznabFixtures.route/1`):
  # required fields, the 1,000-row cap, the per-answer dedupe, the answer classes, caps that cannot
  # take the query, and the key-echo case. The class cases run through the real
  # `Cinder.Acquisition.IndexerSource.Native`, so each asserts the reason the report carries, and
  # call the parser directly beside it. #1671 adds Cardigann to `@adapters`.
  #
  # Not async: Native's clock and the caps table's clock are Native's global config.
  use Cinder.DataCase, async: false

  import Cinder.NewznabFixtures
  import ExUnit.CaptureLog

  alias Cinder.Acquisition.Indexer.{Newznab, NewznabAnswer, Torznab}
  alias Cinder.Acquisition.IndexerSource.{Native, Report}
  alias Cinder.ConfigCase
  alias Cinder.Indexers

  @now ~U[2026-11-26 12:00:00Z]

  @adapters [{Newznab, :newznab, :usenet}, {Torznab, :torznab, :torrent}]

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  defp context, do: %{deadline_at: System.monotonic_time(:millisecond) + 90_000}

  defp link(:newznab, url), do: {:nzb, url}
  defp link(:torznab, url), do: {:torrent, url}

  # Holds the stub's process until the monotonic time `at` without sleeping, which the
  # `req_stub_sleep_test.exs` fence refuses in a stub.
  defp busy_until(at) do
    if System.monotonic_time(:millisecond) < at, do: busy_until(at), else: :ok
  end

  defp delete!(indexer), do: :ok = Indexers.delete(nil, indexer.id)

  defp outcomes(%Report{indexers: indexers}),
    do: Map.new(indexers, fn {{"native", id}, %{outcome: outcome}} -> {id, outcome} end)

  test "Native's adapter map names both adapters, as config/config.exs sets it" do
    assert Application.fetch_env!(:cinder, :indexer_adapters) == %{
             newznab: Newznab,
             torznab: Torznab
           }
  end

  for {adapter, type, protocol} <- @adapters do
    @adapter adapter
    @type_name type
    @protocol protocol

    describe "#{inspect(adapter)}" do
      test "a search answers rows with the type's protocol and the request's query origin" do
        indexer = indexer!(@type_name, "a.example")

        route(%{
          "a.example" => fn _conn, query ->
            if query["t"] == "movie",
              do: rss([item("Movie.1999.1080p", link(@type_name, "https://a.example/1"))]),
              else: :default
          end
        })

        assert {[row], :asked} = @adapter.search(indexer, {:search, "tt0133093"}, context())

        assert row == %{
                 title: "Movie.1999.1080p",
                 download_url: "https://a.example/1",
                 download_url_origin: "https://a.example",
                 protocol: @protocol,
                 # The fixture's enclosure length.
                 size: 1,
                 category_ids: nil,
                 published_at: ~U[2026-11-25 10:30:00Z],
                 tvdb_id: nil,
                 query_origins: [:id_scoped]
               }

        # One request per query, with no limit or offset.
        assert [%{"t" => "movie", "imdbid" => "0133093"} = sent] = searches("a.example")
        refute Map.has_key?(sent, "limit") or Map.has_key?(sent, "offset")
      end

      test "a row missing a required field is dropped and the others kept" do
        indexer = indexer!(@type_name, "a.example")

        body =
          rss([
            item("", link(@type_name, "https://a.example/blank")),
            item(String.duplicate("a", 1025), link(@type_name, "https://a.example/long")),
            "<item><title>No.Link</title></item>",
            item("Kept", link(@type_name, "https://a.example/kept"))
          ])

        route(%{
          "a.example" => fn _conn, query -> if query["t"] == "movie", do: body, else: :default end
        })

        assert {[%{title: "Kept"}], :asked} =
                 @adapter.search(indexer, {:search, "tt0133093"}, context())
      end

      test "at most 1,000 rows per query, and a repeated link inside one answer is dropped" do
        indexer = indexer!(@type_name, "a.example")

        items =
          [item("First", link(@type_name, "https://a.example/0"))] ++
            for(n <- 0..1000, do: item("N#{n}", link(@type_name, "https://a.example/#{n}")))

        route(%{
          "a.example" => fn _conn, query ->
            if query["t"] == "movie", do: rss(items), else: :default
          end
        })

        assert {rows, :asked} = @adapter.search(indexer, {:search, "tt0133093"}, context())
        assert length(rows) == 1000
        assert hd(rows).title == "First"
        assert rows |> Enum.map(& &1.download_url) |> Enum.uniq() |> length() == 1000
        assert List.last(rows).download_url == "https://a.example/999"
      end

      test "caps that cannot take the query make the indexer not asked, beside a positive control" do
        no_imdb = indexer!(@type_name, "a.example")
        imdb = indexer!(@type_name, "b.example")
        movie_q_only = %{"movie-search" => ~s(available="yes" supportedParams="q")}

        route(%{
          "a.example" => fn _conn, query ->
            if query["t"] == "caps", do: caps(modes: movie_q_only), else: flunk("asked")
          end,
          "b.example" => fn _conn, _query -> :default end
        })

        assert @adapter.search(no_imdb, {:search, "tt0133093"}, context()) ==
                 {[], {:not_asked, :caps}}

        assert searches("a.example") == []

        assert {[], :asked} = @adapter.search(imdb, {:search, "tt0133093"}, context())
        assert [%{"t" => "movie"}] = searches("b.example")
      end

      test "a query error on the text query keeps the id-scoped rows and fails the indexer" do
        indexer = indexer!(@type_name, "a.example")

        route(%{
          "a.example" => fn _conn, query ->
            case query do
              %{"t" => "tvsearch", "tvdbid" => "81189"} ->
                rss([item("Show.S01E01", link(@type_name, "https://a.example/id"))])

              %{"t" => "tvsearch", "q" => "Show"} ->
                {400, error(201, "Incorrect parameter (q)")}

              _caps ->
                :default
            end
          end
        })

        assert {[%{title: "Show.S01E01", query_origins: [:id_scoped]}],
                {:failed, {:indexer_error, 201}}} =
                 @adapter.search(indexer, {:search_tv, 81_189, "Show", 1}, context())

        assert length(searches("a.example")) == 2
      end

      test "a query error on the id query still sends the text query" do
        indexer = indexer!(@type_name, "a.example")

        route(%{
          "a.example" => fn _conn, query ->
            case query do
              %{"tvdbid" => _id} ->
                error(300, "No such item")

              %{"q" => "Show"} ->
                rss([item("Show.S01E01", link(@type_name, "https://a.example/q"))])

              _caps ->
                :default
            end
          end
        })

        assert {[%{query_origins: [:free_text]}], {:failed, {:indexer_error, 300}}} =
                 @adapter.search(indexer, {:search_tv, 81_189, "Show", 1}, context())
      end

      test "any other failure stops the search, keeps earlier rows and outranks a query error" do
        indexer = indexer!(@type_name, "a.example")

        for {id_answer, text_answer, titles, outcome} <- [
              {rss([item("Id", link(@type_name, "https://a.example/id"))]), {503, "down"}, ["Id"],
               {:failed, {:http_status, 503}}},
              {error(201, "Incorrect parameter"), {401, ""}, [],
               {:failed, :rejected_credentials}},
              {error(201, "Incorrect parameter"), {429, [{"retry-after", "60"}], ""}, [],
               {:failed, {:limit, ~U[2026-11-26 12:01:00Z]}}}
            ] do
          route(%{
            "a.example" => fn _conn, query ->
              case query do
                %{"tvdbid" => _id} -> id_answer
                %{"q" => _q} -> text_answer
                _caps -> :default
              end
            end
          })

          assert {rows, ^outcome} =
                   @adapter.search(indexer, {:search_tv, 81_189, "Show", 1}, context())

          assert Enum.map(rows, & &1.title) == titles
        end

        # A stop on the id query sends no text query.
        route(%{
          "a.example" => fn _conn, query ->
            case query do
              %{"tvdbid" => _id} -> {401, ""}
              %{"q" => _q} -> flunk("text query sent")
              _caps -> :default
            end
          end
        })

        _drained = searches("a.example")

        assert {[], {:failed, :rejected_credentials}} =
                 @adapter.search(indexer, {:search_tv, 81_189, "Show", 1}, context())

        assert [%{"tvdbid" => "81189"}] = searches("a.example")
      end

      test "a deadline after a query error keeps the query error, so the indexer reads failed" do
        indexer = indexer!(@type_name, "a.example")
        test_pid = self()

        # The caps go in the table first, so the timed search sends only its two queries.
        route(%{"a.example" => fn _conn, _query -> :default end})
        assert {[], :asked} = @adapter.search(indexer, {:search, "tt0133093"}, context())

        deadline_at = System.monotonic_time(:millisecond) + 2_000

        # The id query answers 1 s before the deadline; the text query, sent with about 1 s
        # left, holds its answer past the deadline, so the deadline cuts it.
        route(%{
          "a.example" => fn _conn, query ->
            case query do
              %{"tvdbid" => _id} ->
                busy_until(deadline_at - 1_000)
                error(201, "Incorrect parameter")

              %{"q" => _q} ->
                send(test_pid, :text_sent)
                busy_until(deadline_at + 500)
                rss()
            end
          end
        })

        assert {[], {:failed, {:indexer_error, 201}}} =
                 @adapter.search(indexer, {:search_tv, 81_189, "Show", 1}, %{
                   deadline_at: deadline_at
                 })

        # The control: the text query was sent, so the deadline, not a stop, ended it.
        assert_received :text_sent
      end

      test "a search answer labelled JSON is read as its status, not decoded" do
        indexer = indexer!(@type_name, "a.example")

        route(%{
          "a.example" => fn _conn, query ->
            if query["t"] == "caps",
              do: :default,
              else: {401, [{"content-type", "application/json"}], "{apikey=x"}
          end
        })

        assert @adapter.search(indexer, {:search, "tt0133093"}, context()) ==
                 {[], {:failed, :rejected_credentials}}
      end

      test "the key-echo case: neither the error, the report nor the log holds the key" do
        indexer = indexer!(@type_name, "a.example")
        test_pid = self()

        route(%{
          "a.example" => fn conn, query ->
            send(test_pid, {:key, query["apikey"]})

            case query do
              %{"t" => "caps"} ->
                :default

              %{"t" => "movie"} ->
                {429, [{"x-key", query["apikey"]}], error(500, "limit #{query["apikey"]}")}

              _later ->
                Req.Test.transport_error(conn, :econnrefused)
            end
          end
        })

        log =
          capture_log([level: :debug], fn ->
            send(self(), {:first, @adapter.search(indexer, {:search, "tt0133093"}, context())})
            send(self(), {:native, Native.search("tt0133093")})

            send(
              self(),
              {:later, @adapter.search(indexer, {:search_tv_query, "Show", []}, context())}
            )
          end)

        # The control: the stub got the key, so a leak would have a key to carry.
        assert_received {:key, key}
        assert key == key()

        assert_received {:first, {[], {:failed, {:limit, nil}}} = first}
        assert_received {:native, {:error, {:no_indexer_answered, report}}}
        assert_received {:later, {[], {:failed, :connection_refused}} = later}

        for term <- [first, report, later] do
          refute inspect(term, limit: :infinity, printable_limit: :infinity) =~ key()
        end

        refute log =~ key()
      end
    end
  end

  # One row per class case: the answer the failing indexer gives, its class as the parser gives
  # it, and the reason Native's report carries. A transport row's class is the tag
  # `Cinder.Acquisition.Indexer.request/3` gives.
  @class_cases [
    {"HTTP 401", {401, [], ""}, :rejected_credentials, :rejected_credentials},
    {"HTTP 429 disabled till, with Retry-After",
     {429, [{"retry-after", "600"}],
      error(429, "Indexer is disabled till 11/26/2026 13:00:00 due to recent failures.")},
     {:disabled_till, ~U[2026-11-26 12:10:00Z]}, {:http_status, 429}},
    {"HTTP 429 with Retry-After: 120", {429, [{"retry-after", "120"}], ""},
     {:limit, ~U[2026-11-26 12:02:00Z]}, {:limit, ~U[2026-11-26 12:02:00Z]}},
    {"HTTP 429 with an HTTP-date Retry-After",
     {429, [{"retry-after", "Thu, 26 Nov 2026 15:30:00 GMT"}], ""},
     {:limit, ~U[2026-11-26 15:30:00Z]}, {:limit, ~U[2026-11-26 15:30:00Z]}},
    {"HTTP 429 with Retry in 7 minutes",
     {429, [], error(500, "Request limit reached. Retry in 7 minutes.")},
     {:limit, ~U[2026-11-26 12:07:00Z]}, {:limit, ~U[2026-11-26 12:07:00Z]}},
    {"HTTP 429 with no wait", {429, [], ""}, {:limit, nil}, {:limit, nil}},
    {"HTTP 410", {410, [], error(410, "Indexer is disabled")}, {:http_status, 410},
     {:http_status, 410}},
    {"HTTP 404", {404, [], ""}, {:http_status, 404}, {:http_status, 404}},
    {"code 100", {200, [], error(100, "Incorrect user credentials")}, :rejected_credentials,
     :rejected_credentials},
    {"code 101", {200, [], error(101, "Account suspended")}, :rejected_credentials,
     :rejected_credentials},
    {"code 102", {200, [], error(102, "Insufficient privileges")}, :rejected_credentials,
     :rejected_credentials},
    {"code 910", {200, [], error(910, "API disabled")}, :rejected_credentials,
     :rejected_credentials},
    {"code 500 with Request limit reached", {200, [], error(500, "Request limit reached")},
     {:limit, nil}, {:limit, nil}},
    {"code 500 without limit", {200, [], error(500, "Internal error")}, {:indexer_error, 500},
     {:indexer_error, 500}},
    {"code 201", {400, [], error(201, "Incorrect parameter")}, {:query_error, 201},
     {:indexer_error, 201}},
    {"code 300", {200, [], error(300, "No such item")}, {:query_error, 300},
     {:indexer_error, 300}},
    {"code 900", {200, [], error(900, "Unknown error")}, {:indexer_error, 900},
     {:indexer_error, 900}},
    {"HTTP 200 with an HTML page", {200, [], "<html><body><form>Login</form></body></html>"},
     :bad_response, :bad_response},
    {"HTTP 503", {503, [], "down"}, {:http_status, 503}, {:http_status, 503}},
    {"HTTP 408", {408, [], ""}, {:http_status, 408}, {:http_status, 408}},
    {"HTTP 403", {403, [], "forbidden"}, {:http_status, 403}, {:http_status, 403}},
    {"a redirect", {302, [{"location", "https://elsewhere.example/login"}], ""},
     {:http_status, 302}, {:http_status, 302}},
    {"a body over 4 MiB", {200, [], String.duplicate(" ", 4 * 1024 * 1024 + 1)}, :too_large,
     :too_large},
    {"a refused connection", {:transport, :econnrefused}, :connection_refused,
     :connection_refused},
    {"an NXDOMAIN", {:transport, :nxdomain}, :dns, :dns},
    {"a TLS failure", {:transport, {:tls_alert, {:handshake_failure, ~c"handshake failure"}}},
     :connection_failed, :connection_failed}
  ]

  describe "the answer classes, through the parser and through Native beside a success" do
    for {name, answer, class, reason} <- @class_cases do
      @answer answer
      @reason reason

      # One test body per answer shape, so the type checker sees no branch a literal cannot take.
      case answer do
        # `Indexer.request/3` (#1651) names the transport failure, and the parser passes the
        # tag through, so only the Native half has something to check here.
        {:transport, _reason} ->
          test name do
            assert_native_reason(@answer, @reason)
          end

        {_status, _headers, _body} ->
          @class class

          test name do
            {status, headers, body} = @answer
            headers = Map.new(headers, fn {name, value} -> {name, [value]} end)
            assert NewznabAnswer.classify(status, headers, body, @now) == {:error, @class}
            assert_native_reason(@answer, @reason)
          end
      end
    end
  end

  # Searches a failing indexer answering `answer` beside a healthy one, through each adapter.
  defp assert_native_reason(answer, reason) do
    for {_adapter, type, _protocol} <- @adapters do
      failing = indexer!(type, "fail-#{type}.example")
      healthy = indexer!(type, "ok-#{type}.example")

      route(%{
        "fail-#{type}.example" => fn conn, query ->
          if query["t"] == "caps", do: :default, else: respond(conn, answer)
        end,
        "ok-#{type}.example" => fn _conn, query ->
          if query["t"] == "movie",
            do: rss([item("Healthy", link(type, "https://ok-#{type}.example/1"))]),
            else: :default
        end
      })

      assert {:ok, [%{title: "Healthy"} = row], report} = Native.search("tt0133093")
      assert row.indexer_id == healthy.id

      assert outcomes(report) == %{failing.id => {:failed, reason}, healthy.id => :asked}
      assert Report.incomplete?(report)

      delete!(failing)
      delete!(healthy)
    end
  end

  describe "a caps answer through the same ladder" do
    test "a caps fetch that fails reports its class's reason, and plans nothing" do
      for {answer, reason} <- [
            {{429, [{"retry-after", "60"}], error(429, "Indexer is disabled till later")},
             {:http_status, 429}},
            {{400, [], error(201, "Incorrect parameter")}, {:indexer_error, 201}},
            {{200, [], error(100, "Incorrect user credentials")}, :rejected_credentials},
            {{429, [], ""}, {:limit, nil}}
          ] do
        indexer = indexer!(:newznab, "a.example")

        route(%{
          "a.example" => fn _conn, query ->
            if query["t"] == "caps", do: answer, else: flunk("searched")
          end
        })

        assert {answer, Newznab.search(indexer, {:search, "tt0133093"}, context())} ==
                 {answer, {[], {:failed, reason}}}

        delete!(indexer)
      end
    end
  end

  describe "through Native" do
    test "search_tv/3 with one Newznab indexer answers its rows, id-scoped first, and a report" do
      indexer = indexer!(:newznab, "a.example")

      route(%{
        "a.example" => fn _conn, query ->
          case query do
            %{"t" => "tvsearch", "q" => "Show"} ->
              rss([item("Show.S01E02", {:nzb, "https://a.example/text"})])

            %{"t" => "tvsearch", "tvdbid" => "81189"} ->
              rss([item("Show.S01E01", {:nzb, "https://a.example/id"})])

            _caps ->
              :default
          end
        end
      })

      assert {:ok, rows, report} = Native.search_tv(81_189, "Show", 1)

      assert Enum.map(rows, &{&1.title, &1.query_origins, &1.indexer_id, &1.indexer_source}) == [
               {"Show.S01E01", [:id_scoped], indexer.id, "native"},
               {"Show.S01E02", [:free_text], indexer.id, "native"}
             ]

      assert outcomes(report) == %{indexer.id => :asked}
    end

    test "the same link from two indexers gives two rows, each with its indexer" do
      a = indexer!(:torznab, "a.example")
      b = indexer!(:torznab, "b.example")
      magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"

      answer = fn _conn, query ->
        if query["t"] == "movie", do: rss([item("M", {:magnet, magnet})]), else: :default
      end

      route(%{"a.example" => answer, "b.example" => answer})

      assert {:ok, rows, _report} = Native.search("tt0133093")
      assert Enum.map(rows, &{&1.download_url, &1.indexer_id}) == [{magnet, a.id}, {magnet, b.id}]
    end

    test "a query error on one indexer's text query keeps its id-scoped rows beside another" do
      failing = indexer!(:newznab, "a.example")
      other = indexer!(:newznab, "b.example")

      route(%{
        "a.example" => fn _conn, query ->
          case query do
            %{"tvdbid" => _id} -> rss([item("Show.S01E01", {:nzb, "https://a.example/id"})])
            %{"q" => _q} -> {400, error(201, "Incorrect parameter")}
            _caps -> :default
          end
        end,
        "b.example" => fn _conn, _query -> :default end
      })

      assert {:ok, [%{title: "Show.S01E01"} = row], report} = Native.search_tv(81_189, "Show", 1)
      assert row.indexer_id == failing.id

      assert outcomes(report) == %{
               failing.id => {:failed, {:indexer_error, 201}},
               other.id => :asked
             }
    end

    test "a lone indexer with a query error answers no indexer answered (#1651's rule)" do
      # #1651's Native answers `{:error, {:no_indexer_answered, report}}` when no indexer was
      # asked, so this indexer's id-scoped rows are dropped. #1738 tracks keeping them.
      indexer = indexer!(:newznab, "a.example")

      route(%{
        "a.example" => fn _conn, query ->
          case query do
            %{"tvdbid" => _id} -> rss([item("Show.S01E01", {:nzb, "https://a.example/id"})])
            %{"q" => _q} -> {400, error(201, "Incorrect parameter")}
            _caps -> :default
          end
        end
      })

      assert {:error, {:no_indexer_answered, report}} = Native.search_tv(81_189, "Show", 1)
      assert outcomes(report) == %{indexer.id => {:failed, {:indexer_error, 201}}}
    end
  end
end
