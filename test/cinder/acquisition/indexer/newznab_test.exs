defmodule Cinder.Acquisition.Indexer.NewznabTest do
  # The request half of the Newznab and Torznab adapters (#1652): which requests each seam call
  # plans from an indexer's caps, read through the caps table. Every planned request is sent
  # through `Cinder.Acquisition.Indexer.request/3` to the `Cinder.NewznabStub` plug, and the
  # assertions read the query the stub received, `apikey` and URL encoding included. Each case of
  # the request table runs once per adapter, since Torznab shares Newznab's generator; the caps
  # fetch cases run through Newznab alone.
  #
  # Not async: the caps table's clock is Native's global config.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.Acquisition.Indexer
  alias Cinder.Acquisition.Indexer.{Newznab, Torznab}
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.IndexerCaps
  alias Cinder.ConfigCase
  alias Cinder.Indexers

  @key "nzb-key-0123456789"
  @seven_days_s 7 * 24 * 60 * 60

  @modes %{
    "search" => ~s(available="yes" supportedParams="q"),
    "tv-search" => ~s(available="yes" supportedParams="q,season,ep,tvdbid"),
    "movie-search" => ~s(available="yes" supportedParams="q,imdbid"),
    "book-search" => ~s(available="yes" supportedParams="q,title,author")
  }

  @categories [2000, 2040, 3000, 3030, 5000, 5070, 7000, 7020]

  setup do
    now = ~U[2026-11-26 12:00:00.000000Z]
    ConfigCase.put_env(Native, clock: fn -> now end)
    %{now: now}
  end

  defp caps_body(opts \\ []) do
    modes = Keyword.get(opts, :modes, @modes)
    categories = Keyword.get(opts, :categories, @categories)
    mode_lines = for {name, attrs} <- Enum.sort(modes), attrs, do: "<#{name} #{attrs}/>"
    category_lines = for id <- categories, do: ~s(<category id="#{id}" name="c#{id}"/>)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <caps><searching>#{mode_lines}</searching><categories>#{category_lines}</categories></caps>
    """
  end

  defp indexer!(type, overrides \\ %{}, secrets \\ %{"api_key" => @key}) do
    attrs =
      Map.merge(
        %{
          name: "Indexer #{System.unique_integer([:positive])}",
          type: type,
          base_url: "https://indexer.example",
          api_path: "/api"
        },
        overrides
      )

    {:ok, row} = Indexers.create(nil, attrs, secrets)
    {:ok, indexer} = Indexers.fetch_with_secrets(row.id)
    indexer
  end

  defp context, do: %{deadline_at: System.monotonic_time(:millisecond) + 90_000}

  # Answers `t=caps` with `caps` (a body, or a function of the conn) and every other request with
  # an empty RSS document, and reports each request's path and decoded query to the test.
  defp stub(caps) do
    test_pid = self()

    Req.Test.stub(Cinder.NewznabStub, fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_params})

      case {conn.query_params, caps} do
        {%{"t" => "caps"}, fun} when is_function(fun, 1) -> fun.(conn)
        {%{"t" => "caps"}, body} -> Plug.Conn.send_resp(conn, 200, body)
        _search -> Plug.Conn.send_resp(conn, 200, "<rss/>")
      end
    end)
  end

  # Plans one seam call against an indexer whose caps the stub answers, sends every planned
  # request, and answers each one's decoded query (the caps fetch left out) with its origin.
  defp planned(adapter, query, opts \\ []) do
    indexer = Keyword.get_lazy(opts, :indexer, fn -> indexer!(type(adapter)) end)
    stub(caps_body(opts))

    case adapter.plan(indexer, query, context()) do
      {:ok, planned} ->
        drain_caps_requests()

        for %{params: params, origin: origin} <- planned do
          options = adapter.request_options(indexer, params)
          assert {:ok, %Req.Response{status: 200}} = Indexer.request(context(), options)
          assert_received {:request, "/api", query}
          {query, origin}
        end

      other ->
        other
    end
  end

  defp type(Newznab), do: :newznab
  defp type(Torznab), do: :torznab

  defp drain_caps_requests do
    receive do
      {:request, _path, %{"t" => "caps"}} -> drain_caps_requests()
    after
      0 -> :ok
    end
  end

  defp caps_requests do
    receive do
      {:request, _path, %{"t" => "caps"}} -> 1 + caps_requests()
    after
      0 -> 0
    end
  end

  defp key(query), do: Map.put(query, "apikey", @key)

  for adapter <- [Newznab, Torznab] do
    @adapter adapter
    @name adapter |> Module.split() |> List.last()

    describe "#{@name}: search/1 (an IMDb id)" do
      test "asks t=movie with the id's digits, id-scoped, with no category" do
        assert planned(@adapter, {:search, "tt0133093"}) ==
                 [{key(%{"t" => "movie", "imdbid" => "0133093"}), :id_scoped}]
      end

      test "pads a 6-digit id to 7 and cuts tt; a longer id goes out whole" do
        for {id, digits} <- [
              {"tt133093", "0133093"},
              {"133093", "0133093"},
              {"tt12345678", "12345678"}
            ] do
          assert planned(@adapter, {:search, id}) ==
                   [{key(%{"t" => "movie", "imdbid" => digits}), :id_scoped}]
        end
      end

      test "is not asked, with no text query in its place, when movie-search lacks imdbid" do
        for attrs <- [
              ~s(available="yes" supportedParams="q"),
              ~s(available="no" supportedParams="q,imdbid"),
              nil
            ] do
          assert planned(@adapter, {:search, "tt0133093"},
                   modes: %{@modes | "movie-search" => attrs}
                 ) == {:not_asked, :caps}
        end
      end

      test "plans nothing for an id that is not digits, with or without a leading tt" do
        for id <- ["nm0000123", "tt", "", "tt0133093x"] do
          assert planned(@adapter, {:search, id}) == {:not_asked, :caps}
        end
      end
    end

    describe "#{@name}: search_tv/3" do
      test "asks the TVDB id with its season, and the title with its season, in that order" do
        assert planned(@adapter, {:search_tv, 81_189, "Breaking Bad", 2}) == [
                 {key(%{"t" => "tvsearch", "tvdbid" => "81189", "season" => "2"}), :id_scoped},
                 {key(%{"t" => "tvsearch", "q" => "Breaking Bad", "season" => "2"}), :free_text}
               ]
      end

      test "sends season 0 as 00 on both requests" do
        assert planned(@adapter, {:search_tv, 81_189, "Breaking Bad", 0}) == [
                 {key(%{"t" => "tvsearch", "tvdbid" => "81189", "season" => "00"}), :id_scoped},
                 {key(%{"t" => "tvsearch", "q" => "Breaking Bad", "season" => "00"}), :free_text}
               ]
      end

      test "leaves season off the id request, and falls back to t=search, when tv-search lacks season" do
        modes = %{@modes | "tv-search" => ~s(available="yes" supportedParams="q,tvdbid")}

        assert planned(@adapter, {:search_tv, 81_189, "Breaking Bad", 2}, modes: modes) == [
                 {key(%{"t" => "tvsearch", "tvdbid" => "81189"}), :id_scoped},
                 {key(%{"t" => "search", "q" => "Breaking Bad", "cat" => "5000,5070"}),
                  :free_text}
               ]
      end

      test "falls back to t=search for the title when tv-search lacks q" do
        modes = %{@modes | "tv-search" => ~s(available="yes" supportedParams="season,tvdbid")}

        assert planned(@adapter, {:search_tv, nil, "Breaking Bad", 2}, modes: modes) ==
                 [
                   {key(%{"t" => "search", "q" => "Breaking Bad", "cat" => "5000,5070"}),
                    :free_text}
                 ]
      end

      test "with no TVDB id asks only the title" do
        assert planned(@adapter, {:search_tv, nil, "Breaking Bad", 2}) ==
                 [{key(%{"t" => "tvsearch", "q" => "Breaking Bad", "season" => "2"}), :free_text}]
      end

      test "asks only the title when tv-search lacks tvdbid" do
        modes = %{@modes | "tv-search" => ~s(available="yes" supportedParams="q,season")}

        assert planned(@adapter, {:search_tv, 81_189, "Breaking Bad", 2}, modes: modes) ==
                 [{key(%{"t" => "tvsearch", "q" => "Breaking Bad", "season" => "2"}), :free_text}]
      end

      test "with no tv-search falls back to t=search scoped to TV, and to nothing without it" do
        modes = %{@modes | "tv-search" => nil}

        assert planned(@adapter, {:search_tv, 81_189, "Breaking Bad", 2}, modes: modes) ==
                 [
                   {key(%{"t" => "search", "q" => "Breaking Bad", "cat" => "5000,5070"}),
                    :free_text}
                 ]

        for {modes, categories} <- [
              {%{modes | "search" => ~s(available="yes" supportedParams="tvdbid")}, @categories},
              {%{modes | "search" => nil}, @categories},
              {modes, [2000, 7020]}
            ] do
          assert planned(@adapter, {:search_tv, 81_189, "Breaking Bad", 2},
                   modes: modes,
                   categories: categories
                 ) == {:not_asked, :caps}
        end
      end

      test "both queries share one caps fetch" do
        indexer = indexer!(type(@adapter))
        stub(caps_body())

        assert {:ok, [_by_id, _by_title]} =
                 @adapter.plan(indexer, {:search_tv, 81_189, "Breaking Bad", 2}, context())

        assert caps_requests() == 1
      end
    end

    describe "#{@name}: the free-text calls" do
      # `{call, default scope, the cat the default sends}`: the cat holds each id the caps list
      # (`@categories`) that the scope takes in.
      for {call, default, cat} <- [
            {:search_movie_query, "2000", "2000,2040"},
            {:search_tv_query, "5000", "5000,5070"},
            {:search_ebook_query, "7020", "7020"},
            {:search_audiobook_query, "3030", "3030"}
          ] do
        @call call
        @cat cat

        test "#{call} asks t=search scoped to #{default}, or to the caller's categories" do
          for opts <- [[], [categories: []]] do
            assert planned(@adapter, {@call, "Dune: Part Two", opts}) ==
                     [
                       {key(%{"t" => "search", "q" => "Dune: Part Two", "cat" => @cat}),
                        :free_text}
                     ],
                   inspect(opts)
          end

          assert planned(@adapter, {@call, "Dune", categories: [5070]}) ==
                   [{key(%{"t" => "search", "q" => "Dune", "cat" => "5070"}), :free_text}]
        end

        test "#{call} is not asked when search lacks q or the categories cover none of the scope" do
          assert planned(@adapter, {@call, "Dune", []},
                   modes: %{@modes | "search" => ~s(available="yes" supportedParams="imdbid")}
                 ) == {:not_asked, :caps}

          assert planned(@adapter, {@call, "Dune", []}, categories: [1000, 8000]) ==
                   {:not_asked, :caps}
        end
      end

      test "a 2000 scope reaches an indexer that lists only 2040 and sends it 2040, and a 5070 scope one that lists only 5000 does not" do
        assert [{%{"cat" => "2040"}, :free_text}] =
                 planned(@adapter, {:search_movie_query, "Dune", []}, categories: [2040])

        assert planned(@adapter, {:search_tv_query, "Frieren", categories: [5070]},
                 categories: [5000]
               ) == {:not_asked, :caps}
      end
    end

    describe "#{@name}: the book calls" do
      for {call, default} <- [{:search_ebook, "7020"}, {:search_audiobook, "3030"}] do
        @call call
        @default default

        test "#{call} asks t=book with title and author, scoped to #{default}" do
          for opts <- [[], [categories: []]] do
            assert planned(@adapter, {@call, "Frank Herbert", "Dune", opts}) == [
                     {key(%{
                        "t" => "book",
                        "title" => "Dune",
                        "author" => "Frank Herbert",
                        "cat" => @default
                      }), :id_scoped}
                   ],
                   inspect(opts)
          end
        end

        test "#{call} with a nil author asks the title alone, even when book-search lacks author" do
          modes = %{@modes | "book-search" => ~s(available="yes" supportedParams="title")}

          for modes <- [@modes, modes] do
            assert planned(@adapter, {@call, nil, "Dune", []}, modes: modes) ==
                     [{key(%{"t" => "book", "title" => "Dune", "cat" => @default}), :id_scoped}]
          end
        end

        test "#{call} takes the caller's categories" do
          assert [{%{"cat" => "7000,7020"}, :id_scoped}] =
                   planned(@adapter, {@call, nil, "Dune", categories: [7000]})
        end

        test "#{call} plans no request at all when book-search cannot take it" do
          for {author, attrs} <- [
                {nil, ~s(available="no" supportedParams="q,title,author")},
                {nil, nil},
                {nil, ~s(available="yes" supportedParams="q,author")},
                {"Frank Herbert", ~s(available="yes" supportedParams="q,title")}
              ] do
            assert planned(@adapter, {@call, author, "Dune", []},
                     modes: %{@modes | "book-search" => attrs}
                   ) == {:not_asked, :caps}
          end
        end

        test "#{call} is not asked when the categories cover none of its scope" do
          assert planned(@adapter, {@call, nil, "Dune", []}, categories: [2000, 5000]) ==
                   {:not_asked, :caps}
        end
      end
    end

    describe "#{@name}: requests" do
      test "keep the base URL's own path before the API path" do
        indexer =
          indexer!(type(@adapter), %{base_url: "https://host/prowlarr", api_path: "/5/api"})

        stub(caps_body())

        assert {:ok, [%{params: params}]} =
                 @adapter.plan(indexer, {:search, "tt0133093"}, context())

        assert_received {:request, "/prowlarr/5/api", %{"t" => "caps", "apikey" => @key}}

        assert {:ok, _response} =
                 Indexer.request(context(), @adapter.request_options(indexer, params))

        assert_received {:request, "/prowlarr/5/api", %{"t" => "movie", "apikey" => @key}}
      end

      test "go out as a GET whatever method the configured Req options set" do
        config = Application.get_env(:cinder, Newznab)
        req_options = Keyword.put(Keyword.fetch!(config, :req_options), :method, :post)
        ConfigCase.put_env(Newznab, Keyword.put(config, :req_options, req_options))

        options = @adapter.request_options(indexer!(type(@adapter)), t: "caps")
        assert Keyword.fetch!(options, :method) == :get
        assert Keyword.fetch!(options, :plug) == {Req.Test, Cinder.NewznabStub}
      end

      test "carry no apikey for an indexer with no key" do
        indexer = indexer!(type(@adapter), %{}, %{})

        assert planned(@adapter, {:search, "tt0133093"}, indexer: indexer) ==
                 [{%{"t" => "movie", "imdbid" => "0133093"}, :id_scoped}]
      end

      test "the planned requests hold no key" do
        indexer = indexer!(type(@adapter))
        stub(caps_body())

        assert {:ok, [_by_id, _by_title] = planned} =
                 @adapter.plan(indexer, {:search_tv, 81_189, "Breaking Bad", 2}, context())

        refute inspect(planned, limit: :infinity) =~ @key
      end
    end
  end

  describe "the caps fetch" do
    test "goes out as t=caps with the key, and its caps are stored", %{now: now} do
      indexer = indexer!(:newznab)
      stub(caps_body())

      assert {:ok, _planned} = Newznab.plan(indexer, {:search, "tt0133093"}, context())
      assert_received {:request, "/api", %{"t" => "caps", "apikey" => @key}}

      assert %IndexerCaps{config_version: 1, fetched_at: ^now, caps: caps} =
               Repo.get!(IndexerCaps, indexer.id)

      assert %{"modes" => %{"movie-search" => ["q", "imdbid"]}, "categories" => @categories} =
               caps
    end

    test "a row 7 days minus one second old is used with no caps request", %{now: now} do
      indexer = indexer!(:newznab)
      stub(caps_body())
      assert {:ok, _planned} = Newznab.plan(indexer, {:search, "tt0133093"}, context())
      assert caps_requests() == 1

      age(indexer, now, @seven_days_s - 1)
      assert {:ok, _planned} = Newznab.plan(indexer, {:search, "tt0133093"}, context())
      assert caps_requests() == 0
    end

    test "a row 7 days plus one second old is fetched again before the request", %{now: now} do
      indexer = indexer!(:newznab)
      stub(caps_body())
      assert {:ok, _planned} = Newznab.plan(indexer, {:search, "tt0133093"}, context())
      assert caps_requests() == 1

      age(indexer, now, @seven_days_s + 1)
      stub(caps_body(modes: %{@modes | "movie-search" => nil}))
      assert Newznab.plan(indexer, {:search, "tt0133093"}, context()) == {:not_asked, :caps}
      assert caps_requests() == 1
      assert %IndexerCaps{fetched_at: ^now} = Repo.get!(IndexerCaps, indexer.id)
    end

    test "a row stored under an older config_version is fetched again" do
      indexer = indexer!(:newznab)
      stub(caps_body())
      assert {:ok, _planned} = Newznab.plan(indexer, {:search, "tt0133093"}, context())
      assert caps_requests() == 1

      {:ok, _row} = Indexers.update(nil, indexer.id, indexer.lock_version, %{api_path: "/api2"})
      {:ok, edited} = Indexers.fetch_with_secrets(indexer.id)
      assert edited.config_version == 2

      assert {:ok, _planned} = Newznab.plan(edited, {:search, "tt0133093"}, context())
      assert_received {:request, "/api2", %{"t" => "caps"}}
      assert %IndexerCaps{config_version: 2} = Repo.get!(IndexerCaps, indexer.id)

      # The control: the same version reads the row it just stored.
      assert {:ok, _planned} = Newznab.plan(edited, {:search, "tt0133093"}, context())
      assert caps_requests() == 0
    end

    test "a failed fetch with an expired or stale row present fails and plans nothing", %{
      now: now
    } do
      for stale <- [:expired, :version] do
        indexer = indexer!(:newznab)
        stub(caps_body())
        assert {:ok, _planned} = Newznab.plan(indexer, {:search, "tt0133093"}, context())

        case stale do
          :expired -> age(indexer, now, @seven_days_s + 1)
          :version -> Repo.update_all(IndexerCaps, set: [config_version: 0])
        end

        stub(&Plug.Conn.send_resp(&1, 503, "down"))

        assert Newznab.plan(indexer, {:search, "tt0133093"}, context()) ==
                 {:failed, {:http_status, 503}}

        refute_received {:request, _path, %{"t" => "movie"}}
      end
    end

    test "deleting the configured indexer deletes its caps row" do
      indexer = indexer!(:newznab)
      stub(caps_body())
      assert {:ok, _planned} = Newznab.plan(indexer, {:search, "tt0133093"}, context())
      assert Repo.get(IndexerCaps, indexer.id)

      assert :ok = Indexers.delete(nil, indexer.id)
      refute Repo.get(IndexerCaps, indexer.id)
    end

    test "refetch_caps/2 fetches whatever the row holds and stores the answer" do
      indexer = indexer!(:torznab)
      stub(caps_body())
      assert {:ok, _planned} = Torznab.plan(indexer, {:search, "tt0133093"}, context())
      assert caps_requests() == 1

      stub(caps_body(categories: [5000]))
      assert {:ok, %{"categories" => [5000]}} = Torznab.refetch_caps(indexer, context())
      assert caps_requests() == 1
      assert %IndexerCaps{caps: %{"categories" => [5000]}} = Repo.get!(IndexerCaps, indexer.id)
    end

    for {name, answer, tag} <- [
          {"a refused connection", {:transport, :econnrefused}, :connection_refused},
          {"an unknown host", {:transport, :nxdomain}, :dns},
          {"a redirect", {:status, 302, ""}, {:http_status, 302}},
          {"an <error> answer on HTTP 200",
           {:status, 200, ~s(<error code="100" description="Incorrect user credentials"/>)},
           :rejected_credentials},
          {"an RSS answer to a caps request", {:status, 200, ~s(<rss><channel/></rss>)},
           :bad_response},
          {"a JSON body labelled JSON on HTTP 401", {:json_status, 401, "{apikey=x"},
           :rejected_credentials},
          {"an HTML page on HTTP 200", {:status, 200, "<html><body>Login</body></html>"},
           :bad_response},
          {"a body that is not XML", {:status, 200, "oops"}, :bad_response},
          {"a JSON body", {:json, %{"caps" => true}}, :bad_response},
          {"a declaration in a caps body", {:status, 200, "<!DOCTYPE caps>" <> "<caps/>"},
           :bad_response}
        ] do
      @answer answer
      @tag_name tag

      test "#{name} fails the indexer with #{inspect(tag)}" do
        indexer = indexer!(:newznab)

        stub(fn conn ->
          case @answer do
            {:transport, reason} -> Req.Test.transport_error(conn, reason)
            {:status, status, body} -> Plug.Conn.send_resp(conn, status, body)
            {:json, body} -> Req.Test.json(conn, body)
            {:json_status, status, body} -> json_resp(conn, status, body)
          end
        end)

        assert Newznab.plan(indexer, {:search, "tt0133093"}, context()) == {:failed, @tag_name}
        refute Repo.get(IndexerCaps, indexer.id)
      end
    end

    test "an HTTP 500 that echoes the key leaves no trace of it in the error or the log" do
      indexer = indexer!(:newznab)

      stub(fn conn ->
        Plug.Conn.send_resp(
          conn,
          500,
          "bad key #{conn.query_params["apikey"]} at #{conn.request_path}"
        )
      end)

      log =
        capture_log([level: :debug], fn ->
          send(self(), {:answer, Newznab.plan(indexer, {:search, "tt0133093"}, context())})
        end)

      assert_received {:answer, {:failed, {:http_status, 500}} = answer}
      # The control: the stub got the key, so a leak would have a key to carry.
      assert_received {:request, "/api", %{"apikey" => @key}}
      refute inspect(answer, limit: :infinity) =~ @key
      refute log =~ @key
    end

    test "with no time left sends nothing and reads as the deadline" do
      indexer = indexer!(:newznab)
      stub(caps_body())

      spent = %{deadline_at: System.monotonic_time(:millisecond) - 1}
      assert Newznab.plan(indexer, {:search, "tt0133093"}, spent) == {:failed, :deadline}

      refute_received {:request, _path, _query}
    end
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  defp age(indexer, now, seconds) do
    {1, _rows} =
      IndexerCaps
      |> where(configured_indexer_id: ^indexer.id)
      |> Repo.update_all(set: [fetched_at: DateTime.add(now, -seconds, :second)])
  end
end
