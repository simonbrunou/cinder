defmodule Cinder.Acquisition.Indexer.CardigannRequestKeysTest do
  # The search request keys of #1679 (headers, `$raw`, `allowEmptyInputs`, POST paths, path
  # categories, per-path redirects, the legacy `search.path`, and the keys read and ignored),
  # through the real `Cinder.Acquisition.IndexerSource.Native`, on Nyaa-shaped definitions
  # written for Cinder (`Cinder.CardigannFixtures`), behind the `Cinder.CardigannStub` plug.
  #
  # Not async: Native's clock is Native's global config.
  use Cinder.DataCase, async: false

  import Cinder.CardigannFixtures

  alias Cinder.Acquisition.IndexerSource.{Native, Report}
  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.ConfigCase

  @now ~U[2026-11-26 12:00:00Z]
  @key "k3y-Synthetic+value"

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  defp outcomes(%Report{indexers: indexers}),
    do: Map.new(indexers, fn {{"native", id}, %{outcome: outcome}} -> {id, outcome} end)

  defp search_answer({:ok, rows, report}), do: {rows, outcomes(report)}
  defp search_answer({:error, {:no_indexer_answered, report}}), do: {[], outcomes(report)}

  defp frieren(n \\ 1) do
    for i <- 1..n//1 do
      %{
        id: i,
        title: "[Group] Frieren - 0#{i} [1080p]",
        magnet: "magnet:?xt=urn:btih:#{String.duplicate(Integer.to_string(rem(i, 10)), 40)}",
        size: "1.4 GiB",
        date: "2026-11-25 10:30",
        cat: "1_2"
      }
    end
  end

  # Every request the stub received so far, with its headers, in order. Leaves the
  # `:cardigann_wire` messages for `wire/0`.
  defp sent do
    receive do
      {:cardigann_request, host, path, _query, headers} ->
        [%{host: host, path: path, headers: Map.new(headers)} | sent()]
    after
      0 -> []
    end
  end

  defp telemetry do
    receive do
      {:telemetry, event, measure, meta} -> [{event, measure, meta} | telemetry()]
    after
      0 -> []
    end
  end

  defp nyaa!(edit, secrets \\ %{}) do
    [indexer] = setup!([{"nyaa.yml", nyaa_like(edit)}], [{"nyaa.yml", nyaa_base(), secrets}])
    indexer
  end

  defp paths(definition, paths), do: put_in(definition, ["search", "paths"], paths)

  defp with_apikey(definition) do
    settings =
      definition["settings"] ++
        [%{"name" => "apikey", "type" => "password", "label" => "API key"}]

    Map.put(definition, "settings", settings)
  end

  defp headers(definition, headers),
    do: put_in(definition, ["search", "headers"], obj(headers))

  describe "search.headers" do
    test "each header's first value is rendered and sent to the own host, and dropped on a hop to another" do
      edit = fn definition ->
        definition
        |> with_apikey()
        |> Map.put("followredirect", "true")
        |> headers([
          {"Authorization", ["Bearer {{ .Config.apikey }}", "ignored"]},
          {"X-Search", ["{{ .Keywords }}"]},
          {"Content-Length", ["12"]},
          {"X-None", []}
        ])
        |> paths([%{"path" => "/", "inputs" => obj([{"q", "{{ .Keywords }}"}])}])
      end

      indexer = nyaa!(edit, %{"apikey" => @key})

      route(%{
        "nyaa.test" => fn conn, _query ->
          if conn.request_path == "/",
            do: {:redirect, 302, "https://elsewhere.test/results"},
            else: nyaa_page(frieren())
        end,
        "elsewhere.test" => fn _conn, _query -> nyaa_page(frieren()) end
      })

      assert {[_row], outcomes} =
               search_answer(Native.search_tv_query("frieren", categories: [5070]))

      assert outcomes == %{indexer.id => :asked}
      assert [own, other] = sent()
      assert own.host == "nyaa.test"
      assert own.headers["authorization"] == "Bearer " <> @key
      assert own.headers["x-search"] == "frieren"
      refute Map.has_key?(own.headers, "x-none")
      # Cinder writes its own framing headers: the definition's Content-Length is not sent.
      refute own.headers["content-length"] == "12"

      assert other.host == "elsewhere.test"
      refute Map.has_key?(other.headers, "authorization")
      refute Map.has_key?(other.headers, "x-search")
    end

    test "a path on another host gets no header, and the own host still does" do
      edit = fn definition ->
        definition
        |> headers([{"X-Api-Key", ["{{ .Config.sort }}"]}])
        |> paths([
          %{"path" => "/", "inputs" => obj([{"q", "{{ .Keywords }}"}])},
          # A host the keywords fill: no credential host, since the definition cannot name it.
          %{
            "path" => "https://{{ .Keywords }}.mirror.test/",
            "inputs" => obj([{"q", "{{ .Keywords }}"}])
          }
        ])
      end

      nyaa!(edit)

      route(%{
        "nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end,
        "frieren.mirror.test" => fn _conn, _query -> nyaa_page(frieren(2)) end
      })

      assert {:ok, _rows, _report} = Native.search_tv_query("frieren", categories: [5070])
      assert [own, mirror] = sent()
      assert own.headers["x-api-key"] == "id"
      assert mirror.host == "frieren.mirror.test"
      refute Map.has_key?(mirror.headers, "x-api-key")
    end

    test "a header name that is not a token or a value with a line break sends nothing" do
      for header <- [{"Bad Name", ["x"]}, {"X-Split", ["a\r\nX-Other: b"]}, {"X-Utf8", ["é"]}] do
        Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)
        indexer = nyaa!(&headers(&1, [header]))
        route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

        assert {[], outcomes} =
                 search_answer(Native.search_tv_query("frieren", categories: [5070]))

        assert outcomes == %{indexer.id => {:failed, :definition_error}}
        assert sent() == []
      end
    end

    test "a 429 that echoes the key and a transport failure leave no trace of it" do
      edit = fn definition ->
        definition
        |> with_apikey()
        |> headers([{"Authorization", ["Bearer {{ .Config.apikey }}"]}])
      end

      indexer = nyaa!(edit, %{"apikey" => @key})
      test_pid = self()
      id = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        id,
        [[:cinder, :http, :request_task], [:cinder, :http, :request]],
        fn event, measure, meta, _config ->
          send(test_pid, {:telemetry, event, measure, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      for {answer, outcome} <- [
            {{429, "<html>slow down, #{@key}</html>"},
             &match?({:failed, {:limit, %DateTime{}}}, &1)},
            {{:transport, :econnrefused}, &(&1 == {:failed, :connection_refused})}
          ] do
        Repo.delete_all(IndexerStatus)
        route(%{"nyaa.test" => fn _conn, _query -> answer end})

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(self(), {:answer, Native.search_tv_query("frieren", categories: [5070])})
          end)

        assert_received {:answer, answer}
        assert {[], outcomes} = search_answer(answer)
        assert outcome.(outcomes[indexer.id])

        # The positive control: the stub got the key in the header.
        assert [%{headers: %{"authorization" => "Bearer " <> @key}} | _] = sent()
        refute inspect(answer) =~ "k3y"
        refute log =~ "k3y"

        # Both request events fired, and neither carries the key.
        events = telemetry()
        assert Enum.any?(events, &match?({[:cinder, :http, :request_task], _, _}, &1))
        assert Enum.any?(events, &match?({[:cinder, :http, :request], _, _}, &1))
        refute inspect(events) =~ "k3y"
      end
    end
  end

  describe "inputs" do
    test "a $raw input adds its pairs in order, skips an empty key and encodes a value twice" do
      raw = "{{ range .Categories }}cat{{.}}=1&{{end}}=skipped&kw={{ .Keywords }}&empty="

      nyaa!(fn definition ->
        paths(definition, [%{"path" => "/", "inputs" => obj([{"$raw", raw}, {"q", "x"}])}])
      end)

      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      assert {:ok, _rows, _report} =
               Native.search_tv_query("Spider-Man (2002)! ~x*", categories: [5070])

      # The search inputs first, then the path's. `.Categories` is the call's mapped site ids.
      # `.Keywords` reads `Spider-Man+(2002)!+%7Ex*` after the template's encoding, .NET's
      # `WebUtility.UrlEncode`, and is encoded again as Prowlarr's `GetQueryString` does
      # (`WebUtility.UrlEncodeToBytes` on the UTF-8 bytes). The `kw` value ran in `dotnet fsi`
      # (SDK 8.0.427, .NET 8.0.33) on 2026-11-27.
      assert [{"nyaa.test", "GET", "/", query, ""}] = wire()

      assert query ==
               "f=0&c=0_0&s=id&o=desc&cat1_0=1&cat1_2=1&kw=Spider-Man%2B(2002)!%2B%257Ex*" <>
                 "&empty=&q=x"
    end

    test "allowEmptyInputs sends a blank input as name=, and without it the input stays out" do
      blank = "{{ if .Keywords }}{{ else }}x{{ end }}"

      edit = fn allow ->
        fn definition ->
          definition
          |> paths([%{"path" => "/", "inputs" => obj([{"q", "{{ .Keywords }}"}, {"e", blank}])}])
          |> then(&if(allow, do: put_in(&1, ["search", "allowEmptyInputs"], true), else: &1))
        end
      end

      for {allow, expected} <- [
            {true, "f=0&c=0_0&s=id&o=desc&q=frieren&e="},
            {false, "f=0&c=0_0&s=id&o=desc&q=frieren"}
          ] do
        Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)
        nyaa!(edit.(allow))
        route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

        assert {:ok, _rows, _report} = Native.search_tv_query("frieren", categories: [5070])
        assert [{"nyaa.test", "GET", "/", ^expected, ""}] = wire()
      end
    end
  end

  describe "POST paths" do
    # The windows-1251 body is `Cinder.Acquisition.Indexer.Cardigann.QueryTest`'s: Req's test step
    # decodes a form body as UTF-8 before the stub sees it.
    test "the inputs and $raw pairs go in a form body, and two POST paths with one URL both run" do
      post = %{
        "path" => "/search",
        "method" => "POST",
        "inputs" =>
          obj([{"q", "{{ .Keywords }}"}, {"$raw", "{{ range .Categories }}c={{.}}&{{end}}"}])
      }

      indexer =
        nyaa!(fn definition ->
          paths(definition, [post, post])
        end)

      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      assert {:ok, _rows, report} = Native.search_tv_query("Dune é", categories: [5070])
      assert outcomes(report) == %{indexer.id => :asked}

      assert [headers, _second] = sent()
      assert headers.headers["content-type"] == "application/x-www-form-urlencoded"

      body = "f=0&c=0_0&s=id&o=desc&q=Dune%20%C3%A9&c=1_0&c=1_2"

      assert [
               {"nyaa.test", "POST", "/search", "", ^body},
               {"nyaa.test", "POST", "/search", "", ^body}
             ] = wire()
    end

    test "a GET to a URL a POST path already sends is left out, and a POST after that GET goes" do
      # With no inputs, the GET's URL is the POST's: Prowlarr's list of URLs holds both.
      post = %{"path" => "/search", "method" => "post"}
      get = %{"path" => "/search"}

      for {order, expected} <- [
            {[post, get], [{"nyaa.test", "POST", "/search", "", ""}]},
            {[get, post],
             [{"nyaa.test", "GET", "/search", "", ""}, {"nyaa.test", "POST", "/search", "", ""}]}
          ] do
        Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)
        indexer = nyaa!(&(&1 |> paths(order) |> put_in(["search", "inputs"], %{})))
        route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

        assert {:ok, _rows, report} = Native.search_tv_query("Dune", categories: [5070])
        assert outcomes(report) == %{indexer.id => :asked}
        assert wire() == expected
      end
    end

    test "a 303 turns a POST into a GET with no body, and a 307 keeps the method and body" do
      post = %{
        "path" => "/search",
        "method" => "post",
        "inputs" => obj([{"q", "{{ .Keywords }}"}])
      }

      for {status, method, body} <- [
            {303, "GET", ""},
            {307, "POST", "f=0&c=0_0&s=id&o=desc&q=frieren"}
          ] do
        Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)

        nyaa!(fn definition ->
          definition |> Map.put("followredirect", "true") |> paths([post])
        end)

        route(%{
          "nyaa.test" => fn conn, _query ->
            if conn.request_path == "/search",
              do: {:redirect, status, "/results"},
              else: nyaa_page(frieren())
          end
        })

        assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])

        assert [{_, "POST", "/search", "", _}, {_, ^method, "/results", "", ^body}] = wire()
      end
    end

    test "a POST body holding the secret is not sent off the credential hosts" do
      edit = fn definition ->
        definition
        |> with_apikey()
        |> paths([
          %{
            "path" => "https://{{ .Keywords }}.mirror.test/",
            "method" => "post",
            "inputs" => obj([{"k", "{{ .Config.apikey }}"}])
          }
        ])
      end

      indexer = nyaa!(edit, %{"apikey" => @key})
      route(%{"frieren.mirror.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      assert {[], outcomes} =
               search_answer(Native.search_tv_query("frieren", categories: [5070]))

      assert outcomes == %{indexer.id => {:failed, :secret_host}}
      assert wire() == []
    end
  end

  describe "a $raw value holding a secret" do
    test "is not sent off the credential hosts in its twice-encoded form" do
      secret = "p@ss word"

      edit = fn definition ->
        definition
        |> with_apikey()
        |> paths([
          # A host no credential host matches: its template leaves it unknown at load.
          %{
            "path" => "https://mirror{{ if .Keywords }}{{ else }}x{{ end }}.test/",
            "inputs" => obj([{"$raw", "kw={{ .Keywords }}"}])
          }
        ])
      end

      indexer = nyaa!(edit, %{"apikey" => secret})
      route(%{"mirror.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      assert {[], outcomes} = search_answer(Native.search_tv_query(secret, categories: [5070]))
      assert outcomes == %{indexer.id => {:failed, :secret_host}}
      assert wire() == []
    end
  end

  describe "path categories" do
    defp category_paths(definition) do
      raw = "{{ range .Categories }}c={{.}}&{{end}}"

      paths(definition, [
        %{"path" => "/a", "categories" => ["1_2"], "inputs" => obj([{"$raw", raw}])},
        %{"path" => "/b", "categories" => ["!", "1_2"], "inputs" => obj([{"$raw", raw}])}
      ])
    end

    test "a path runs when the call's site ids meet its list, a \"!\" path when they do not" do
      indexer = nyaa!(&category_paths/1)
      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      # TV/Anime maps to 1_0 and 1_2: only /a runs, with `.Categories` holding the meet.
      assert {:ok, _rows, _report} = Native.search_tv_query("frieren", categories: [5070])
      assert [{_, "GET", "/a", "f=0&c=0_0&s=id&o=desc&c=1_2", ""}] = wire()

      # Audio maps to 2_0 only: only /b runs, and its `.Categories` meets nothing.
      assert {:ok, _rows, report} = Native.search_tv_query("frieren", categories: [3000])
      assert outcomes(report) == %{indexer.id => :asked}
      assert [{_, "GET", "/b", "f=0&c=0_0&s=id&o=desc", ""}] = wire()
    end

    test "a query whose every path is skipped is not asked" do
      indexer =
        nyaa!(fn definition ->
          paths(definition, [%{"path" => "/a", "categories" => ["1_2"]}])
        end)

      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      assert {[], outcomes} =
               search_answer(Native.search_tv_query("frieren", categories: [3000]))

      assert outcomes == %{indexer.id => {:not_asked, :caps}}
      assert wire() == []
    end
  end

  describe "redirects, the legacy path and the ignored keys" do
    test "a path's followredirect follows a 302 on that path only" do
      indexer =
        nyaa!(fn definition ->
          paths(definition, [
            %{"path" => "/a", "followredirect" => true},
            %{"path" => "/b"}
          ])
        end)

      route(%{
        "nyaa.test" => fn conn, _query ->
          case conn.request_path do
            "/r" -> nyaa_page(frieren())
            _path -> {:redirect, 302, "/r"}
          end
        end
      })

      # Native drops the rows of /a since no indexer was asked (#1738).
      assert {[], outcomes} =
               search_answer(Native.search_tv_query("frieren", categories: [5070]))

      assert outcomes == %{indexer.id => {:failed, {:http_status, 302}}}
      assert [{_, _, "/a", _, _}, {_, _, "/r", _, _}, {_, _, "/b", _, _}] = wire()
    end

    test "search.path alone searches as one path with the search inputs" do
      nyaa!(fn definition ->
        definition
        |> Map.update!("search", &Map.delete(&1, "paths"))
        |> put_in(["search", "path"], "/legacy")
      end)

      route(%{"nyaa.test" => fn _conn, _query -> nyaa_page(frieren()) end})

      assert {:ok, [_row], _report} = Native.search_tv_query("frieren", categories: [5070])
      assert [{"nyaa.test", "GET", "/legacy", "f=0&c=0_0&s=id&o=desc", ""}] = wire()
    end

    test "allowtvsearchimdb and search.error change no request and no row" do
      ignored = fn definition ->
        definition
        |> put_in(["caps", "allowtvsearchimdb"], true)
        |> put_in(["search", "error"], [%{"selector" => "div.error"}])
      end

      answers =
        for edit <- [& &1, ignored] do
          Repo.delete_all(Cinder.Indexers.ConfiguredIndexer)
          nyaa!(edit)

          route(%{
            "nyaa.test" => fn _conn, _query ->
              String.replace(
                nyaa_page(frieren(2)),
                "<body>",
                ~s(<body><div class="error">x</div>)
              )
            end
          })

          assert {:ok, rows, _report} = Native.search_tv_query("frieren", categories: [5070])
          {Enum.map(rows, &{&1.title, &1.download_url}), wire()}
        end

      assert [{[_, _], [_ | _]} = plain, with_keys] = answers
      assert plain == with_keys
    end
  end
end
