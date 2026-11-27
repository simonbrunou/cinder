defmodule Cinder.Acquisition.Indexer.CardigannSearchTest do
  # The Cardigann adapter (#1671) through the real `Cinder.Acquisition.IndexerSource.Native`, on
  # definitions and pages written for Cinder (`Cinder.CardigannFixtures`), behind the
  # `Cinder.CardigannStub` plug. Every page runs through a real parser worker, but in the worker
  # crash and deadline tests, which start a stub `erl` in its place.
  #
  # Not async: Native's clock is Native's global config.
  use Cinder.DataCase, async: false

  import Cinder.CardigannFixtures
  import Ecto.Query

  alias Cinder.Acquisition.IndexerSource.{Native, Report}
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.ConfigCase
  alias Cinder.Indexers
  alias Cinder.Indexers.Definitions
  alias Cinder.Indexers.Definitions.{Loader, LoadResult, Pin}
  alias Cinder.Test.OsProcess

  @now ~U[2026-11-26 12:00:00Z]

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  defp outcomes(%Report{indexers: indexers}),
    do: Map.new(indexers, fn {{"native", id}, %{outcome: outcome}} -> {id, outcome} end)

  defp frieren(n \\ 1) do
    for i <- 1..n//1 do
      %{
        id: i,
        title: "[Group] Frieren - #{String.pad_leading(Integer.to_string(i), 2, "0")} [1080p]",
        magnet: "magnet:?xt=urn:btih:#{String.duplicate(Integer.to_string(rem(i, 10)), 40)}",
        size: "1.4 GiB",
        date: "2026-11-25 10:30",
        cat: "1_2"
      }
    end
  end

  # Each used slot of the lease reports the gap it applied (`Native.Lease`), for this test only.
  defp spacing! do
    test_pid = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:cinder, :native, :lease, :spaced],
      fn _event, measure, meta, _ ->
        send(test_pid, {:spaced, meta.key, measure.spacing_ms})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp spaced do
    receive do
      {:spaced, key, ms} -> [{key, ms} | spaced()]
    after
      0 -> []
    end
  end

  # A Nyaa-shaped definition with three paths, told apart by their `p` input.
  defp three_paths(definition) do
    paths =
      for page <- ["1", "2", "3"],
          do: %{"path" => "/", "inputs" => obj([{"q", "{{ .Keywords }}"}, {"p", page}])}

    put_in(definition, ["search", "paths"], paths)
  end

  # A second Nyaa-shaped definition on its own site, to answer beside the one under test: Native
  # drops every row when no indexer was asked (#1738).
  defp other_nyaa,
    do: nyaa_like(&%{&1 | "id" => "cindertestother", "links" => ["https://other.test/"]})

  defp nyaa!(edit \\ & &1) do
    [indexer] = setup!([{"nyaa.yml", nyaa_like(edit)}], [{"nyaa.yml", nyaa_base(), %{}}])
    indexer
  end

  describe "a Nyaa-shaped definition" do
    test "a TV text search sends the declared inputs and answers rows with every field" do
      [indexer] = setup!([{"nyaa.yml", nyaa_like()}], [{"nyaa.yml", nyaa_base(), %{}}])
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      assert {:ok, [row], report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report) == %{indexer.id => :asked}

      assert [{"nyaa.test", "/", query}] = requests()
      assert query == %{"f" => "0", "c" => "0_0", "s" => "id", "o" => "desc", "q" => "frieren"}

      assert row.title == "[Group] Frieren - 01 [1080p]"
      assert row.download_url == "magnet:?xt=urn:btih:" <> String.duplicate("1", 40)
      assert row.protocol == :torrent
      # 1.4 GiB, cut toward zero.
      assert row.size == 1_503_238_553
      assert 5070 in row.category_ids
      assert row.published_at == ~U[2026-11-25 10:30:00Z]
      assert row.query_origins == [:free_text]
      assert row.download_url_origin == nil
      assert row.indexer_id == indexer.id
    end

    test "the second path goes out only when its URL differs, spaced by the lease" do
      indexer = nyaa!()
      spacing!()
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren(3)) end})

      assert {:ok, rows, _report} = Native.search_tv_query("frieren 05", categories: [5070])
      assert [{_, "/", %{"q" => "frieren 05"}}, {_, "/", %{"q" => "frieren 5"}}] = requests()
      # Both pages' rows, the second page's links repeating the first's.
      assert length(rows) == 6
      # The lease's own spacing, 10 ms in the test env, since `requestDelay` 2 is not above 2 s.
      assert spaced() == [{indexer.id, 10}, {indexer.id, 10}]

      assert {:ok, _rows, _report} = Native.search_tv_query("frieren", categories: [5070])
      assert [{_, "/", %{"q" => "frieren"}}] = requests()
    end

    test "a requestDelay above 2 s spaces the indexer's requests by it" do
      indexer = nyaa!(&Map.put(&1, "requestDelay", "3.5"))
      spacing!()
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren(1)) end})

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert spaced() == [{indexer.id, 3500}]
    end

    # A page's workers share one 30 s budget (#1679's `.Result` rounds), so the first gets 30 s
    # less the milliseconds spent before it starts.
    test "a page's parser worker gets 30 s, or less when the search deadline is nearer" do
      nyaa!()
      test_pid = self()
      id = {__MODULE__, make_ref()}

      :telemetry.attach(
        id,
        [:cinder, :cardigann, :parse],
        fn _event, measure, _meta, _ ->
          send(test_pid, {:parse, measure.deadline_ms})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren(1)) end})

      # Native's own 90 s deadline leaves more than the worker's 30 s.
      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert_received {:parse, full}
      assert full in 29_000..30_000

      Repo.delete_all(IndexerStatus)
      ConfigCase.put_env(Native, clock: fn -> @now end, deadline_ms: 5_000)
      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert_received {:parse, ms}
      assert ms in 1..5_000
    end

    test "a requestDelay past 60 s spaces the indexer's requests by 60 s" do
      # The lease keeps the 60 s gap for this indexer id, which the next test's indexer reuses:
      # a fresh lease starts with none.
      on_exit(fn ->
        :ok = Supervisor.terminate_child(Cinder.Supervisor, Native.Lease)
        {:ok, _lease} = Supervisor.restart_child(Cinder.Supervisor, Native.Lease)
      end)

      indexer = nyaa!(&Map.put(&1, "requestDelay", "600"))
      spacing!()
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren(1)) end})

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert spaced() == [{indexer.id, 60_000}]
    end

    test "the page loop goes on after a full page and stops after a short or empty one" do
      indexer = nyaa!(&three_paths/1)

      for {pages, sent} <- [{[3, 3, 3], 3}, {[3, 3, 2], 3}, {[3, 2, 3], 2}, {[0, 3, 3], 1}] do
        route(%{
          "nyaa.test" => fn _conn, %{"p" => page} ->
            nyaa_page(frieren(Enum.at(pages, String.to_integer(page) - 1)))
          end
        })

        assert {:ok, _rows, report} = Native.search_tv_query("frieren", categories: [5070])
        assert outcomes(report) == %{indexer.id => :asked}
        assert length(requests()) == sent, "pages #{inspect(pages)}"
      end
    end

    test "a path that fails after one answered keeps its rows and fails the indexer" do
      [failing, other] =
        setup!(
          [{"nyaa.yml", nyaa_like(&three_paths/1)}, {"other.yml", other_nyaa()}],
          [{"nyaa.yml", nyaa_base(), %{}}, {"other.yml", "https://other.test/", %{}}]
        )

      route(%{
        "nyaa.test" => fn _conn, %{"p" => page} ->
          if page == "1", do: nyaa_page(frieren(3)), else: {500, "down"}
        end,
        "other.test" => fn _conn, _query -> nyaa_page([]) end
      })

      assert {:ok, rows, report} = Native.search_tv_query("frieren", categories: [5070])
      assert length(rows) == 3
      assert Enum.all?(rows, &(&1.indexer_id == failing.id))

      assert outcomes(report) == %{
               failing.id => {:failed, {:http_status, 500}},
               other.id => :asked
             }
    end
  end

  defp t9!(edit \\ & &1, base \\ torrent9_base()) do
    definition = torrent9_like(&(&1 |> without_download() |> edit.()))
    [indexer] = setup!([{"t9.yml", definition}], [{"t9.yml", base, %{}}])
    indexer
  end

  defp t9_rows(titles),
    do:
      for(
        {title, i} <- Enum.with_index(titles, 1),
        do: %{
          title: title,
          href: "/details/#{i}",
          size: "1,4 Go",
          icon: "film",
          date: "25/11/2026"
        }
      )

  # A 200 HTML answer whose body comes with `content-encoding: encoding`.
  defp encoded(conn, encoding, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.put_resp_header("content-encoding", encoding)
    |> Plug.Conn.send_resp(200, body)
  end

  # The answer Native gives a lone indexer: rows when it was asked, else its report.
  defp search_answer({:ok, rows, report}), do: {rows, outcomes(report)}
  defp search_answer({:error, {:no_indexer_answered, report}}), do: {[], outcomes(report)}

  describe "a Torrent9-shaped definition" do
    test "a search reads its rows: the details link resolved, the size in French units" do
      indexer = t9!()

      route(%{
        "t9.test" => fn _conn, _query -> torrent9_page(t9_rows(["Dune Part Two 2024"])) end
      })

      assert {:ok, [row], report} = Native.search_movie_query("dune part two", [])
      assert outcomes(report) == %{indexer.id => :asked}
      assert [{"t9.test", "/search/dune-part-two.html", %{}}] = requests()
      assert row.download_url == "https://t9.test/details/1"
      # "1,4 Go" reads as 1.4 GB once its filter turns "Go" into "GB".
      assert row.size == 1_503_238_553
      assert row.category_ids == [2000]
      assert row.published_at == ~U[2026-11-25 00:00:00Z]
    end

    test "andmatch keeps the rows that answer the query text, and without it every row stays" do
      titles = ["Dune Part Two 2024", "Matrix"]
      route(%{"t9.test" => fn _conn, _query -> torrent9_page(t9_rows(titles)) end})

      filtered = t9!()
      assert {:ok, rows, _report} = Native.search_movie_query("dune part two", [])
      assert Enum.map(rows, & &1.title) == ["Dune Part Two 2024"]

      :ok = Indexers.delete(nil, filtered.id)
      t9!(&update_in(&1, ["search", "rows"], fn rows -> Map.delete(rows, "filters") end))
      assert {:ok, rows, _report} = Native.search_movie_query("dune part two", [])
      assert Enum.map(rows, & &1.title) == titles
    end

    test "with followredirect it follows a 302 on its own host and refuses a private address" do
      indexer = t9!()

      route(%{
        "t9.test" => fn conn, _query ->
          case conn.request_path do
            "/search/dune.html" -> {:redirect, 302, "/results/dune.html"}
            "/results/dune.html" -> torrent9_page(t9_rows(["Dune 2021"]))
            "/search/matrix.html" -> {:redirect, 302, "https://box.lan.test/matrix.html"}
          end
        end
      })

      assert {:ok, [_row], _report} = Native.search_movie_query("dune", [])
      assert [{_, "/search/dune.html", _}, {_, "/results/dune.html", _}] = requests()

      assert {[], outcomes} = search_answer(Native.search_movie_query("matrix", []))
      assert outcomes == %{indexer.id => {:failed, :forbidden_address}}
      # The private host got no request.
      assert [{"t9.test", "/search/matrix.html", _}] = requests()
    end

    test "without followredirect a 302 fails the indexer" do
      indexer = t9!(&Map.delete(&1, "followredirect"))
      route(%{"t9.test" => fn _conn, _query -> {:redirect, 302, "/results/dune.html"} end})

      assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes == %{indexer.id => {:failed, {:http_status, 302}}}
      assert [{_, "/search/dune.html", _}] = requests()
    end

    test "more than five redirect hops fail the indexer" do
      indexer = t9!()

      route(%{
        "t9.test" => fn conn, _query ->
          hop = conn.request_path |> String.trim_leading("/hop/") |> Integer.parse()

          case hop do
            {n, ""} -> {:redirect, 302, "/hop/#{n + 1}"}
            :error -> {:redirect, 302, "/hop/1"}
          end
        end
      })

      assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes == %{indexer.id => {:failed, :too_many_redirects}}
      # The first request and five hops.
      assert length(requests()) == 6
    end

    test "a base URL whose host resolves to a loopback address gets no request" do
      base = "https://t9.loopback.test/"
      indexer = t9!(&Map.put(&1, "links", [base]), base)
      route(%{"t9.loopback.test" => fn _conn, _query -> torrent9_page([]) end})

      assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes == %{indexer.id => {:failed, :forbidden_address}}
      assert requests() == []

      # The positive control: the same definition on a public address is asked.
      :ok = Indexers.delete(nil, indexer.id)
      t9!()
      route(%{"t9.test" => fn _conn, _query -> torrent9_page([]) end})
      assert {:ok, [], _report} = Native.search_movie_query("dune", [])
      assert [{"t9.test", _, _}] = requests()
    end

    test "a base URL whose host does not resolve gets no request" do
      base = "https://t9.nx.test/"
      indexer = t9!(&Map.put(&1, "links", [base]), base)

      assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes == %{indexer.id => {:failed, :dns}}
      assert requests() == []
    end

    test "a search URL the definition builds that the request path refuses is a definition error" do
      indexer = t9!(&put_in(&1, ["search", "paths"], [%{"path" => "ftp://t9.test/"}]))

      assert {[], outcomes} = search_answer(Native.search_movie_query("dune", []))
      assert outcomes == %{indexer.id => {:failed, :definition_error}}
      assert requests() == []
    end

    test "each answer class: a status fails the indexer, a 502 gets one retry, a challenge is named" do
      indexer = t9!()

      cloudflare = fn status ->
        fn conn ->
          conn
          |> Plug.Conn.put_resp_header("server", "cloudflare")
          |> Plug.Conn.send_resp(status, "")
        end
      end

      for {answers, outcome, sent} <- [
            {[{401, ""}], {:failed, :rejected_credentials}, 1},
            {[{403, ""}], {:failed, {:http_status, 403}}, 1},
            {[{404, ""}], {:failed, {:http_status, 404}}, 1},
            {[{500, ""}], {:failed, {:http_status, 500}}, 1},
            {[{502, ""}, {502, ""}], {:failed, {:http_status, 502}}, 2},
            {[{502, ""}, torrent9_page(t9_rows(["Dune 2021"]))], :asked, 2},
            {[cloudflare.(403)], {:failed, :challenge}, 1},
            # A 503 gets its retry before it reads as a challenge.
            {[cloudflare.(503)], {:failed, :challenge}, 2}
          ] do
        # Each case starts with no backoff, and each request takes the next answer, the last one
        # repeated.
        Repo.delete_all(IndexerStatus)
        {:ok, queue} = Agent.start_link(fn -> answers end)

        route(%{
          "t9.test" => fn conn, _query ->
            case Agent.get_and_update(queue, fn
                   [last] -> {last, [last]}
                   [next | rest] -> {next, rest}
                 end) do
              fun when is_function(fun, 1) -> fun.(conn)
              answer -> answer
            end
          end
        })

        answer = Native.search_movie_query("dune", [])

        case outcome do
          :asked ->
            assert {:ok, [_ | _], report} = answer
            assert outcomes(report) == %{indexer.id => :asked}

          failed ->
            assert {[], outcomes} = search_answer(answer)
            assert outcomes == %{indexer.id => failed}
        end

        assert {length(requests()), outcome} == {sent, outcome}
      end
    end

    test "a gzip body is read inflated up to the cap; another encoding or a broken gzip fails" do
      indexer = t9!()
      page = torrent9_page(t9_rows(["Dune 2021"]))
      # Inflates to one byte past the 2 MiB cap from a body far under it.
      bomb = :zlib.gzip(page <> "<!--" <> String.duplicate("x", 2_097_153) <> "-->")

      for {answer, outcome} <- [
            {fn conn -> encoded(conn, "gzip", :zlib.gzip(page)) end, :asked},
            {fn conn -> encoded(conn, "GZIP", :zlib.gzip(page)) end, :asked},
            {fn conn -> encoded(conn, "gzip", bomb) end, {:failed, :too_large}},
            {fn conn -> encoded(conn, "br", page) end, {:failed, :bad_response}},
            {fn conn -> encoded(conn, "gzip", "not gzip at all") end, {:failed, :bad_response}},
            {fn conn -> encoded(conn, "gzip", binary_part(:zlib.gzip(page), 0, 40)) end,
             {:failed, :bad_response}}
          ] do
        Repo.delete_all(IndexerStatus)
        route(%{"t9.test" => fn conn, _query -> answer.(conn) end})
        result = Native.search_movie_query("dune", [])

        case outcome do
          :asked ->
            assert {:ok, [row], report} = result
            assert row.title == "Dune 2021"
            assert outcomes(report) == %{indexer.id => :asked}

          failed ->
            assert {{[], outcomes}, ^failed} = {search_answer(result), failed}
            assert outcomes == %{indexer.id => failed}
        end
      end
    end
  end

  describe "a definition whose movie-search lists imdbid (#1632)" do
    setup do
      [nyaa] =
        setup!(
          [{"nyaa.yml", nyaa_like(&with_imdbid/1)}],
          [{"nyaa.yml", nyaa_base(), %{}}]
        )

      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})
      %{nyaa: nyaa}
    end

    test "a standard movie search sends the id request only, tagged id-scoped", %{nyaa: nyaa} do
      assert {:ok, [_ | _] = rows, report} =
               Native.search_movie("tt0133093", "Frieren 2023", [])

      assert outcomes(report) == %{nyaa.id => :asked}
      assert Enum.all?(rows, &(&1.query_origins == [:id_scoped]))

      sent = requests()
      assert sent != []

      for {"nyaa.test", "/", query} <- sent do
        assert query["imdb"] == "tt0133093"
        refute Map.has_key?(query, "q")
      end
    end

    test "an id that is not digits sends nothing, not the text in its place", %{nyaa: nyaa} do
      assert {[], outcomes} =
               search_answer(Native.search_movie("nm0000123", "Frieren 2023", []))

      assert outcomes == %{nyaa.id => {:not_asked, :caps}}
      assert requests() == []
    end
  end

  # Nyaa-shaped, with `imdbid` under movie-search and the id sent as the `imdb` input. A blank
  # input stays out, so a text query sends no `imdb`.
  defp with_imdbid(definition) do
    definition
    |> put_in(["caps", "modes", "movie-search"], ["q", "imdbid"])
    |> update_in(["search", "inputs"], fn %{values: values} ->
      obj(values ++ [{"imdb", "{{ .Query.IMDBID }}"}])
    end)
  end

  describe "the queries a definition listing only q in its modes asks" do
    setup do
      [nyaa, t9] =
        setup!(
          [{"nyaa.yml", nyaa_like()}, {"t9.yml", torrent9_like(&without_download/1)}],
          [{"nyaa.yml", nyaa_base(), %{}}, {"t9.yml", torrent9_base(), %{}}]
        )

      route(%{
        "nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end,
        "t9.test" => fn _conn, _query -> torrent9_page(t9_rows(["Frieren Book"])) end
      })

      %{nyaa: nyaa, t9: t9}
    end

    test "a movie IMDb search asks neither, a movie text search asks both", %{nyaa: nyaa, t9: t9} do
      assert {[], outcomes} = search_answer(Native.search("tt0133093"))
      assert outcomes == %{nyaa.id => {:not_asked, :caps}, t9.id => {:not_asked, :caps}}
      assert requests() == []

      assert {:ok, _rows, report} = Native.search_movie_query("frieren", [])
      assert outcomes(report) == %{nyaa.id => :asked, t9.id => :asked}
    end

    test "a standard movie search asks both by the \"Title Year\" text, tagged free text (#1632)",
         %{nyaa: nyaa, t9: t9} do
      assert {:ok, rows, report} = Native.search_movie("tt0133093", "Frieren 2023", [])
      assert outcomes(report) == %{nyaa.id => :asked, t9.id => :asked}
      assert rows != []
      assert Enum.all?(rows, &(&1.query_origins == [:free_text]))

      sent = requests()

      assert {"nyaa.test", "/", %{"q" => "Frieren 2023"}} in for(
               {h, p, q} <- sent,
               do: {h, p, Map.take(q, ["q"])}
             )

      # The Torrent9-shaped keyword filter joins the words with `-`.
      assert {"t9.test", "/search/Frieren-2023.html"} in for({h, p, _q} <- sent, do: {h, p})

      refute Enum.any?(sent, fn {_host, path, query} ->
               path =~ "0133093" or Map.has_key?(query, "imdb")
             end)
    end

    test "a standard movie search with a blank query asks neither", %{nyaa: nyaa, t9: t9} do
      assert {[], outcomes} = search_answer(Native.search_movie("tt0133093", " ", []))
      assert outcomes == %{nyaa.id => {:not_asked, :caps}, t9.id => {:not_asked, :caps}}
      assert requests() == []
    end

    test "a TV search with a TVDB id sends no id query, only its text one", %{nyaa: nyaa} do
      assert {:ok, rows, report} = Native.search_tv(81_189, "Frieren", 1)
      assert outcomes(report)[nyaa.id] == :asked
      assert Enum.all?(rows, &(&1.query_origins == [:free_text]))

      sent = requests()
      assert sent != []

      refute Enum.any?(sent, fn {_host, path, query} ->
               path =~ "81189" or Map.has_key?(query, "tvdbid")
             end)

      assert Enum.any?(sent, &match?({"nyaa.test", "/", %{"q" => "Frieren S01"}}, &1))
    end

    test "a season-0 TV search sends the title with no season", %{nyaa: nyaa} do
      assert {:ok, _rows, report} = Native.search_tv(81_189, "Frieren", 0)
      assert outcomes(report)[nyaa.id] == :asked
      assert for({"nyaa.test", _path, query} <- requests(), do: query["q"]) == ["Frieren"]
    end

    test "a structured e-book search asks neither, an e-book text search under Books asks",
         %{t9: t9} = ids do
      assert {[], outcomes} = search_answer(Native.search_ebook("Author", "Frieren", []))
      assert outcomes == %{ids.nyaa.id => {:not_asked, :caps}, t9.id => {:not_asked, :caps}}
      assert requests() == []

      # Nyaa-shaped maps no Books category, so only the Torrent9-shaped one is asked. The e-book
      # default 7020 reaches no mapping of either: Books (7000) is its parent, not a child.
      assert {:ok, [row], report} = Native.search_ebook_query("frieren", categories: [7000])
      assert outcomes(report) == %{ids.nyaa.id => {:not_asked, :caps}, t9.id => :asked}
      assert row.title == "Frieren Book"
    end
  end

  @secret "s3cr3t-Passkey+value"

  # A Nyaa-shaped definition with a `passkey` password setting sent as the `k` input, and a
  # `region` text setting.
  # Templates that read the passkey setting and render none of it. `Template` refuses an `if`
  # with no `else`.
  @names_passkey "{{ if .Config.passkey }}{{ .Result.magnet_page }}" <>
                   "{{ else }}{{ .Result.magnet_page }}{{ end }}"
  @names_passkey_blank "{{ if .Config.passkey }}{{ else }}{{ end }}"
  # The same templates reading `.Keywords`, for the control cases.
  @names_keywords String.replace(@names_passkey, ".Config.passkey", ".Keywords")
  @names_keywords_blank String.replace(@names_passkey_blank, ".Config.passkey", ".Keywords")

  defp with_passkey(definition),
    do: definition |> with_passkey_setting() |> with_input("k", "{{ .Config.passkey }}")

  # The passkey and region settings, with no template that reads them.
  defp with_passkey_setting(definition) do
    settings =
      definition["settings"] ++
        [
          %{"name" => "passkey", "type" => "password", "label" => "Passkey"},
          %{"name" => "region", "type" => "text", "label" => "Region", "default" => "eu"}
        ]

    Map.put(definition, "settings", settings)
  end

  defp with_input(definition, key, template) do
    update_in(definition, ["search", "inputs"], fn %{values: values} ->
      obj(values ++ [{key, template}])
    end)
  end

  describe "a secret setting" do
    test "a limit or a transport failure never carries the secret the stub saw" do
      [indexer] =
        setup!([{"nyaa.yml", nyaa_like(&with_passkey/1)}], [
          {"nyaa.yml", nyaa_base(), %{"passkey" => @secret}}
        ])

      for {answer, outcome} <- [
            {{429, "<html>slow down, #{@secret}</html>"},
             &match?({:failed, {:limit, %DateTime{}}}, &1)},
            {{:transport, :econnrefused}, &(&1 == {:failed, :connection_refused})}
          ] do
        # Each case starts with no backoff.
        Repo.delete_all(IndexerStatus)
        route(%{"nyaa.test" => fn _conn, _query -> answer end})

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(self(), {:answer, Native.search_tv_query("frieren", categories: [5070])})
          end)

        assert_received {:answer, answer}
        assert {[], outcomes} = search_answer(answer)
        assert outcome.(outcomes[indexer.id])

        # The positive control: the stub got the secret as the `k` input.
        assert [{"nyaa.test", "/", %{"k" => @secret}}] = requests()
        refute inspect(answer) =~ "s3cr3t"
        refute log =~ "s3cr3t"
      end
    end

    test "a URL that would carry the secret outside the credential hosts is not sent" do
      outside = fn definition ->
        definition
        |> with_passkey()
        |> put_in(["search", "paths"], [
          # A host the keywords fill: no credential host, since the definition cannot name it.
          %{
            "path" => "https://{{ .Keywords }}.mirror.test/",
            "inputs" => obj([{"q", "{{ .Keywords }}"}])
          }
        ])
      end

      [indexer, inside] =
        setup!(
          [{"nyaa.yml", nyaa_like(outside)}, {"other.yml", other_nyaa() |> with_passkey()}],
          [
            {"nyaa.yml", nyaa_base(), %{"passkey" => @secret}},
            {"other.yml", "https://other.test/", %{"passkey" => @secret}}
          ]
        )

      route(%{
        "frieren.mirror.test" => fn _conn, _query -> nyaa_page(frieren()) end,
        "other.test" => fn _conn, _query -> nyaa_page(frieren()) end
      })

      assert {:ok, _rows, report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report) == %{indexer.id => {:failed, :secret_host}, inside.id => :asked}
      # Only the credential host got a request, with the secret.
      assert [{"other.test", "/", %{"k" => @secret}}] = requests()
    end

    test "a redirect that would carry the secret to another host is not followed" do
      redirecting = fn definition ->
        definition |> with_passkey() |> Map.put("followredirect", "true")
      end

      [indexer] =
        setup!([{"nyaa.yml", nyaa_like(redirecting)}], [
          {"nyaa.yml", nyaa_base(), %{"passkey" => @secret}}
        ])

      route(%{
        "nyaa.test" => fn _conn, _query ->
          {:redirect, 302, "https://elsewhere.test/?k=" <> URI.encode_www_form(@secret)}
        end
      })

      assert {[], outcomes} = search_answer(Native.search_tv_query("frieren", categories: [5070]))
      assert outcomes == %{indexer.id => {:failed, :secret_host}}
      assert [{"nyaa.test", "/", _query}] = requests()
    end

    # A Nyaa-shaped indexer with a stored passkey that no template reads, which follows redirects,
    # its search page redirecting to `location`.
    defp redirecting_to!(location, secret \\ @secret) do
      redirecting = fn definition ->
        definition |> with_passkey_setting() |> Map.put("followredirect", "true")
      end

      [indexer] =
        setup!([{"nyaa.yml", nyaa_like(redirecting)}], [
          {"nyaa.yml", nyaa_base(), %{"passkey" => secret}}
        ])

      route(%{
        "nyaa.test" => fn conn, _query ->
          if conn.request_path == "/",
            do: {:redirect, 302, location},
            else: nyaa_page(frieren())
        end,
        "elsewhere.test" => fn _conn, _query -> nyaa_page(frieren()) end
      })

      indexer
    end

    test "a redirect whose Location is not UTF-8 keeps the secret off other hosts" do
      indexer =
        redirecting_to!("https://elsewhere.test/caf\xe9?k=" <> URI.encode_www_form(@secret))

      assert {[], outcomes} = search_answer(Native.search_tv_query("frieren", categories: [5070]))
      assert outcomes == %{indexer.id => {:failed, :secret_host}}
      assert [{"nyaa.test", "/", _query}] = requests()
    end

    test "a lone non-UTF-8 byte before a capitalised secret does not hide it from the check" do
      # `String.downcase/1` leaves the character after a lone 0xC3 byte as it is.
      indexer = redirecting_to!("https://elsewhere.test/\xc3Hunter2-passkey", "Hunter2-passkey")

      assert {[], outcomes} = search_answer(Native.search_tv_query("frieren", categories: [5070]))
      assert outcomes == %{indexer.id => {:failed, :secret_host}}
      assert [{"nyaa.test", "/", _query}] = requests()
    end

    test "a redirect whose Location is not UTF-8 is followed on the indexer's own host" do
      indexer = redirecting_to!("https://nyaa.test/caf\xe9")

      assert {:ok, [_ | _], report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report) == %{indexer.id => :asked}
    end

    test "a search template that transforms the secret still keeps its URL off other hosts" do
      # `re_replace` changes the value, so only the reference to the setting shows it.
      transformed = fn definition ->
        definition
        |> with_passkey_setting()
        |> with_input("k", ~S|{{ re_replace .Config.passkey "3" "e" }}|)
        |> put_in(["search", "paths"], [%{"path" => "https://{{ .Keywords }}.mirror.test/"}])
      end

      [indexer] =
        setup!([{"nyaa.yml", nyaa_like(transformed)}], [
          {"nyaa.yml", nyaa_base(), %{"passkey" => @secret}}
        ])

      route(%{"frieren.mirror.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      assert {[], outcomes} = search_answer(Native.search_tv_query("frieren", categories: [5070]))
      assert outcomes == %{indexer.id => {:failed, :secret_host}}
      assert requests() == []
    end

    test "a URL holding the secret value is not sent off the credential hosts, though no template reads it" do
      secret = "s3cr3tpasskey"

      unread = fn definition ->
        definition
        |> with_passkey_setting()
        |> put_in(["search", "paths"], [
          %{
            "path" => "https://{{ .Keywords }}.mirror.test/",
            "inputs" => obj([{"q", "{{ .Keywords }}"}])
          }
        ])
      end

      [indexer] =
        setup!([{"nyaa.yml", nyaa_like(unread)}], [
          {"nyaa.yml", nyaa_base(), %{"passkey" => secret}}
        ])

      route(%{(secret <> ".mirror.test") => fn _conn, _query -> nyaa_page(frieren()) end})

      assert {[], outcomes} = search_answer(Native.search_tv_query(secret, categories: [5070]))
      assert outcomes == %{indexer.id => {:failed, :secret_host}}
      assert requests() == []
    end

    test "a row whose link holds the secret value the page sent is dropped" do
      # No field template reads the secret: only the value in the page's magnet shows it.
      [indexer] =
        setup!([{"nyaa.yml", nyaa_like(&with_passkey/1)}], [
          {"nyaa.yml", nyaa_base(), %{"passkey" => @secret}}
        ])

      [clean, echoed] = frieren(2)
      tracker = "&tr=" <> URI.encode_www_form("https://x.test/a?k=" <> @secret)
      echoed = %{echoed | magnet: echoed.magnet <> tracker}
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page([clean, echoed]) end})

      answer = Native.search_tv_query("frieren", categories: [5070])
      assert {[row], outcomes} = search_answer(answer)
      assert outcomes == %{indexer.id => :asked}
      assert row.download_url == clean.magnet
      refute inspect(answer) =~ "s3cr3t"
    end

    test "a row whose link would carry the secret off the credential hosts is dropped" do
      tracker = "&tr=https%3A%2F%2Fevil.test%2Fannounce%3Fk%3D"

      for {label, field, link, kept?} <- [
            {"a magnet with the secret", "magnet",
             "{{ .Result.magnet_page }}#{tracker}{{ .Config.passkey }}", false},
            {"a magnet with the secret transformed", "magnet",
             ~s|{{ .Result.magnet_page }}#{tracker}{{ re_replace .Config.passkey "3" "e" }}|,
             false},
            {"a magnet from a template that only names the secret", "magnet", @names_passkey,
             false},
            # Each other part of a field that renders `.Config`, each naming the secret alone.
            {"a magnet whose default names the secret", "magnet",
             %{
               "selector" => "td.none",
               "optional" => "true",
               "default" => @names_passkey
             }, false},
            {"a magnet whose case value names the secret", "magnet",
             %{
               "selector" => "td:nth-child(3)",
               "case" =>
                 obj([
                   {~S|a[href^="magnet:?"]|, @names_passkey}
                 ])
             }, false},
            {"a magnet whose filter argument names the secret", "magnet",
             %{
               "text" => "{{ .Result.magnet_page }}",
               "filters" => [%{"name" => "append", "args" => @names_passkey_blank}]
             }, false},
            # The controls. A tracker that holds no secret keeps its magnet, and so does each
            # `if` case above with `.Keywords` in place of the secret, so a template the engine
            # refuses turns them red too.
            {"a magnet with a tracker that holds no secret", "magnet",
             "{{ .Result.magnet_page }}#{tracker}x", true},
            {"a magnet that names no secret", "magnet", @names_keywords, true},
            {"a magnet whose default names no secret", "magnet",
             %{
               "selector" => "td.none",
               "optional" => "true",
               "default" => @names_keywords
             }, true},
            {"a magnet whose case value names no secret", "magnet",
             %{
               "selector" => "td:nth-child(3)",
               "case" => obj([{~S|a[href^="magnet:?"]|, @names_keywords}])
             }, true},
            {"a magnet whose filter argument names no secret", "magnet",
             %{
               "text" => "{{ .Result.magnet_page }}",
               "filters" => [%{"name" => "append", "args" => @names_keywords_blank}]
             }, true},
            # A host the keywords fill: a host the definition's text names is a credential host.
            {"a download link on another host", "download",
             "https://{{ .Keywords }}.mirror.test/dl?k={{ .Config.passkey }}", false},
            {"a download link on the credential host", "download",
             "https://nyaa.test/dl?k={{ .Config.passkey }}", true}
          ] do
        leaky = fn definition ->
          definition
          |> with_passkey()
          |> update_in(["search", "fields"], fn %{values: values} ->
            {"magnet", page_magnet} = List.keyfind(values, "magnet", 0)

            values
            |> List.keydelete("magnet", 0)
            |> List.keydelete("download", 0)
            |> Kernel.++([{"magnet_page", page_magnet}, {field, spec(link)}])
            |> then(&if(field == "download", do: &1 ++ [{"magnet", page_magnet}], else: &1))
            |> obj()
          end)
        end

        [indexer] =
          setup!([{"nyaa.yml", nyaa_like(leaky)}], [
            {"nyaa.yml", nyaa_base(), %{"passkey" => @secret}}
          ])

        route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})
        answer = Native.search_tv_query("frieren", categories: [5070])
        {rows, outcomes} = search_answer(answer)

        assert outcomes == %{indexer.id => :asked}, label
        assert length(rows) == if(kept?, do: 1, else: 0), label
        if not kept?, do: refute(inspect(answer) =~ "s3cr3t", label)
        :ok = Indexers.delete(nil, indexer.id)
      end
    end
  end

  # A field's text, or its whole spec.
  defp spec(%{} = spec), do: spec
  defp spec(text), do: %{"text" => text}

  # A pattern that hits `BoundedRegex`'s match limit on `@backtracks`, and none other.
  @limit_pattern "^(a+)+$"
  @backtracks String.duplicate("a", 30) <> "!"

  defp limit_title(definition) do
    update_in(definition, ["search", "fields"], fn %{values: values} ->
      obj(
        List.keyreplace(
          values,
          "title",
          0,
          {"title",
           %{
             "text" => "{{ .Result.title_default }}",
             "filters" => [%{"name" => "re_replace", "args" => [@limit_pattern, "x"]}]
           }}
        )
      )
    end)
  end

  # A filter that turns each Z into 2,000 bytes: `@cap_input`'s 40 Zs pass the 65,536-byte cap.
  @cap_filter %{"name" => "re_replace", "args" => ["Z", String.duplicate("x", 2_000)]}
  @cap_input String.duplicate("Z", 40)

  defp cap_title(definition) do
    update_in(definition, ["search", "fields"], fn %{values: values} ->
      obj(
        List.keyreplace(
          values,
          "title",
          0,
          {"title", %{"text" => "{{ .Result.title_default }}", "filters" => [@cap_filter]}}
        )
      )
    end)
  end

  defp status(indexer), do: IndexerStatus.read([indexer])[indexer.id]

  # A stub `erl` for the parser worker, in place of the real one (`ParserWorker`'s moduledoc).
  defp erl_stub!(tmp, body) do
    path = Path.join(tmp, "erl")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    ConfigCase.put_env(:parser_worker_erl, path)
  end

  describe "limits and the parser worker" do
    test "a field that hits the regex limit drops only its row, fails the query, starts no backoff" do
      [limited, other] =
        setup!(
          [{"nyaa.yml", nyaa_like(&limit_title/1)}, {"other.yml", other_nyaa()}],
          [{"nyaa.yml", nyaa_base(), %{}}, {"other.yml", "https://other.test/", %{}}]
        )

      [fine | _] = frieren()

      route(%{
        "nyaa.test" => fn _conn, _query ->
          nyaa_page([%{fine | id: 2, title: @backtracks}, fine])
        end,
        "other.test" => fn _conn, _query -> nyaa_page([]) end
      })

      assert {:ok, rows, report} = Native.search_tv_query("frieren", categories: [5070])
      # The positive control: the row the pattern does not match keeps its title.
      assert Enum.map(rows, &{&1.indexer_id, &1.title}) == [{limited.id, fine.title}]
      assert outcomes(report) == %{limited.id => {:failed, :regex_limit}, other.id => :asked}

      status = status(limited)
      assert status.backoff == :none
      assert {status.last_partial, status.last_partial_at} == {:regex_limit, @now}
      assert status.last_failure == nil
    end

    test "a keyword filter that hits the regex limit sends no request for that query" do
      limited_keywords = fn definition ->
        put_in(definition, ["search", "keywordsfilters"], [
          %{"name" => "re_replace", "args" => [@limit_pattern, "x"]}
        ])
      end

      [limited, other] =
        setup!(
          [{"nyaa.yml", nyaa_like(limited_keywords)}, {"other.yml", other_nyaa()}],
          [{"nyaa.yml", nyaa_base(), %{}}, {"other.yml", "https://other.test/", %{}}]
        )

      route(%{
        "nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end,
        "other.test" => fn _conn, _query -> nyaa_page(frieren()) end
      })

      assert {:ok, _rows, report} = Native.search_tv_query(@backtracks, categories: [5070])
      assert outcomes(report) == %{limited.id => {:failed, :regex_limit}, other.id => :asked}
      assert Enum.all?(requests(), &(elem(&1, 0) == "other.test"))
      assert status(limited).backoff == :none

      # The positive control: a query the pattern does not match is sent.
      assert {:ok, _rows, report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report)[limited.id] == :asked
      assert Enum.any?(requests(), &(elem(&1, 0) == "nyaa.test"))
    end

    test "a field past the filter output cap drops only its row and fails the query" do
      [capped, other] =
        setup!(
          [{"nyaa.yml", nyaa_like(&cap_title/1)}, {"other.yml", other_nyaa()}],
          [{"nyaa.yml", nyaa_base(), %{}}, {"other.yml", "https://other.test/", %{}}]
        )

      [fine | _] = frieren()

      route(%{
        "nyaa.test" => fn _conn, _query ->
          nyaa_page([%{fine | id: 2, title: @cap_input}, fine])
        end,
        "other.test" => fn _conn, _query -> nyaa_page([]) end
      })

      assert {:ok, rows, report} = Native.search_tv_query("frieren", categories: [5070])
      assert Enum.map(rows, &{&1.indexer_id, &1.title}) == [{capped.id, fine.title}]
      assert outcomes(report) == %{capped.id => {:failed, :filter_output_cap}, other.id => :asked}
      assert status(capped).last_partial == :filter_output_cap
    end

    test "a keyword filter past the filter output cap sends no request for that query" do
      capped_keywords = fn definition ->
        put_in(definition, ["search", "keywordsfilters"], [@cap_filter])
      end

      [capped, other] =
        setup!(
          [{"nyaa.yml", nyaa_like(capped_keywords)}, {"other.yml", other_nyaa()}],
          [{"nyaa.yml", nyaa_base(), %{}}, {"other.yml", "https://other.test/", %{}}]
        )

      route(%{
        "nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end,
        "other.test" => fn _conn, _query -> nyaa_page(frieren()) end
      })

      assert {:ok, _rows, report} = Native.search_tv_query(@cap_input, categories: [5070])
      assert outcomes(report) == %{capped.id => {:failed, :filter_output_cap}, other.id => :asked}
      assert Enum.all?(requests(), &(elem(&1, 0) == "other.test"))

      # The positive control: a query with no Z is sent.
      assert {:ok, _rows, report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report)[capped.id] == :asked
      assert Enum.any?(requests(), &(elem(&1, 0) == "nyaa.test"))
    end

    @tag :tmp_dir
    test "a worker that crashes on the page fails the indexer and starts a failure backoff", %{
      tmp_dir: tmp
    } do
      indexer = nyaa!()
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      # The positive control: the real worker reads the page.
      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])

      erl_stub!(tmp, "exit 3")
      assert {[], outcomes} = search_answer(Native.search_tv_query("frieren", categories: [5070]))
      assert outcomes == %{indexer.id => {:failed, :parser_failed}}

      status = status(indexer)
      assert {status.backoff, status.last_failure} == {:failure, :parser_failed}
    end

    @tag :tmp_dir
    test "the search deadline kills a running worker: its OS process is gone once the call returns",
         %{tmp_dir: tmp} do
      indexer = nyaa!()
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})
      pidfile = Path.join(tmp, "worker.pid")

      erl_stub!(
        tmp,
        "echo $$ > '#{pidfile}.tmp' && mv '#{pidfile}.tmp' '#{pidfile}'\nexec sleep 30"
      )

      ConfigCase.put_env(Native, clock: fn -> @now end, deadline_ms: 1_500)

      # A lone indexer the deadline cut reads as Native's retry 60 s later.
      assert Native.search_tv_query("frieren", categories: [5070]) ==
               {:error, {:indexers_backing_off, DateTime.add(@now, 60, :second)}}

      {:ok, pid} = OsProcess.await_record(pidfile)
      assert OsProcess.dead?(pid |> String.trim() |> String.to_integer())
      # A deadline cut starts no backoff.
      assert status(indexer).backoff == :none
    end
  end

  # The Nyaa-shaped fields with the magnet read as an info hash instead.
  defp infohash_only(definition) do
    update_in(definition, ["search", "fields"], fn %{values: values} ->
      values =
        values
        |> List.keydelete("magnet", 0)
        |> Kernel.++([
          {"infohash",
           %{
             "selector" => ~S|td:nth-child(3) a[href^="magnet:?"]|,
             "attribute" => "href",
             "filters" => [%{"name" => "regexp", "args" => "btih:([0-9a-f]+)"}]
           }}
        ])

      obj(values)
    end)
  end

  # An input that shows the site ids the scope reached.
  defp with_categories_input(definition) do
    update_in(definition, ["search", "inputs"], fn %{values: values} ->
      obj(values ++ [{"cats", ~S|{{ join .Categories "," }}|}])
    end)
  end

  defp request_task_telemetry! do
    test_pid = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:cinder, :http, :request_task],
      fn _event, _measure, meta, _ ->
        send(test_pid, {:request_task, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "rows" do
    test "an info-hash-only row gets a magnet on a public definition and is dropped on a private one" do
      [hash] = Regex.run(~r/btih:([0-9a-f]+)/, hd(frieren()).magnet, capture: :all_but_first)
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      public = nyaa!(&infohash_only/1)
      assert {:ok, [row], _report} = Native.search_tv_query("frieren", categories: [5070])

      assert row.download_url ==
               "magnet:?xt=urn:btih:#{hash}&dn=%5BGroup%5D+Frieren+-+01+%5B1080p%5D"

      :ok = Indexers.delete(nil, public.id)
      nyaa!(&(&1 |> infohash_only() |> Map.put("type", "private")))
      assert {:ok, [], _report} = Native.search_tv_query("frieren", categories: [5070])
    end

    test "one site id maps to two categories, and a scope reaches its child categories" do
      indexer = nyaa!(&with_categories_input/1)
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      assert {:ok, [row], _report} = Native.search_tv_query("frieren", categories: [5070])
      # 1_2 maps to both TV/Anime and Movies/Other.
      assert row.category_ids == [5070, 2020]
      assert [{_, _, %{"cats" => "1_0,1_2"}}] = requests()

      # TV (5000) reaches TV/Anime and TV; Movies (2000) reaches Movies/Other.
      assert {:ok, _rows, _report} = Native.search_tv_query("frieren", categories: [5000])
      assert [{_, _, %{"cats" => "1_0,1_2,4_0"}}] = requests()
      assert {:ok, _rows, _report} = Native.search_movie_query("frieren", [])
      assert [{_, _, %{"cats" => "1_0,1_2"}}] = requests()

      # An audiobook scope (3030) reaches no mapping: Audio (3000) is its parent.
      assert {:ok, [], report} = Native.search_audiobook_query("frieren", [])
      assert outcomes(report) == %{indexer.id => {:not_asked, :caps}}
      assert requests() == []
    end

    test "a standard movie search's text takes the Movies scope, else the caller's (#1632)" do
      nyaa!(&with_categories_input/1)
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      # Movies (2000) reaches Movies/Other alone, where TV (5000) would add 4_0.
      assert {:ok, _rows, _report} = Native.search_movie("tt0133093", "Frieren 2023", [])
      assert [{_, _, %{"cats" => "1_0,1_2", "q" => "Frieren 2023"}}] = requests()

      assert {:ok, _rows, _report} =
               Native.search_movie("tt0133093", "Frieren 2023", categories: [5000])

      assert [{_, _, %{"cats" => "1_0,1_2,4_0"}}] = requests()
    end

    test "a scope that reaches no mapping is not asked, though a mapping is marked default; the Test sends the default" do
      with_default = fn definition ->
        definition
        |> with_categories_input()
        |> update_in(["caps", "categorymappings"], fn mappings ->
          Enum.map(mappings, &if(&1["id"] == "4_0", do: Map.put(&1, "default", true), else: &1))
        end)
      end

      indexer = nyaa!(with_default)
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      # Books (7000) reaches no Nyaa-shaped mapping: the default one is for a call with no
      # category, so the indexer is not asked.
      assert {:ok, [], report} = Native.search_ebook_query("frieren", categories: [7000])
      assert outcomes(report) == %{indexer.id => {:not_asked, :caps}}
      assert requests() == []

      # A scope that reaches a mapping sends that mapping alone.
      assert {:ok, _rows, _report} = Native.search_tv_query("frieren", categories: [5070])
      assert [{"nyaa.test", "/", %{"cats" => "1_0,1_2"}} | _] = requests()

      # The Test asks no category, so it sends the default one.
      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
      assert [{"nyaa.test", "/", %{"cats" => "4_0"}}] = requests()
    end

    test "a select and a checkbox setting reach the inputs and fields, a blank input stays out" do
      [indexer] =
        setup!([{"nyaa.yml", nyaa_like()}], [
          {"nyaa.yml", nyaa_base(), %{},
           %{settings: %{"sort" => "seeders", "prefer_magnet_links" => false}}}
        ])

      rows = for row <- frieren(1), do: Map.put(row, :torrent, "/download/1.torrent")
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(rows) end})

      # One row from each of the two paths.
      assert {:ok, [row, _second], _report} =
               Native.search_tv_query("frieren 05", categories: [5070])

      assert row.indexer_id == indexer.id
      # The checkbox off: the download field reads the torrent link, resolved on the page's URL.
      assert row.download_url == "https://nyaa.test/download/1.torrent"

      assert [{_, _, first}, {_, _, second}] = requests()
      assert first["s"] == "seeders"
      # The second path's `p` renders blank while there are keywords.
      assert second == %{
               "f" => "0",
               "c" => "0_0",
               "s" => "seeders",
               "o" => "desc",
               "q" => "frieren 5"
             }
    end

    test "a TV search on a definition with no tv-search mode sends the title as a search query" do
      indexer =
        nyaa!(&update_in(&1, ["caps", "modes"], fn modes -> Map.delete(modes, "tv-search") end))

      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      assert {:ok, [row], report} = Native.search_tv(81_189, "Frieren", 1)
      assert outcomes(report) == %{indexer.id => :asked}
      assert row.query_origins == [:free_text]
      assert [{"nyaa.test", "/", %{"q" => "Frieren"}}] = requests()
    end

    test "a byte that is not UTF-8 reads as U+FFFD and its row stays" do
      indexer = nyaa!()
      [fine, latin1] = frieren(2)
      latin1 = %{latin1 | title: "Frieren caf" <> <<0xE9>>, size: "1.4 GiB" <> <<0xE9>>}
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page([fine, latin1]) end})

      assert {:ok, rows, report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report) == %{indexer.id => :asked}

      assert Enum.map(rows, &{&1.title, &1.size}) == [
               {fine.title, 1_503_238_553},
               {"Frieren caf\uFFFD", 1_503_238_553}
             ]
    end

    test "a row with a blank title, a title over 1,024 bytes or no link is dropped" do
      nyaa!()
      [fine, blank, long, linkless] = frieren(4)

      page = [
        fine,
        %{blank | title: "   "},
        %{long | title: String.duplicate("a", 1_025)},
        %{linkless | magnet: ""}
      ]

      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(page) end})

      assert {:ok, [row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert row.title == fine.title

      # The positive control: a title of 1,024 bytes is kept.
      route(%{
        "nyaa.test" => fn _conn, _query ->
          nyaa_page([%{long | title: String.duplicate("a", 1_024)}])
        end
      })

      assert {:ok, [row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert byte_size(row.title) == 1_024
    end

    test "one page keeps 1,000 rows, a repeated link dropped first" do
      nyaa!()

      rows =
        for i <- 1..1_001 do
          %{
            hd(frieren())
            | id: i,
              magnet: "magnet:?xt=urn:btih:" <> String.pad_leading("#{i}", 40, "0")
          }
        end

      repeated = %{hd(rows) | id: 0}
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page([hd(rows), repeated | tl(rows)]) end})

      assert {:ok, kept, _report} = Native.search_tv_query("frieren", categories: [5070])
      assert length(kept) == 1_000
      assert List.last(kept).download_url == Enum.at(rows, 999).magnet
    end

    test "a query keeps 1,000 rows over its pages" do
      nyaa!(&three_paths/1)

      rows =
        for i <- 1..1_200 do
          %{
            hd(frieren())
            | id: i,
              magnet: "magnet:?xt=urn:btih:" <> String.pad_leading("#{i}", 40, "0")
          }
        end

      {first, second} = Enum.split(rows, 600)
      pages = %{"1" => first, "2" => second, "3" => []}
      route(%{"nyaa.test" => fn _conn, query -> nyaa_page(pages[query["p"]]) end})

      assert {:ok, kept, _report} = Native.search_tv_query("frieren", categories: [5070])
      # The positive control: every page went out.
      assert length(requests()) == 3
      assert length(kept) == 1_000
      assert List.last(kept).download_url == Enum.at(rows, 999).magnet
    end

    test "a body of the 2 MiB cap is read, one byte more fails, and each request has 30 s" do
      indexer = nyaa!()
      request_task_telemetry!()
      page = nyaa_page(frieren())

      padded = fn size ->
        page <> "<!--" <> String.duplicate("x", size - byte_size(page) - 7) <> "-->"
      end

      route(%{"nyaa.test" => fn _conn, _query -> padded.(2_097_152) end})
      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])

      # The request's own budget, and no path in the telemetry: a path can hold a setting.
      assert_received {:request_task, %{deadline_ms: 30_000, path: nil}}

      Repo.delete_all(IndexerStatus)
      route(%{"nyaa.test" => fn _conn, _query -> padded.(2_097_153) end})
      assert {[], outcomes} = search_answer(Native.search_tv_query("frieren", categories: [5070]))
      assert outcomes == %{indexer.id => {:failed, :too_large}}
    end
  end

  describe "the running copy and the Test" do
    # #1679 builds every `download` key but `before.pathselector` and a custom
    # `before.queryseparator`, which no v11 definition sets.
    test "a copy that reads not supported is not asked and its Test sends nothing" do
      code = :download_before_pathselector

      path_selector = fn definition ->
        put_in(definition, ["download", "before"], %{
          "path" => "thanks.php",
          "pathselector" => %{"selector" => "a.thanks", "attribute" => "href"}
        })
      end

      [indexer] =
        setup!([{"t9.yml", torrent9_like(path_selector)}], [{"t9.yml", torrent9_base(), %{}}])

      route(%{"t9.test" => fn _conn, _query -> torrent9_page([]) end})

      assert {:ok, [], report} = Native.search_movie_query("dune", [])
      assert outcomes(report) == %{indexer.id => {:not_asked, {:not_supported, code}}}
      assert Native.test_indexer(indexer.id) == {:error, {:not_supported, code}}
      assert requests() == []
    end

    test "a Torrent9-shaped copy with its download block is asked" do
      [indexer] = setup!([{"t9.yml", torrent9_like()}], [{"t9.yml", torrent9_base(), %{}}])

      route(%{
        "t9.test" => fn _conn, _query ->
          torrent9_page([%{title: "Dune 2021 1080p", href: "/torrent/1", size: "2.1 Go"}])
        end
      })

      assert {:ok, [row], report} = Native.search_movie_query("dune", [])
      assert outcomes(report) == %{indexer.id => :asked}
      assert row.download_url == "https://t9.test/torrent/1"
    end

    test "a copy the current loader has not checked is not asked until the boot re-check runs" do
      indexer = nyaa!()
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})
      %{revision: revision} = Loader.fingerprint()

      sha = Cinder.DefinitionFixtures.blob_sha(bytes(nyaa_like()))

      {1, _} =
        Repo.update_all(from(r in LoadResult, where: r.blob_sha == ^sha),
          set: [revision: revision - 1]
        )

      assert {:ok, [], report} = Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{
               indexer.id => {:not_asked, {:not_supported, :definition_unchecked}}
             }

      assert requests() == []

      # The boot re-check: the stale copy is checked under the current fingerprint.
      assert [_copy] = stale = Definitions.stale_copies()
      :ok = stale |> Definitions.check_copies() |> Definitions.store_results()

      assert {:ok, [_row], report} = Native.search_tv_query("frieren", categories: [5070])
      assert outcomes(report) == %{indexer.id => :asked}
    end

    test "a copy whose stored check fails, or an indexer with no pinned copy, is not asked" do
      indexer = nyaa!()
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})
      sha = Cinder.DefinitionFixtures.blob_sha(bytes(nyaa_like()))

      {1, _} =
        Repo.update_all(from(r in LoadResult, where: r.blob_sha == ^sha),
          set: [outcome: :fails, detail: :erlang.term_to_binary(:bad_yaml)]
        )

      assert {:ok, [], report} = Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{
               indexer.id => {:not_asked, {:not_supported, :definition_fails}}
             }

      assert Native.test_indexer(indexer.id) == {:error, {:not_supported, :definition_fails}}

      {1, _} = Repo.delete_all(from(p in Pin, where: p.configured_indexer_id == ^indexer.id))

      assert {:ok, [], report} = Native.search_tv_query("frieren", categories: [5070])

      assert outcomes(report) == %{
               indexer.id => {:not_asked, {:not_supported, :definition_missing}}
             }

      assert requests() == []
    end

    test "the Test reads a gzip page as the search does" do
      indexer = nyaa!()

      route(%{
        "nyaa.test" => fn conn, _query ->
          encoded(conn, "gzip", :zlib.gzip(nyaa_page(frieren())))
        end
      })

      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
    end

    test "the Test passes on a keywordless page with a row and fails on an empty one" do
      indexer = nyaa!()

      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})
      assert {:ok, %{outcome: :success}} = Native.test_indexer(indexer.id)
      # The first path with no keywords: `q` renders blank and stays out.
      assert [{"nyaa.test", "/", %{"f" => "0", "c" => "0_0", "s" => "id", "o" => "desc"} = query}] =
               requests()

      refute Map.has_key?(query, "q")

      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page([]) end})
      assert {:ok, %{outcome: :no_rows}} = Native.test_indexer(indexer.id)
      # A page that answered is no failure in the status.
      assert status(indexer).backoff == :none
    end
  end
end
