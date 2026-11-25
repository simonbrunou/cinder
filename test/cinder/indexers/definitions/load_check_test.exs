defmodule Cinder.Indexers.Definitions.LoadCheckTest do
  # check/2 starts the real parser worker; selectors/1 reads the loaded copy only.
  use ExUnit.Case, async: true

  alias Cinder.Indexers.Definitions.LoadCheck
  alias Cinder.Indexers.Definitions.Loader

  # The smallest copy that loads with no unsupported feature, as in LoaderTest.
  @base %{
    "id" => "cindertest",
    "name" => "Cinder Test",
    "description" => "Written for Cinder's tests",
    "language" => "en-US",
    "type" => "public",
    "encoding" => "UTF-8",
    "links" => ["https://tracker.invalid/"],
    "settings" => [],
    "caps" => %{"modes" => %{"search" => ["q"]}},
    "search" => %{"rows" => %{"selector" => "tr"}, "fields" => %{"title" => %{"selector" => "a"}}}
  }

  defp yaml(map), do: Jason.encode!(map)

  defp block(name),
    do: %{"selector" => "#{name}", "remove" => "#{name}-x", "case" => %{"#{name}-k" => "1"}}

  defp field(name), do: %{"selector" => "#{name}"}

  # One distinct selector in every place the engine hands lexbor.
  @every_place %{
    "login" => %{
      "path" => "/l",
      "form" => "login-form",
      "test" => %{"path" => "/t", "selector" => "login-test"},
      "captcha" => %{"type" => "image", "selector" => "login-captcha", "input" => "c"},
      "error" => [%{"selector" => "login-error", "message" => %{"selector" => "login-message"}}],
      "selectorinputs" => %{"i" => %{"selector" => "login-input"}},
      "getselectorinputs" => %{"g" => %{"selector" => "login-get"}}
    },
    "download" => %{
      "selectors" => [%{"selector" => "dl-one"}, %{"selector" => "dl-two"}],
      "before" => %{"path" => "/b", "pathselector" => %{"selector" => "dl-before"}},
      "infohash" => %{
        "hash" => %{"selector" => "dl-hash"},
        "title" => %{"selector" => "dl-title"}
      }
    }
  }

  defp every_place(paths) do
    {:ok, definition} = Loader.load(yaml(every_place_copy(paths)))
    definition
  end

  defp every_place_copy(paths) do
    search = %{
      "paths" => paths,
      "error" => [%{"selector" => "s-error", "message" => %{"selector" => "s-message"}}],
      "rows" =>
        Map.merge(block("rows"), %{
          "dateheaders" => %{"selector" => "rows-date"},
          "count" => %{"selector" => "rows-count"}
        }),
      "fields" => %{"title" => block("f"), "size" => field("f-size")}
    }

    Map.put(Map.merge(@base, @every_place), "search", search)
  end

  # Every key path of the fixture, list indexes included, as LoaderTest walks @full.
  defp slot_paths(map, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> [path ++ [key] | slot_paths(value, path ++ [key])] end)
  end

  defp slot_paths(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      at = path ++ [Access.at(index)]
      [at | slot_paths(value, at)]
    end)
  end

  defp slot_paths(_value, _path), do: []

  @login_and_download ~w(login-form login-test login-captcha login-error login-message
                         login-input login-get dl-one dl-two dl-before dl-hash dl-title)

  describe "selectors/1" do
    test "collects every place of an HTML search, then login, then download" do
      selectors = LoadCheck.selectors(every_place([%{"path" => "/"}]))

      {search, rest} = Enum.split(selectors, length(selectors) - length(@login_and_download))
      assert rest == @login_and_download

      assert Enum.sort(search) ==
               Enum.sort(~w(rows rows-x rows-k rows-date rows-count f f-x f-k f-size s-error
                            s-message))

      assert Enum.take(search, 5) == ~w(rows rows-x rows-k rows-date rows-count)
      assert Enum.take(search, -2) == ~w(s-error s-message)
    end

    test "skips the search places when every path answers JSON or XML" do
      paths = [
        %{"path" => "/a", "response" => %{"type" => "json"}},
        %{"path" => "/b", "response" => %{"type" => "xml"}}
      ]

      assert LoadCheck.selectors(every_place(paths)) == @login_and_download
    end

    test "keeps the search places when any path answers HTML" do
      for html <- [%{"path" => "/c"}, %{"path" => "/c", "response" => %{"type" => "html"}}] do
        paths = [%{"path" => "/a", "response" => %{"type" => "json"}}, html]
        assert "rows" in LoadCheck.selectors(every_place(paths)), inspect(html)
      end
    end

    # docs/agents/testing.md: a reader of untrusted input never raises. `check/2` hands each
    # selector to `Selector.compile/2`, which takes only a binary.
    test "answers only binaries and raises on none of seven value shapes in any slot" do
      copy = every_place_copy([%{"path" => "/"}])

      problems =
        for(
          path <- slot_paths(copy, []),
          value <- [nil, "x", ["x"], [nil], [%{}], %{}, %{"a" => nil}],
          do: {path, value}
        )
        |> Task.async_stream(fn {path, value} ->
          try do
            case Loader.load(yaml(put_in(copy, path, value))) do
              {:ok, definition} ->
                selectors = LoadCheck.selectors(definition)
                if Enum.all?(selectors, &is_binary/1), do: nil, else: {path, value, selectors}

              {:error, _reason} ->
                nil
            end
          rescue
            error -> {path, value, Exception.message(error)}
          end
        end)
        |> Enum.flat_map(fn {:ok, result} -> List.wrap(result) end)

      assert problems == []
    end

    test "lists a selector used twice once" do
      {:ok, definition} =
        @base
        |> put_in(["search", "fields"], %{
          "a" => %{"selector" => "tr"},
          "b" => %{"selector" => "a"}
        })
        |> yaml()
        |> Loader.load()

      assert LoadCheck.selectors(definition) == ["tr", "a"]
    end
  end

  describe "check/2" do
    test "lists every code it adds, in its order" do
      assert LoadCheck.codes() ==
               Enum.map(
                 ~w(comment escape structure template refused crash timeout memory
                    output_too_large)a,
                 &{:selector, &1}
               )
    end

    test "adds nothing to a copy whose selectors all pass" do
      assert {:ok, %{unsupported: []}} = LoadCheck.check(yaml(@base))
      # Its login and download add the loader's codes, and its selectors none.
      bytes = yaml(every_place_copy([%{"path" => "/"}]))
      assert {:ok, %{unsupported: [_code | _more] = codes}} = Loader.load(bytes)
      assert {:ok, %{unsupported: ^codes}} = LoadCheck.check(bytes)
    end

    test "answers the loader's answer otherwise unchanged" do
      bytes = yaml(@base)
      assert LoadCheck.check(bytes) == Loader.load(bytes)
    end

    test "passes a copy that fails to load through as the loader answered" do
      bytes = yaml(Map.delete(@base, "id"))
      assert {:error, _reason} = Loader.load(bytes)
      assert LoadCheck.check(bytes) == Loader.load(bytes)
    end

    test "adds each selector problem once, after the loader's codes, in its order" do
      fields = %{
        "a" => %{"selector" => ~S|[id!="x"]|},
        "b" => %{"selector" => ~S|a[href*="{{ .Config.x }}"]|},
        "c" => %{"selector" => "td /* x */"},
        "d" => %{"selector" => ~S|img[src$=\"x\"]|},
        "e" => %{"selector" => "td:has()"},
        "f" => %{"selector" => "td /* y */"},
        "g" => %{"selector" => "td:has(b[border=1])"}
      }

      copy = @base |> put_in(["search", "fields"], fields) |> put_in(["requestDelay"], 2)

      assert {:ok, %{unsupported: unsupported}} = LoadCheck.check(yaml(copy))

      assert unsupported == [
               :request_delay,
               {:selector, :comment},
               {:selector, :escape},
               {:selector, :structure},
               {:selector, :template},
               {:selector, :refused}
             ]
    end

    test "reads td:has(b[border=1]) as refused: its part runs before the whole" do
      copy = put_in(@base, ["search", "rows", "selector"], "td:has(b[border=1])")
      assert {:ok, %{unsupported: [{:selector, :refused}]}} = LoadCheck.check(yaml(copy))
    end

    test "reads [id!=\"x\"] alone as refused" do
      copy = put_in(@base, ["search", "rows", "selector"], ~S|[id!="x"]|)
      assert {:ok, %{unsupported: [{:selector, :refused}]}} = LoadCheck.check(yaml(copy))
    end

    test "starts no worker for a copy with no selector to check" do
      copy =
        put_in(@base, ["search", "paths"], [%{"path" => "/", "response" => %{"type" => "json"}}])

      assert {:ok, %{unsupported: unsupported}} = LoadCheck.check(yaml(copy), max_memory_bytes: 1)
      refute Enum.any?(unsupported, &match?({:selector, _code}, &1))
    end

    test "starts no worker when the gate refuses every selector" do
      copy = put_in(@base, ["search", "fields"], %{"a" => %{"selector" => "a /* x */"}})
      copy = put_in(copy, ["search", "rows", "selector"], "tr /* x */")

      assert {:ok, %{unsupported: [{:selector, :comment}]}} =
               LoadCheck.check(yaml(copy), max_memory_bytes: 1)
    end

    test "reads a worker failure as one code for the whole copy" do
      assert {:ok, %{unsupported: [{:selector, :memory}]}} =
               LoadCheck.check(yaml(@base), max_memory_bytes: 1)
    end

    test "drops the gate's codes of a copy whose worker fails" do
      copy = put_in(@base, ["search", "rows", "selector"], "td /* x */")
      assert {:ok, %{unsupported: [{:selector, :comment}]}} = LoadCheck.check(yaml(copy))

      assert {:ok, %{unsupported: [{:selector, :memory}]}} =
               LoadCheck.check(yaml(copy), max_memory_bytes: 1)
    end
  end
end
