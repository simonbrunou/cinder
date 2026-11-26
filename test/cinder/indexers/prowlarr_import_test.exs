defmodule Cinder.Indexers.ProwlarrImportTest do
  # The Prowlarr import's preview and commit (#1673), against `Cinder.Indexers.ProwlarrApiMock`
  # answering as `Cinder.ProwlarrApiFixtures` shapes Prowlarr 3.1.0.5799's answers.
  #
  # Not async: the Prowlarr source's config, the import lock, the Test runner and the adapter map
  # are app-wide, and the Test tasks reach the database through the shared sandbox.
  use Cinder.DataCase, async: false

  import Ecto.Query
  import Mox
  import Cinder.ProwlarrApiFixtures
  import Cinder.TestRunnerHelpers

  alias Cinder.Acquisition.IndexerAdapterMock
  alias Cinder.Acquisition.IndexerSource.Native.TestRunner
  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.Audit.AdminAudit
  alias Cinder.ConfigCase
  alias Cinder.Indexers
  alias Cinder.Indexers.{ConfiguredIndexer, ProwlarrApiMock, ProwlarrImport}
  alias Cinder.Indexers.ProwlarrImport.{Preview, Row}

  @prowlarr_url "https://media.example.com/prowlarr"
  @prowlarr_key "stored-prowlarr-key-3e9a"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    ConfigCase.put_config(Prowlarr, base_url: @prowlarr_url, api_key: @prowlarr_key)
    block_tests()

    ConfigCase.put_env(:indexer_adapters, %{
      newznab: IndexerAdapterMock,
      torznab: IndexerAdapterMock
    })

    stop_tests_on_exit()
    :ok = TestRunner.subscribe()
    :ok
  end

  defp preview! do
    assert {:ok, %Preview{} = preview} = ProwlarrImport.preview()
    preview
  end

  defp row(%Preview{rows: rows}, id), do: Enum.find(rows, &(&1.prowlarr_id == id))

  defp tick(id, name, extra \\ %{}),
    do: {id, Map.merge(%{ticked: true, name: name, via_prowlarr: false, secrets: %{}}, extra)}

  defp configured, do: Repo.all(from c in ConfiguredIndexer, order_by: c.id)

  defp audits, do: Repo.all(from a in AdminAudit, where: a.action == "import_prowlarr_indexers")

  # Everything the preview holds, as `inspect/1` shows it, lists and strings uncut.
  defp shown(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  describe "preview/0" do
    test "prod's shape: three direct Newznab rows with masked keys and three held Cardigann rows" do
      stub_api(
        [
          newznab(1, name: "NZBgeek"),
          newznab(2, name: "altHUB"),
          newznab(3, name: "NinjaCentral", api_key: "clear-indexer-key-71b0"),
          cardigann(4, "nyaasi", name: "Nyaa.si"),
          cardigann(5, "torrent9", name: "Torrent9"),
          cardigann(6, "1337x", name: "1337x", tags: [1])
        ],
        [proxy(1, "FlareSolverr", [1])],
        host(false)
      )

      preview = preview!()

      assert for(r <- preview.rows, do: {r.prowlarr_id, r.state, r.type, r.key, r.tickable}) ==
               [
                 {1, :direct, :newznab, :masked, true},
                 {2, :direct, :newznab, :masked, true},
                 {3, :direct, :newznab, :masked, true},
                 {4, :held, nil, nil, false},
                 {5, :held, nil, nil, false},
                 {6, :held, nil, nil, false}
               ]

      assert for(r <- preview.rows, r.state == :held, do: r.reasons) ==
               List.duplicate([:definitions_not_loaded], 3)

      assert for(r <- preview.rows, do: r.default_ticked) == [
               true,
               true,
               true,
               false,
               false,
               false
             ]

      assert row(preview, 1).name == "NZBgeek"

      # A key Prowlarr answered in clear, and the host config's own key and proxy password.
      text = shown(preview)

      for secret <- ["clear-indexer-key-71b0", "host-api-key-a81f", masked(), @prowlarr_key] do
        refute text =~ secret, "#{inspect(secret)} in the preview"
      end
    end

    test "the host config's key and proxy password are kept nowhere in the preview or the log" do
      stub_api([newznab(1)], [], host(true, "host-key-SENTINEL-1", "host-pw-SENTINEL-2"))

      {preview, log} = ExUnit.CaptureLog.with_log([level: :debug], &preview!/0)
      text = shown(preview) <> log

      assert text =~ "global_proxy: true"
      refute text =~ "SENTINEL"

      # Also after a commit, through the re-read and the report.
      {result, log} =
        ExUnit.CaptureLog.with_log([level: :debug], fn ->
          ProwlarrImport.commit(preview, Map.new([tick(1, "One", %{via_prowlarr: true})]))
        end)

      assert {:ok, report} = result
      refute shown(report) <> log =~ "SENTINEL"
    end

    for {name, overrides} <- [
          {"no URL", [base_url: nil]},
          {"no API key", [api_key: nil]},
          {"a blank key", [api_key: ""]}
        ] do
      @overrides overrides

      test "#{name}: :not_configured and no request" do
        ConfigCase.put_config(Prowlarr, @overrides)
        expect(ProwlarrApiMock, :get, 0, fn _connection, _path, _query -> {:ok, []} end)

        assert {:error, :not_configured} = ProwlarrImport.preview()
      end
    end

    test "the three reads go to the stored URL with the stored key" do
      test_pid = self()

      stub(ProwlarrApiMock, :get, fn connection, path, [] ->
        send(test_pid, {:read, connection.url, connection.api_key, path})

        case path do
          "/api/v1/indexer" -> {:ok, []}
          "/api/v1/indexerproxy" -> {:ok, []}
          "/api/v1/config/host" -> {:ok, host(false)}
        end
      end)

      assert {:ok, %Preview{rows: []}} = ProwlarrImport.preview()

      for path <- ["/api/v1/indexer", "/api/v1/indexerproxy", "/api/v1/config/host"],
          do: assert_received({:read, @prowlarr_url, @prowlarr_key, ^path})
    end

    test "a read's error is the preview's" do
      for error <- [{:http_status, 401}, {:http_status, 500}, :timeout, :too_large, :transport] do
        stub_api(fn -> {:error, error} end)
        assert {error, {:error, error}} == {error, ProwlarrImport.preview()}

        stub_api([newznab(1)], fn -> {:error, error} end)
        assert {error, {:error, error}} == {error, ProwlarrImport.preview()}

        stub_api([newznab(1)], [], fn -> {:error, error} end)
        assert {error, {:error, error}} == {error, ProwlarrImport.preview()}
      end
    end

    test "an answer of an unknown shape refuses the whole preview" do
      stub_api([newznab(1), Map.delete(newznab(2), "implementation")])
      assert {:error, :unexpected_response} = ProwlarrImport.preview()

      stub_api(%{"indexers" => [newznab(1)]})
      assert {:error, :unexpected_response} = ProwlarrImport.preview()

      stub_api([newznab(1)], [], %{"proxy" => false})
      assert {:error, :unexpected_response} = ProwlarrImport.preview()
    end

    test "a C# indexer, an HTTP-tagged Newznab and a SOCKS-tagged Torznab are unticked through-Prowlarr offers" do
      stub_api(
        [
          csharp(1, "BroadcastheNet", "torrent"),
          csharp(2, "Omgwtfnzbs", "usenet"),
          newznab(3, tags: [2]),
          torznab(4, tags: [3]),
          torznab(5, tags: [4]),
          newznab(6, tags: [2, 1]),
          newznab(7)
        ],
        [
          proxy(1, "FlareSolverr", [1]),
          proxy(2, "Http", [2]),
          proxy(3, "Socks5", [3]),
          proxy(4, "Socks4", [4])
        ]
      )

      preview = preview!()

      assert for(r <- preview.rows, do: {r.prowlarr_id, r.state, r.type, r.reasons, r.key}) == [
               {1, :via_prowlarr, :torznab, [:implementation], :prowlarr},
               {2, :via_prowlarr, :newznab, [:implementation], :prowlarr},
               {3, :via_prowlarr, :newznab, [:http_proxy], :prowlarr},
               {4, :via_prowlarr, :torznab, [:socks_proxy], :prowlarr},
               {5, :via_prowlarr, :torznab, [:socks_proxy], :prowlarr},
               {6, :via_prowlarr, :newznab, [:flaresolverr, :http_proxy], :prowlarr},
               {7, :direct, :newznab, [], :masked}
             ]

      assert for(r <- preview.rows, r.state == :via_prowlarr, do: {r.tickable, r.default_ticked}) ==
               List.duplicate({true, false}, 6)
    end

    test "a proxy Cinder does not know makes its indexers through-Prowlarr offers" do
      stub_api([newznab(1, tags: [5])], [proxy(1, "Tor", [5])])

      assert %Row{state: :via_prowlarr, reasons: [:other_proxy]} = row(preview!(), 1)
    end

    test "Prowlarr's global proxy on makes every row but a Cardigann one a through-Prowlarr offer" do
      stub_api(
        [newznab(1), torznab(2), csharp(3, "BroadcastheNet"), cardigann(4, "nyaasi")],
        [],
        host(true)
      )

      preview = preview!()

      assert for(r <- preview.rows, do: {r.prowlarr_id, r.state, r.type, r.reasons}) == [
               {1, :via_prowlarr, :newznab, [:global_proxy]},
               {2, :via_prowlarr, :torznab, [:global_proxy]},
               {3, :via_prowlarr, :torznab, [:global_proxy, :implementation]},
               {4, :held, nil, [:definitions_not_loaded]}
             ]

      stub_api([newznab(1)], [], host(false))
      assert %Row{state: :direct} = row(preview!(), 1)
    end

    test "a FlareSolverr tag on a Newznab or a Torznab indexer makes it a through-Prowlarr offer" do
      stub_api([newznab(1, tags: [1]), torznab(2, tags: [1]), newznab(3, tags: [9])], [
        proxy(1, "FlareSolverr", [1])
      ])

      preview = preview!()

      assert for(r <- preview.rows, do: {r.prowlarr_id, r.state, r.type, r.reasons}) == [
               {1, :via_prowlarr, :newznab, [:flaresolverr]},
               {2, :via_prowlarr, :torznab, [:flaresolverr]},
               {3, :direct, :newznab, []}
             ]
    end

    test "a through-Prowlarr offer of protocol unknown is refused" do
      stub_api([csharp(1, "Mystery", "unknown")])

      assert %Row{state: :refused, reasons: [:protocol_unknown], tickable: false} =
               row(preview!(), 1)

      # A Newznab or Torznab one too, whatever its own type says.
      for {indexer, proxies, host} <- [
            {newznab(2, protocol: "unknown"), [], host(true)},
            {torznab(3, protocol: "unknown", tags: [1]), [proxy(1, "Http", [1])], host(false)}
          ] do
        stub_api([indexer], proxies, host)
        id = indexer["id"]

        assert {^id, %Row{state: :refused, reasons: [:protocol_unknown], type: nil}} =
                 {id, row(preview!(), id)}
      end
    end

    # A Torznab configured indexer stores no additional parameters, and Prowlarr adds them to
    # each search of its own `/<id>/api`, so the row keeps them only through Prowlarr. They pass
    # the checks a Newznab row's parameters pass, so a credential in them is refused.
    test "a Torznab indexer's additional parameters make it an unticked through-Prowlarr offer, or refuse it when they fail the Newznab checks" do
      stub_api([
        torznab(1, additional_parameters: "&cat=5000"),
        torznab(2, additional_parameters: "&apikey=x"),
        torznab(3, additional_parameters: "  "),
        newznab(4, additional_parameters: "&cat=2000"),
        torznab(5, additional_parameters: "&cat=1#x")
      ])

      preview = preview!()

      assert for(r <- preview.rows, do: {r.prowlarr_id, r.state, r.reasons, r.tickable}) ==
               [
                 {1, :via_prowlarr, [:additional_parameters], true},
                 {2, :refused, [{:settings, :credential_parameter}], false},
                 {3, :direct, [], true},
                 {4, :direct, [], true},
                 {5, :refused, [{:settings, :parameter_format}], false}
               ]

      assert row(preview, 1).default_ticked == false
      assert Enum.sort(Map.keys(row(preview, 2).plan)) == [:reasons, :state]

      assert row(preview, 1).plan.attrs["settings"] == %{}
      assert row(preview, 3).plan.attrs["settings"] == %{}
      refute shown(preview) =~ "apikey=x"

      assert {:ok, _} =
               ProwlarrImport.commit(preview, Map.new([tick(1, "T", %{via_prowlarr: true})]))

      assert [%{base_url: @prowlarr_url, api_path: "/1/api", settings: %{}}] = configured()
    end

    # The issue refuses these inputs whatever the route: a Newznab or Torznab indexer's own base
    # URL, API path and additional parameters are checked before any through-Prowlarr rule.
    for {route, tags, proxies, global} <- [
          {"direct", [], [], false},
          {"under a proxy tag", [2], [{1, "Http", [2]}], false},
          {"under the global proxy", [], [], true}
        ] do
      @tags tags
      @proxies proxies
      @global global

      test "a Newznab or Torznab indexer whose own settings fail the checks is refused #{route}" do
        stub_api(
          [
            newznab(1, tags: @tags, api_path: "//evil.example/api"),
            newznab(2, tags: @tags, base_url: "https://u:p@nzb.example"),
            newznab(3, tags: @tags, base_url: "https://nzb.example/?x=1"),
            newznab(4, tags: @tags, additional_parameters: "&apikey=x"),
            torznab(5, tags: @tags, additional_parameters: "&apikey=x"),
            torznab(6, tags: @tags, base_url: "https://u:p@tz.example"),
            newznab(7, tags: @tags, priority: 51, additional_parameters: "&apikey=x")
          ],
          for({id, kind, proxy_tags} <- @proxies, do: proxy(id, kind, proxy_tags)),
          host(@global)
        )

        preview = preview!()

        assert for(r <- preview.rows, do: {r.prowlarr_id, r.state, r.reasons, r.tickable}) == [
                 {1, :refused, [{:api_path, :api_path_authority}], false},
                 {2, :refused, [{:base_url, :base_url_userinfo}], false},
                 {3, :refused, [{:base_url, :base_url_query}], false},
                 {4, :refused, [{:settings, :credential_parameter}], false},
                 {5, :refused, [{:settings, :credential_parameter}], false},
                 {6, :refused, [{:base_url, :base_url_userinfo}], false},
                 {7, :refused, [{:priority, :number}, {:settings, :credential_parameter}], false}
               ]

        for r <- preview.rows,
            do: assert(Enum.sort(Map.keys(r.plan)) == [:reasons, :state])

        text = shown(preview)

        for value <- ["evil.example", "u:p@", "x=1", "apikey=x"],
            do: refute(text =~ value, "#{inspect(value)} in the preview")
      end
    end

    # A C# indexer's own base URL is not one Cinder would store: it goes through Prowlarr.
    test "a C# indexer is offered through Prowlarr whatever its own base URL" do
      indexer =
        Map.update!(csharp(1, "BroadcastheNet"), "fields", fn fields ->
          Enum.map(fields, fn
            %{"name" => "baseUrl"} = field -> Map.put(field, "value", "https://u:p@btn.example")
            field -> field
          end)
        end)

      stub_api([indexer])

      assert %Row{state: :via_prowlarr, reasons: [:implementation], tickable: true} =
               row(preview!(), 1)
    end

    test "a through-Prowlarr row whose created settings fail the checks is refused and keeps none of them" do
      stub_api([csharp(1, "BroadcastheNet", "torrent", priority: 51)])

      assert %Row{
               state: :refused,
               reasons: [{:priority, :number}],
               type: nil,
               key: nil,
               tickable: false,
               plan: plan
             } = row(preview!(), 1)

      assert Enum.sort(Map.keys(plan)) == [:reasons, :state]
    end

    test "a refused setting wins over a protocol Prowlarr calls unknown" do
      stub_api(
        [newznab(1, protocol: "unknown", base_url: "https://u:p@nzb.example")],
        [],
        host(true)
      )

      assert %Row{state: :refused, reasons: [{:base_url, :base_url_userinfo}]} =
               row(preview!(), 1)
    end

    test "settings the configured indexer refuses give a refused row with its reasons and no tick" do
      stub_api([
        newznab(1, api_path: "//evil.example/api"),
        newznab(2, base_url: "https://u:p@nzb.example"),
        newznab(3, base_url: "https://nzb.example/?x=1"),
        newznab(4, additional_parameters: "&apikey=x"),
        newznab(6, priority: 51),
        newznab(7, base_url: nil),
        newznab(8, additional_parameters: "&cat=2000")
      ])

      preview = preview!()

      assert for(r <- preview.rows, do: {r.prowlarr_id, r.state, r.reasons, r.tickable}) == [
               {1, :refused, [{:api_path, :api_path_authority}], false},
               {2, :refused, [{:base_url, :base_url_userinfo}], false},
               {3, :refused, [{:base_url, :base_url_query}], false},
               {4, :refused, [{:settings, :credential_parameter}], false},
               {7, :refused, [{:base_url, :required}], false},
               {8, :direct, [], true},
               {6, :refused, [{:priority, :number}], false}
             ]

      assert row(preview, 8).plan.attrs["settings"] == %{"additional_parameters" => "&cat=2000"}

      for %Row{state: :refused} = r <- preview.rows do
        assert {r.prowlarr_id, r.type, r.key, r.default_ticked, Enum.sort(Map.keys(r.plan))} ==
                 {r.prowlarr_id, nil, nil, false, [:reasons, :state]}
      end

      text = shown(preview)

      for value <- ["evil.example", "u:p@", "x=1", "apikey=x"],
          do: refute(text =~ value, "#{inspect(value)} in the preview")
    end

    test "a set limit, query timeout, app profile or seed setting is listed as not carried" do
      limited =
        newznab(1,
          fields: [],
          appProfileId: 0
        )
        |> put_field("baseSettings.queryLimit", 100)
        |> put_field("baseSettings.grabLimit", 5)
        |> put_field("baseSettings.queryTimeout", 30)

      seeded =
        torznab(2)
        |> Map.update!("fields", &(&1 ++ [field("torrentBaseSettings.seedRatio", 1.5)]))

      stub_api([limited, seeded, newznab(3, appProfileId: 0)])
      preview = preview!()

      assert row(preview, 1).not_carried == [:grab_limit, :query_limit, :query_timeout]
      assert row(preview, 2).not_carried == [:app_profile, :seed_settings]
      assert row(preview, 3).not_carried == []
    end

    test "an indexer with no key in Prowlarr is key :none" do
      stub_api([newznab(1, api_key: nil), newznab(2, api_key: "")])
      preview = preview!()

      assert row(preview, 1).key == :none
      assert row(preview, 2).key == :none
    end
  end

  # Sets the value of the `fields` entry `name`.
  defp put_field(indexer, name, value) do
    Map.update!(indexer, "fields", fn fields ->
      Enum.map(fields, fn
        %{"name" => ^name} = entry -> Map.put(entry, "value", value)
        entry -> entry
      end)
    end)
  end

  describe "commit/3" do
    test "a typed key creates the row enabled with it, a blank masked key disabled with none" do
      stub_api([
        newznab(1),
        newznab(2),
        newznab(3, api_key: nil),
        newznab(4, api_key: nil, enable: false)
      ])

      preview = preview!()

      assert {:ok, report} =
               ProwlarrImport.commit(
                 preview,
                 Map.new([
                   tick(1, "Keyed", %{secrets: %{"api_key" => "typed-key-1"}}),
                   tick(2, "Blank", %{secrets: %{"api_key" => "  "}}),
                   tick(3, "Keyless On"),
                   tick(4, "Keyless Off")
                 ])
               )

      assert for(c <- report.created, do: {c.prowlarr_id, c.name, c.enabled, c.notes}) == [
               {1, "Keyed", true, []},
               {2, "Blank", false, [:created_disabled_no_key]},
               {3, "Keyless On", true, []},
               {4, "Keyless Off", false, []}
             ]

      [keyed, blank, keyless_on, keyless_off] = configured()

      assert {:ok, %{secrets: %{"api_key" => "typed-key-1"}}} =
               Indexers.fetch_with_secrets(keyed.id)

      assert {:ok, %{secrets: secrets}} = Indexers.fetch_with_secrets(blank.id)
      assert secrets == %{}
      assert {keyless_on.enabled, keyless_off.enabled} == {true, false}
      assert {blank.secrets_ciphertext, keyless_on.secrets_ciphertext} == {nil, nil}
    end

    test "a direct row is created with Prowlarr's type, base URL, API path, settings and priority" do
      stub_api([
        newznab(1,
          base_url: "https://nzb.example",
          additional_parameters: "&cat=2000",
          priority: 7
        ),
        torznab(2, base_url: "https://tz.example/", api_path: "/torznab/api", priority: 40)
      ])

      assert {:ok, _report} =
               ProwlarrImport.commit(preview!(), Map.new([tick(1, "N"), tick(2, "T")]))

      assert for(
               c <- configured(),
               do:
                 {c.prowlarr_indexer_id, c.type, c.base_url, c.api_path, c.settings, c.priority,
                  c.flaresolverr}
             ) == [
               {1, :newznab, "https://nzb.example", "/api",
                %{"additional_parameters" => "&cat=2000"}, 7, false},
               {2, :torznab, "https://tz.example/", "/torznab/api", %{}, 40, false}
             ]
    end

    test "a ticked through-Prowlarr row is created at Prowlarr's /<id>/api with the stored key" do
      stub_api([newznab(11, tags: [1]), torznab(12, tags: [1])], [proxy(1, "FlareSolverr", [1])])
      preview = preview!()

      assert {:ok, report} =
               ProwlarrImport.commit(
                 preview,
                 Map.new([
                   tick(11, "Through N", %{via_prowlarr: true, secrets: %{"api_key" => "ignored"}}),
                   tick(12, "Through T", %{via_prowlarr: true})
                 ])
               )

      [n, t] = configured()

      assert {n.type, n.base_url, n.api_path, n.flaresolverr, n.prowlarr_indexer_id} ==
               {:newznab, @prowlarr_url, "/11/api", false, 11}

      assert {t.type, t.base_url, t.api_path, t.flaresolverr, t.prowlarr_indexer_id} ==
               {:torznab, @prowlarr_url, "/12/api", false, 12}

      for row <- [n, t] do
        assert {:ok, %{secrets: %{"api_key" => @prowlarr_key}}} =
                 Indexers.fetch_with_secrets(row.id)

        assert Indexers.through_prowlarr?(row.base_url, row.api_path, @prowlarr_url)
      end

      refute shown(preview) =~ @prowlarr_key
      refute shown(report) =~ @prowlarr_key
    end

    test "the through-Prowlarr base URL drops the stored URL's trailing slash" do
      ConfigCase.put_config(Prowlarr, base_url: @prowlarr_url <> "/")
      stub_api([csharp(3, "BroadcastheNet")])

      assert {:ok, _} =
               ProwlarrImport.commit(preview!(), Map.new([tick(3, "BTN", %{via_prowlarr: true})]))

      assert [%{base_url: @prowlarr_url, api_path: "/3/api"}] = configured()
    end

    test "rows are created in priority order, ties in Prowlarr id order, each with its priority" do
      stub_api([newznab(1, priority: 30), newznab(5, priority: 25), newznab(2, priority: 25)])

      assert {:ok, report} =
               ProwlarrImport.commit(
                 preview!(),
                 Map.new([tick(1, "A"), tick(5, "B"), tick(2, "C")])
               )

      assert for(c <- configured(), do: {c.prowlarr_indexer_id, c.priority}) ==
               [{2, 25}, {5, 25}, {1, 30}]

      assert for(c <- report.created, do: c.prowlarr_id) == [2, 5, 1]
    end

    test "every created row is linked, and indexer_source is unchanged" do
      source = Application.get_env(:cinder, :indexer_source)
      stub_api([newznab(1), csharp(2, "BroadcastheNet")])

      assert {:ok, _} =
               ProwlarrImport.commit(
                 preview!(),
                 Map.new([tick(1, "One"), tick(2, "Two", %{via_prowlarr: true})])
               )

      assert for(c <- configured(), do: c.prowlarr_indexer_id) == [1, 2]
      assert Application.get_env(:cinder, :indexer_source) == source
    end

    test "a linked indexer whose own settings now fail the checks stays already imported" do
      stub_api([newznab(1)])
      assert {:ok, _} = ProwlarrImport.commit(preview!(), Map.new([tick(1, "First")]))

      stub_api([
        newznab(1, base_url: "https://u:p@moved.example", additional_parameters: "&apikey=x")
      ])

      assert %Row{state: :already_imported, reasons: [], tickable: false} = row(preview!(), 1)
    end

    test "a second import skips each linked indexer and changes no field of it" do
      stub_api([newznab(1), newznab(2)])
      assert {:ok, _} = ProwlarrImport.commit(preview!(), Map.new([tick(1, "First")]))
      [before] = configured()

      stub_api([newznab(1, base_url: "https://moved.example", priority: 3), newznab(2)])
      preview = preview!()

      assert %Row{state: :already_imported, tickable: false, type: nil} = row(preview, 1)
      assert %Row{state: :direct} = row(preview, 2)

      assert {:error, {:rows, %{1 => [:not_importable]}}} =
               ProwlarrImport.commit(preview, Map.new([tick(1, "Again"), tick(2, "Second")]))

      assert {:ok, %{created: [%{prowlarr_id: 2}]}} =
               ProwlarrImport.commit(preview, Map.new([tick(2, "Second")]))

      assert hd(configured()) == before
    end

    test "a name another configured indexer holds is a row error, and nothing is created" do
      {:ok, _} =
        Indexers.create(nil, %{
          name: "Taken",
          type: :newznab,
          base_url: "https://t.example",
          api_path: "/api"
        })

      stub_api([newznab(1), newznab(2)])

      assert {:error, {:rows, errors}} =
               ProwlarrImport.commit(preview!(), Map.new([tick(1, "  Taken "), tick(2, "Free")]))

      assert errors == %{1 => [:name_taken]}
      assert length(configured()) == 1
    end

    test "every ticked row's error comes back in one answer" do
      {:ok, _} =
        Indexers.create(nil, %{
          name: "Taken",
          type: :newznab,
          base_url: "https://t.example",
          api_path: "/api"
        })

      stub_api([newznab(1), newznab(2), newznab(3), newznab(4), csharp(5, "BroadcastheNet")])

      assert {:error, {:rows, errors}} =
               ProwlarrImport.commit(
                 preview!(),
                 Map.new([
                   tick(1, "Taken"),
                   tick(2, " "),
                   tick(3, "Twice"),
                   tick(4, "Twice", %{via_prowlarr: true, secrets: %{"api_key" => <<0xFF>>}}),
                   tick(5, "Five")
                 ])
               )

      assert errors == %{
               1 => [:name_taken],
               2 => [:name_required],
               3 => [:name_duplicate],
               4 => [:via_prowlarr_not_offered, :name_duplicate, :secret_invalid],
               5 => [:via_prowlarr_not_chosen]
             }

      assert length(configured()) == 1
    end

    test "two ticked rows with one name each get a row error, and nothing is created" do
      stub_api([newznab(1), newznab(2), newznab(3)])

      assert {:error, {:rows, errors}} =
               ProwlarrImport.commit(
                 preview!(),
                 Map.new([tick(1, "Same"), tick(2, " Same"), tick(3, "Other")])
               )

      assert errors == %{1 => [:name_duplicate], 2 => [:name_duplicate]}
      assert configured() == []
    end

    test "a name is trimmed, and a blank one is a row error" do
      stub_api([newznab(1), newznab(2)])
      preview = preview!()

      assert {:error, {:rows, %{2 => [:name_required]}}} =
               ProwlarrImport.commit(preview, Map.new([tick(1, " Kept "), tick(2, "   ")]))

      assert {:ok, _} = ProwlarrImport.commit(preview, Map.new([tick(1, " Kept ")]))
      assert [%{name: "Kept"}] = configured()
    end

    test "the through-Prowlarr opt-in must match the row" do
      stub_api([newznab(1), csharp(2, "BroadcastheNet")])
      preview = preview!()

      assert {:error, {:rows, errors}} =
               ProwlarrImport.commit(
                 preview,
                 Map.new([
                   tick(1, "One", %{via_prowlarr: true}),
                   tick(2, "Two", %{via_prowlarr: false})
                 ])
               )

      assert errors == %{1 => [:via_prowlarr_not_offered], 2 => [:via_prowlarr_not_chosen]}

      assert {:error, {:rows, %{2 => [:via_prowlarr_not_chosen]}}} =
               ProwlarrImport.commit(preview, %{2 => %{ticked: true, name: "Two"}})

      assert configured() == []
    end

    test "a held, refused or unknown row ticked is not importable" do
      stub_api([
        cardigann(1, "nyaasi"),
        newznab(2, base_url: "https://u:p@x.example"),
        newznab(3)
      ])

      preview = preview!()

      stub_api([
        cardigann(1, "nyaasi"),
        newznab(2, base_url: "https://u:p@x.example"),
        newznab(3),
        newznab(4)
      ])

      assert {:error, {:rows, errors}} =
               ProwlarrImport.commit(
                 preview,
                 Map.new([tick(1, "A"), tick(2, "B"), tick(3, "C"), tick(4, "D")])
               )

      assert errors == %{1 => [:not_importable], 2 => [:not_importable], 4 => [:not_importable]}
      assert configured() == []
    end

    test "a secret that is not text, or not a map, is a row error" do
      stub_api([newznab(1), newznab(2)])

      assert {:error, {:rows, errors}} =
               ProwlarrImport.commit(
                 preview!(),
                 Map.new([
                   tick(1, "A", %{secrets: %{"api_key" => <<0xFF>>}}),
                   tick(2, "B", %{secrets: "key"})
                 ])
               )

      assert errors == %{1 => [:secret_invalid], 2 => [:secret_invalid]}
    end

    test "typed secrets are read for ticked rows only" do
      stub_api([newznab(1), newznab(2)])

      assert {:ok, _} =
               ProwlarrImport.commit(
                 preview!(),
                 Map.new([
                   tick(1, "A"),
                   {2, %{ticked: false, name: "B", secrets: %{"api_key" => <<0xFF>>}}}
                 ])
               )

      assert [%{prowlarr_indexer_id: 1}] = configured()
    end

    test "choices that tick nothing are refused before any request" do
      stub_api([newznab(1)])
      preview = preview!()
      expect(ProwlarrApiMock, :get, 0, fn _c, _p, _q -> {:ok, []} end)

      assert {:error, :nothing_ticked} = ProwlarrImport.commit(preview, %{})

      assert {:error, :nothing_ticked} =
               ProwlarrImport.commit(preview, %{1 => %{ticked: false, name: "A"}})
    end

    for {change, before, later} <- [
          {"a new baseUrl", [newznab(1)], [newznab(1, base_url: "https://moved.example")]},
          {"a key now masked", [newznab(1, api_key: nil)], [newznab(1)]},
          {"a new proxy tag", [newznab(1)], [newznab(1, tags: [2])]},
          {"a new enabled state", [newznab(1)], [newznab(1, enable: false)]},
          {"a key value changed, still present", [newznab(1, api_key: "first-secret")],
           [newznab(1, api_key: "second-secret")]},
          {"the indexer gone", [newznab(1)], []}
        ] do
      @before before
      @later later

      test "#{change} between preview and commit refuses the import with a new preview" do
        stub_api(@before, [proxy(1, "Http", [2])])
        preview = preview!()
        stub_api(@later, [proxy(1, "Http", [2])])

        assert {:error, {:changed, %Preview{} = fresh}} =
                 ProwlarrImport.commit(preview, Map.new([tick(1, "One")]))

        assert for(r <- fresh.rows, do: r.prowlarr_id) == for(i <- @later, do: i["id"])
        assert fresh.mac_key != preview.mac_key
        assert configured() == []
        assert audits() == []
      end
    end

    test "the stored Prowlarr key changed between preview and commit refuses the import" do
      stub_api([newznab(1)])
      preview = preview!()
      ConfigCase.put_config(Prowlarr, api_key: "another-key")

      assert {:error, {:changed, _}} = ProwlarrImport.commit(preview, Map.new([tick(1, "One")]))
      assert configured() == []
    end

    test "an unchanged Prowlarr commits, and a change to an unticked row does not refuse it" do
      stub_api([newznab(1, api_key: "same-secret"), newznab(2)])
      preview = preview!()

      stub_api([
        newznab(1, api_key: "same-secret"),
        newznab(2, base_url: "https://moved.example"),
        newznab(3)
      ])

      assert {:ok, %{created: [%{prowlarr_id: 1}]}} =
               ProwlarrImport.commit(preview, Map.new([tick(1, "One")]))
    end

    test "a link another tab makes while the commit reads Prowlarr refuses the whole batch" do
      stub_api([newznab(1), newznab(2)])
      preview = preview!()

      stub(ProwlarrApiMock, :get, fn _connection, path, [] ->
        case path do
          "/api/v1/indexer" ->
            {:ok, [newznab(1), newznab(2)]}

          "/api/v1/indexerproxy" ->
            {:ok, []}

          "/api/v1/config/host" ->
            {:ok, _} =
              Indexers.create_imported(
                nil,
                %{
                  name: "Other tab",
                  type: :newznab,
                  base_url: "https://o.example",
                  api_path: "/api"
                },
                %{},
                2
              )

            {:ok, host(false)}
        end
      end)

      assert {:error, {:rows, %{2 => [:already_imported]}}} =
               ProwlarrImport.commit(preview, Map.new([tick(1, "One"), tick(2, "Two")]))

      assert [%{name: "Other tab"}] = configured()
      assert audits() == []
    end

    test "a name another tab takes while the commit reads Prowlarr refuses the whole batch" do
      stub_api([newznab(1)])
      preview = preview!()

      stub(ProwlarrApiMock, :get, fn _connection, path, [] ->
        case path do
          "/api/v1/indexer" ->
            {:ok, [newznab(1)]}

          "/api/v1/indexerproxy" ->
            {:ok, _} =
              Indexers.create(nil, %{
                name: "One",
                type: :newznab,
                base_url: "https://o.example",
                api_path: "/api"
              })

            {:ok, []}

          "/api/v1/config/host" ->
            {:ok, host(false)}
        end
      end)

      assert {:error, {:rows, %{1 => [:name_taken]}}} =
               ProwlarrImport.commit(preview, Map.new([tick(1, "One")]))

      assert audits() == []
    end

    test "a commit writes one audit row with the count, and a refused commit none" do
      stub_api([newznab(1), newznab(2), newznab(3)])
      preview = preview!()

      assert {:error, {:rows, _}} =
               ProwlarrImport.commit(preview, Map.new([tick(1, "Same"), tick(2, "Same")]))

      assert audits() == []

      assert {:ok, _} =
               ProwlarrImport.commit(preview, Map.new([tick(1, "One"), tick(3, "Three")]))

      assert [%AdminAudit{entity_type: "ConfiguredIndexer", entity_id: nil, detail: detail}] =
               audits()

      assert detail == %{"count" => 2, "prowlarr_indexer_ids" => [1, 3]}
    end

    test "a refused audit row rolls the import back with :audit_refused" do
      stub_api([newznab(1)])

      assert {:error, :audit_refused} =
               ProwlarrImport.commit(
                 preview!(),
                 Map.new([tick(1, "One")]),
                 %Cinder.Accounts.User{id: "not-an-id"}
               )

      assert configured() == []
    end

    test "a second commit while one holds the import lock is refused, and the lock is free after" do
      stub_api([newznab(1), newznab(2)])
      preview = preview!()
      test_pid = self()

      stub(ProwlarrApiMock, :get, fn _connection, path, [] ->
        if path == "/api/v1/indexer" and self() != test_pid do
          send(test_pid, {:holding, self()})

          receive do
            :release -> :ok
          end
        end

        case path do
          "/api/v1/indexer" -> {:ok, [newznab(1), newznab(2)]}
          "/api/v1/indexerproxy" -> {:ok, []}
          "/api/v1/config/host" -> {:ok, host(false)}
        end
      end)

      holder = Task.async(fn -> ProwlarrImport.commit(preview, Map.new([tick(1, "One")])) end)
      assert_receive {:holding, holder_pid}, 5_000

      assert {:error, :import_running} = ProwlarrImport.commit(preview, Map.new([tick(2, "Two")]))

      send(holder_pid, :release)
      assert {:ok, %{created: [%{prowlarr_id: 1}]}} = Task.await(holder)

      assert {:ok, %{created: [%{prowlarr_id: 2}]}} =
               ProwlarrImport.commit(preview, Map.new([tick(2, "Two")]))
    end

    # The later commit runs in another process: the process that holds the lock could take it
    # again, so only another one shows the lock was freed.
    for {outcome, answer} <- [{"fails", :fail}, {"raises", :raise}, {"succeeds", :ok}] do
      @answer answer

      test "a commit that #{outcome} frees the lock for another process" do
        stub_api([newznab(1), newznab(2)])
        preview = preview!()

        case @answer do
          :fail ->
            stub_api(fn -> {:error, :timeout} end)
            assert {:error, :timeout} = ProwlarrImport.commit(preview, Map.new([tick(1, "One")]))

          :raise ->
            stub_api(fn -> raise "read crashed" end)

            assert_raise RuntimeError, fn ->
              ProwlarrImport.commit(preview, Map.new([tick(1, "One")]))
            end

          :ok ->
            assert {:ok, _} = ProwlarrImport.commit(preview, Map.new([tick(1, "One")]))
        end

        stub_api([newznab(1), newznab(2)])

        assert {:ok, %{created: [%{prowlarr_id: 2}]}} =
                 Task.await(
                   Task.async(fn -> ProwlarrImport.commit(preview, Map.new([tick(2, "Two")])) end)
                 )
      end
    end

    test "after a commit, one Test starts for each enabled created indexer and none for a disabled one" do
      stub_api([newznab(1), newznab(2), newznab(3, api_key: nil, enable: false)])

      assert {:ok, report} =
               ProwlarrImport.commit(
                 preview!(),
                 Map.new([
                   tick(1, "Keyed", %{secrets: %{"api_key" => "k1"}}),
                   tick(2, "Blank"),
                   tick(3, "Off")
                 ])
               )

      [keyed, blank, off] = configured()
      assert report.tests_started == [keyed.id]

      keyed_id = keyed.id
      assert_receive {TestRunner, :started, ^keyed_id}
      assert_receive {:test_started, _task, ^keyed_id}

      for id <- [blank.id, off.id], do: refute_received({TestRunner, :started, ^id})
      assert TestRunner.running() == MapSet.new([keyed.id])
    end
  end
end
