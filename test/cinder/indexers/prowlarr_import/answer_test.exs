defmodule Cinder.Indexers.ProwlarrImport.AnswerTest do
  # The strict reader of Prowlarr's three answers (#1673): an answer of a shape it does not know
  # is refused as a whole, never read as fewer indexers.
  use ExUnit.Case, async: true

  import Cinder.ProwlarrApiFixtures

  alias Cinder.Indexers.ProwlarrImport.Answer

  @indexer_keys ~w(id name implementation protocol enable priority appProfileId tags fields)

  describe "indexers/1" do
    test "reads each indexer's keys, the generic fields and no other field" do
      assert {:ok, [read]} =
               Answer.indexers([newznab(4, name: "NZBgeek", priority: 7, tags: [2])])

      assert read == %{
               id: 4,
               name: "NZBgeek",
               implementation: "Newznab",
               protocol: "usenet",
               enable: true,
               priority: 7,
               tags: [2],
               app_profile_id: 1,
               fields: %{
                 "baseUrl" => "https://newznab4.example",
                 "apiPath" => "/api",
                 "apiKey" => masked(),
                 "additionalParameters" => nil
               },
               not_carried: []
             }
    end

    test "an empty list is no indexer" do
      assert {:ok, []} = Answer.indexers([])
    end

    for key <- @indexer_keys do
      @key key

      test "an indexer without #{key} refuses the answer, alone or beside a valid one" do
        renamed = newznab(2) |> Map.delete(@key) |> Map.put(@key <> "Renamed", newznab(2)[@key])

        assert {:error, :unexpected_response} = Answer.indexers([renamed])
        assert {:error, :unexpected_response} = Answer.indexers([newznab(1), renamed])
        assert {:error, :unexpected_response} = Answer.indexers([renamed, newznab(1)])
      end
    end

    for {key, values} <- [
          {"id", [0, -1, "1", 1.0, nil]},
          {"name", [nil, 3, ["a"]]},
          {"implementation", [nil, 3]},
          {"protocol", ["Usenet", "nzb", nil, 1]},
          {"enable", ["true", 1, nil]},
          {"priority", ["25", 25.5, nil]},
          {"appProfileId", ["1", nil]},
          {"tags", [nil, "1", [1, "2"], %{}]},
          {"fields", [nil, %{}, "x", [1], [%{"value" => "x"}], [%{"name" => 3}]]}
        ] do
      @key key
      @values values

      test "a #{key} of the wrong type refuses the answer" do
        for value <- @values do
          assert {value, {:error, :unexpected_response}} ==
                   {value, Answer.indexers([newznab(1), Map.put(newznab(2), @key, value)])}
        end
      end
    end

    test "a body that is not a list, or an entry that is not a map, refuses the answer" do
      for body <- [
            nil,
            %{},
            "[]",
            3,
            %{"records" => [newznab(1)]},
            [newznab(1), nil],
            [[newznab(1)]]
          ] do
        assert {body, {:error, :unexpected_response}} == {body, Answer.indexers(body)}
      end
    end

    test "a field without a text name, beside the generic ones, refuses the answer" do
      for extra <- [%{"name" => 3, "value" => "x"}, %{"label" => "x", "value" => "x"}, "x", nil] do
        indexer = Map.update!(newznab(1), "fields", &(&1 ++ [extra]))
        assert {extra, {:error, :unexpected_response}} == {extra, Answer.indexers([indexer])}
      end
    end

    test "two indexers with one id refuse the answer" do
      assert {:error, :unexpected_response} =
               Answer.indexers([newznab(1), torznab(1, name: "Other")])
    end

    test "two fields with one name refuse the answer" do
      twice =
        Map.update!(newznab(1), "fields", &(&1 ++ [field("baseUrl", "https://twice.example")]))

      assert {:error, :unexpected_response} = Answer.indexers([twice])
    end

    for name <- ~w(baseUrl apiPath apiKey additionalParameters) do
      @name name

      test "a Newznab or Torznab indexer without the #{name} field refuses the answer, alone or beside a valid one" do
        for indexer <- [newznab(2), torznab(2)] do
          missing =
            Map.update!(indexer, "fields", &Enum.reject(&1, fn f -> f["name"] == @name end))

          assert {:error, :unexpected_response} = Answer.indexers([missing])
          assert {:error, :unexpected_response} = Answer.indexers([newznab(1), missing])
          assert {:error, :unexpected_response} = Answer.indexers([missing, torznab(3)])
        end
      end

      test "a #{name} value that is not text refuses the answer" do
        for value <- [3, true, ["x"], %{"x" => 1}] do
          wrong =
            Map.update!(newznab(1), "fields", fn fields ->
              Enum.map(fields, fn
                %{"name" => @name} = f -> Map.put(f, "value", value)
                f -> f
              end)
            end)

          assert {value, {:error, :unexpected_response}} == {value, Answer.indexers([wrong])}
        end
      end
    end

    test "a field value of JSON null reads as unset" do
      nulled =
        Map.update!(newznab(1), "fields", fn fields ->
          Enum.map(fields, fn
            %{"name" => "apiKey"} = f -> Map.put(f, "value", nil)
            %{"name" => "baseSettings.queryLimit"} = f -> Map.put(f, "value", nil)
            f -> f
          end)
        end)

      assert {:ok, [%{fields: %{"apiKey" => nil}, not_carried: []}]} = Answer.indexers([nulled])
    end

    test "a Cardigann or C# indexer needs no generic field" do
      assert {:ok, [%{fields: %{"baseUrl" => nil}}, %{fields: fields}]} =
               Answer.indexers([cardigann(1, "nyaasi"), csharp(2, "BroadcastheNet")])

      assert fields == %{"baseUrl" => nil, "apiKey" => masked()}
    end

    test "each set limit, query timeout or seed setting is a not-carried note, listed once" do
      set =
        Map.update!(torznab(1), "fields", fn fields ->
          fields ++
            [
              field("torrentBaseSettings.appMinimumSeeders", 3),
              field("torrentBaseSettings.seedRatio", 1.5),
              field("torrentBaseSettings.seedTime", 60),
              field("torrentBaseSettings.packSeedTime", nil)
            ]
        end)
        |> put_value("baseSettings.queryLimit", 100)
        |> put_value("baseSettings.grabLimit", 5)
        |> put_value("baseSettings.queryTimeout", 30)

      assert {:ok, [%{not_carried: notes}]} = Answer.indexers([set])
      assert notes == [:grab_limit, :query_limit, :query_timeout, :seed_settings]

      for {name, note} <- [
            {"baseSettings.queryLimit", :query_limit},
            {"baseSettings.grabLimit", :grab_limit},
            {"baseSettings.queryTimeout", :query_timeout}
          ] do
        assert {:ok, [%{not_carried: [^note]}]} =
                 Answer.indexers([put_value(newznab(1), name, 1)])
      end

      for name <- ~w(appMinimumSeeders seedRatio seedTime packSeedTime) do
        one =
          Map.update!(torznab(1), "fields", &(&1 ++ [field("torrentBaseSettings." <> name, 2)]))

        assert {name, {:ok, [%{not_carried: [:seed_settings]}]}} ==
                 {name, Answer.indexers([one]) |> only_notes()}
      end
    end

    test "Prowlarr's limitsUnit, always set, is no note" do
      assert {:ok, [%{not_carried: []}]} = Answer.indexers([newznab(1)])
    end

    test "a limit or seed setting that is not a number refuses the answer" do
      for value <- ["100", true, [1]] do
        assert {value, {:error, :unexpected_response}} ==
                 {value,
                  Answer.indexers([put_value(newznab(1), "baseSettings.queryLimit", value)])}
      end
    end
  end

  describe "proxies/1" do
    test "reads each proxy's id, implementation and tags" do
      assert {:ok, [%{id: 1, implementation: "FlareSolverr", tags: [1, 2]}]} =
               Answer.proxies([proxy(1, "FlareSolverr", [1, 2])])
    end

    for key <- ~w(id implementation tags) do
      @key key

      test "a proxy without #{key} refuses the answer, alone or beside a valid one" do
        renamed =
          proxy(2, "Http", [2])
          |> Map.delete(@key)
          |> Map.put(@key <> "Renamed", proxy(2, "Http", [2])[@key])

        assert {:error, :unexpected_response} = Answer.proxies([renamed])
        assert {:error, :unexpected_response} = Answer.proxies([proxy(1, "Http", [1]), renamed])
        assert {:error, :unexpected_response} = Answer.proxies([renamed, proxy(3, "Socks5", [3])])
      end
    end

    test "a wrong type or a body that is not a list refuses the answer" do
      for body <- [
            nil,
            %{},
            [proxy(1, "Http", [1]) |> Map.put("id", "1")],
            [proxy(1, "Http", [1]) |> Map.put("implementation", nil)],
            [proxy(1, "Http", ["1"])],
            [proxy(1, "Http", nil)],
            [nil]
          ] do
        assert {body, {:error, :unexpected_response}} == {body, Answer.proxies(body)}
      end
    end
  end

  describe "global_proxy/1" do
    test "keeps only whether the global proxy is on" do
      assert {:ok, true} = Answer.global_proxy(host(true))
      assert {:ok, false} = Answer.global_proxy(host(false))
    end

    test "a host config without a boolean proxyEnabled refuses the answer" do
      for body <- [
            nil,
            [],
            Map.delete(host(true), "proxyEnabled"),
            Map.put(host(true), "proxyEnabled", "true"),
            Map.put(host(true), "proxyEnabled", nil)
          ] do
        assert {:error, :unexpected_response} = Answer.global_proxy(body)
      end
    end
  end

  # docs/agents/testing.md: an untrusted reader never raises. Each slot of a full fixture of each
  # answer gets each of seven wrong shapes in turn; every read answers, and a shape that cannot
  # be the slot's refuses the answer.
  @shapes [nil, "x", ["x"], [nil], [%{}], %{}, %{"a" => nil}]

  describe "every slot, seven wrong shapes" do
    test "no read raises" do
      full_indexers = [
        newznab(1, additional_parameters: "&cat=2000")
        |> put_value("baseSettings.queryLimit", 100),
        torznab(2, tags: [1])
        |> Map.update!("fields", &(&1 ++ [field("torrentBaseSettings.seedRatio", 1.5)])),
        cardigann(3, "nyaasi"),
        csharp(4, "BroadcastheNet")
      ]

      cases =
        for(
          {reader, body} <- [
            {&Answer.indexers/1, full_indexers},
            {&Answer.proxies/1, [proxy(1, "FlareSolverr", [1]), proxy(2, "Http", [2, 3])]},
            {&Answer.global_proxy/1, host(true)}
          ],
          path <- slot_paths(body, []),
          value <- @shapes,
          do: {reader, body, path, value}
        )

      raised =
        cases
        |> Task.async_stream(fn {reader, body, path, value} ->
          try do
            case reader.(put_in(body, path, value)) do
              {:ok, _read} -> nil
              {:error, :unexpected_response} -> nil
              other -> {path, value, {:answered, other}}
            end
          rescue
            error -> {path, value, Exception.message(error)}
          end
        end)
        |> Enum.flat_map(fn {:ok, result} -> List.wrap(result) end)

      assert length(cases) > 1_000
      assert raised == []
    end

    test "a wrong shape in any slot the reader keeps refuses the answer" do
      body = [newznab(1), torznab(2, tags: [1])]

      for slot <- @indexer_keys, value <- @shapes, not valid_for?(slot, value) do
        assert {slot, value, {:error, :unexpected_response}} ==
                 {slot, value,
                  Answer.indexers(List.update_at(body, 0, &Map.put(&1, slot, value)))}
      end
    end
  end

  # Of the seven shapes, only "x" is a valid value, and only for the two free-text slots.
  defp valid_for?(slot, "x") when slot in ~w(name implementation), do: true
  defp valid_for?(_slot, _value), do: false

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

  defp put_value(indexer, name, value) do
    Map.update!(indexer, "fields", fn fields ->
      Enum.map(fields, fn
        %{"name" => ^name} = f -> Map.put(f, "value", value)
        f -> f
      end)
    end)
  end

  defp only_notes({:ok, [%{not_carried: notes}]}), do: {:ok, [%{not_carried: notes}]}
  defp only_notes(other), do: other
end
