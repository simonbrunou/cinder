defmodule Cinder.Indexers.ProwlarrImportCardigannTest do
  # The Prowlarr import of Cardigann indexers (#1675): each Prowlarr Cardigann indexer maps, by
  # its definition file, to a native Cardigann configured indexer pinned to the mirror's copy, or
  # to the through-Prowlarr offer with its reason. Prowlarr's answers are hand-written
  # (`Cinder.ProwlarrApiFixtures`), and so are the definitions (`Cinder.DefinitionFixtures`), as
  # #1616's rule 14 asks.
  #
  # Not async: the Prowlarr source's config, the import lock and the Test runner are app-wide.
  use Cinder.DataCase, async: false

  import Ecto.Query
  import Mox
  import Cinder.ProwlarrApiFixtures
  import Cinder.TestRunnerHelpers

  alias Cinder.Acquisition.IndexerSource.Native.TestRunner
  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.ConfigCase
  alias Cinder.DefinitionFixtures
  alias Cinder.Indexers
  alias Cinder.Indexers.{ConfiguredIndexer, ProwlarrImport}
  alias Cinder.Indexers.Definitions.LoadResult
  alias Cinder.Indexers.ProwlarrImport.{Answer, Preview}

  @prowlarr_url "https://media.example.com/prowlarr"
  @prowlarr_key "stored-prowlarr-key-3e9a"
  @link DefinitionFixtures.link()
  @password "clear-password-SENTINEL-41"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    ConfigCase.put_config(Prowlarr, base_url: @prowlarr_url, api_key: @prowlarr_key)
    block_tests()
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

  defp shown(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp secrets(%ConfiguredIndexer{id: id}) do
    {:ok, %{secrets: secrets}} = Indexers.fetch_with_secrets(id)
    secrets
  end

  # The settings of `DefinitionFixtures.definition/1` as Prowlarr answers them: `sort` sorted by
  # key reads Date at 0 and Size at 1.
  defp tracker_fields(overrides \\ []) do
    values =
      Keyword.merge(
        [
          username: "alice",
          password: @password,
          apikey: nil,
          freeleech: true,
          sort: {1, ["Date", "Size"]}
        ],
        overrides
      )

    [
      field("username", values[:username]),
      field("password", values[:password]),
      field("apikey", values[:apikey]),
      field("freeleech", values[:freeleech]),
      select_field("sort", elem(values[:sort], 0), elem(values[:sort], 1))
    ]
  end

  defp tracker(id, opts \\ []) do
    {fields, opts} = Keyword.pop(opts, :fields, tracker_fields())
    cardigann(id, "tracker", Keyword.merge([name: "Tracker #{id}", fields: fields], opts))
  end

  defp definition(extra \\ %{}), do: DefinitionFixtures.definition("tracker", extra)

  defp mirror!(bytes \\ definition(), more \\ []), do: DefinitionFixtures.mirror!(bytes, more)

  defp via(preview, id) do
    row = row(preview, id)
    {row.state, row.type, row.tickable, row.default_ticked, row.reasons}
  end

  describe "a definition that loads" do
    test "imports as a native Cardigann indexer pinned to the running copy" do
      bytes = definition()
      mirror!(bytes)
      stub_api([tracker(1)])

      preview = preview!()
      row = row(preview, 1)

      assert {row.state, row.type, row.tickable, row.default_ticked} ==
               {:direct, :cardigann, true, true}

      assert row.secret_inputs == []
      assert row.notes == []
      refute shown(preview) =~ @password
      refute shown(preview) =~ "alice"

      assert {:ok, report} = ProwlarrImport.commit(preview, Map.new([tick(1, "Mine")]))
      assert [%{prowlarr_id: 1, name: "Mine", enabled: true, notes: []}] = report.created

      assert [indexer] = configured()

      assert {indexer.type, indexer.definition, indexer.base_url, indexer.prowlarr_indexer_id,
              indexer.enabled, indexer.flaresolverr, indexer.priority} ==
               {:cardigann, "tracker.yml", @link, 1, true, false, 25}

      assert indexer.settings == %{"freeleech" => true, "sort" => "size"}

      # Every secret's effective value: the clear ones copied, the unset one at its default.
      assert secrets(indexer) == %{
               "username" => "alice",
               "password" => @password,
               "apikey" => "public-key"
             }

      assert DefinitionFixtures.pin(indexer).running == DefinitionFixtures.blob_sha(bytes)
      refute shown(report) =~ @password
    end

    test "maps by Prowlarr's definitionFile, never by definitionName" do
      # The decoy carries the definitionName's file name, with a link of its own.
      decoy =
        DefinitionFixtures.definition("tracker-api", %{"links" => ["https://decoy.invalid/"]})

      bytes = DefinitionFixtures.definition("tracker-api")

      DefinitionFixtures.apply_files([
        {"v11", "tracker.yml", bytes},
        {"v11", "tracker-api.yml", decoy}
      ])

      stub_api([tracker(1, definitionName: "tracker-api")])

      preview = preview!()
      assert row(preview, 1).plan.attrs["definition"] == "tracker.yml"

      assert row(preview, 1).plan.attrs["definition_blob_sha"] ==
               DefinitionFixtures.blob_sha(bytes)

      assert row(preview, 1).plan.attrs["base_url"] == @link
    end

    test "a definitionFile that already ends in .yml names that file" do
      mirror!()
      stub_api([tracker(1, file: "tracker.yml")])

      assert row(preview!(), 1).plan.attrs["definition"] == "tracker.yml"
    end
  end

  describe "base URL" do
    @links %{
      "links" => ["https://new.invalid/", "https://second.invalid/"],
      "legacylinks" => ["https://old.invalid/", "https://second.invalid"]
    }

    for {name, stored, expected} <- [
          {"a legacy link takes the first link", "https://old.invalid/", "https://new.invalid/"},
          {"a legacy link without its slash", "https://old.invalid", "https://new.invalid/"},
          {"an empty one takes the first link", "", "https://new.invalid/"},
          {"a blank one takes the first link", "  ", "https://new.invalid/"},
          {"an unset one takes the first link", nil, "https://new.invalid/"},
          {"a link and a legacy link at once is legacy", "https://second.invalid/",
           "https://new.invalid/"},
          {"a link stays", "https://new.invalid/", "https://new.invalid/"},
          {"a link without its slash takes the link as written", "https://new.invalid",
           "https://new.invalid/"}
        ] do
      @stored stored
      @expected expected

      test "#{name}" do
        mirror!(definition(@links))
        stub_api([tracker(1, base_url: @stored)])

        preview = preview!()
        assert row(preview, 1).state == :direct
        assert row(preview, 1).plan.attrs["base_url"] == @expected
      end
    end

    test "a stored URL in neither list cannot go direct" do
      mirror!(definition(@links))
      stub_api([tracker(1, base_url: "https://elsewhere.invalid/")])

      assert via(preview!(), 1) ==
               {:via_prowlarr, :torznab, true, false, [:base_url_not_in_links]}
    end

    test "a stored URL with a trailing slash the link leaves out still matches; another path does not" do
      mirror!(definition(%{"links" => ["https://new.invalid/x"]}))

      stub_api([
        tracker(1, base_url: "https://new.invalid/x/"),
        tracker(2, base_url: "https://new.invalid/")
      ])

      preview = preview!()
      assert row(preview, 1).plan.attrs["base_url"] == "https://new.invalid/x"
      assert via(preview, 2) == {:via_prowlarr, :torznab, true, false, [:base_url_not_in_links]}
    end
  end

  describe "a definition that cannot be used" do
    test "removed upstream: cannot go direct, offered unticked through Prowlarr" do
      mirror!()
      assert {:ok, {:loaded, _}} = DefinitionFixtures.apply_files([])
      stub_api([tracker(1)])

      assert via(preview!(), 1) ==
               {:via_prowlarr, :torznab, true, false, [:definition_not_available]}
    end

    test "absent from the mirror" do
      mirror!()
      stub_api([cardigann(1, "elsewhere", fields: tracker_fields())])

      assert via(preview!(), 1) ==
               {:via_prowlarr, :torznab, true, false, [:definition_not_available]}
    end

    test "replaced by another file" do
      newer = DefinitionFixtures.definition("newer", %{"replaces" => ["tracker"]})
      assert {:ok, {:loaded, _}} = DefinitionFixtures.apply_files([{"v11", "newer.yml", newer}])
      stub_api([tracker(1)])

      assert via(preview!(), 1) ==
               {:via_prowlarr, :torznab, true, false, [:definition_not_available]}
    end

    test "a copy that fails to load" do
      mirror!(DefinitionFixtures.failing("tracker"))
      stub_api([tracker(1)])

      assert via(preview!(), 1) ==
               {:via_prowlarr, :torznab, true, false, [:definition_not_available]}
    end

    test "a copy whose stored load result fails reads not available, even when it parses" do
      bytes = definition()

      check = fn
        ^bytes -> {:error, :refused_by_check}
        other -> DefinitionFixtures.check(other)
      end

      assert {:ok, {:loaded, _}} =
               DefinitionFixtures.apply_files([{"v11", "tracker.yml", bytes}], check: check)

      stub_api([tracker(1)])

      assert via(preview!(), 1) ==
               {:via_prowlarr, :torznab, true, false, [:definition_not_available]}
    end

    test "not supported: each feature its load result names" do
      mirror!(DefinitionFixtures.definition("tracker-ns"))
      stub_api([tracker(1)])

      assert via(preview!(), 1) ==
               {:via_prowlarr, :torznab, true, false, [{:not_supported, :html_search}]}
    end

    test "a copy reason and a proxy reason are both listed" do
      mirror!(DefinitionFixtures.definition("tracker-ns"))
      stub_api([tracker(1, tags: [3])], [proxy(1, "Http", [3])])

      assert via(preview!(), 1) ==
               {:via_prowlarr, :torznab, true, false,
                [:http_proxy, {:not_supported, :html_search}]}
    end

    test "needs a newer Cinder" do
      assert {:ok, {:loaded, _}} =
               DefinitionFixtures.apply_files([{"v13", "tracker.yml", definition()}])

      stub_api([tracker(1)])

      assert via(preview!(), 1) == {:via_prowlarr, :torznab, true, false, [:needs_newer_cinder]}
    end

    test "a copy with no load result yet stays held, so no link is made for good" do
      mirror!()
      Repo.delete_all(LoadResult)
      stub_api([tracker(1)])

      assert via(preview!(), 1) == {:held, nil, false, false, [:definitions_not_loaded]}
    end

    test "a through-Prowlarr Cardigann row is created at Prowlarr's /<id>/api with its key" do
      mirror!(DefinitionFixtures.definition("tracker-ns"))
      stub_api([tracker(7)], [proxy(1, "FlareSolverr", [3])], host(false))

      preview = preview!()

      assert {:ok, _report} =
               ProwlarrImport.commit(preview, Map.new([tick(7, "Via", %{via_prowlarr: true})]))

      assert [indexer] = configured()

      assert {indexer.type, indexer.base_url, indexer.api_path, indexer.flaresolverr,
              indexer.prowlarr_indexer_id} ==
               {:torznab, @prowlarr_url, "/7/api", false, 7}

      assert secrets(indexer) == %{"api_key" => @prowlarr_key}
    end
  end

  describe "no definition loaded" do
    test "every Cardigann row stays definitions not loaded yet, whatever its tags" do
      stub_api([tracker(1, tags: [1]), tracker(2)], [proxy(1, "Http", [1])], host(true))

      preview = preview!()

      for id <- [1, 2],
          do: assert(via(preview, id) == {:held, nil, false, false, [:definitions_not_loaded]})
    end
  end

  describe "proxies" do
    test "a FlareSolverr tag goes direct with its toggle on" do
      mirror!()
      stub_api([tracker(1, tags: [3]), tracker(2, tags: [4])], [proxy(1, "FlareSolverr", [3])])

      preview = preview!()
      assert row(preview, 1).state == :direct
      assert row(preview, 1).plan.attrs["flaresolverr"] == true
      assert row(preview, 2).plan.attrs["flaresolverr"] == false

      assert {:ok, _report} = ProwlarrImport.commit(preview, Map.new([tick(1, "Flare")]))
      assert [%ConfiguredIndexer{flaresolverr: true, type: :cardigann}] = configured()
    end

    for {name, proxies, global, reasons} <- [
          {"an HTTP proxy tag beside it", [{"Http", [3]}], false, [:http_proxy]},
          {"a SOCKS proxy tag beside it", [{"Socks5", [3]}], false, [:socks_proxy]},
          {"a proxy Cinder does not know beside it", [{"Tor", [3]}], false, [:other_proxy]},
          {"Prowlarr's global proxy on", [], true, [:global_proxy]}
        ] do
      @proxies proxies
      @global global
      @reasons reasons

      test "a FlareSolverr tag with #{name} cannot go direct" do
        mirror!()

        proxies =
          [proxy(1, "FlareSolverr", [3])] ++
            for {{implementation, tags}, i} <- Enum.with_index(@proxies, 2),
                do: proxy(i, implementation, tags)

        stub_api([tracker(1, tags: [3])], proxies, host(@global))

        assert via(preview!(), 1) == {:via_prowlarr, :torznab, true, false, @reasons}
      end
    end

    test "a proxy on another tag changes nothing" do
      mirror!()
      stub_api([tracker(1, tags: [3])], [proxy(1, "Http", [4])])

      assert row(preview!(), 1).state == :direct
    end
  end

  describe "select settings" do
    defp sort_definition(options, default) do
      setting =
        %{"name" => "sort", "type" => "select", "label" => "Sort order", "options" => options}

      setting = if default, do: Map.put(setting, "default", default), else: setting
      settings = Enum.reject(DefinitionFixtures.settings(), &(&1["name"] == "sort"))
      definition(%{"settings" => settings ++ [setting]})
    end

    @options %{"date" => "Date", "size" => "Size", "seeders" => "Seeders"}

    test "a label unique on both sides stores the running copy's key" do
      mirror!(sort_definition(@options, "date"))
      stub_api([tracker(1, fields: tracker_fields(sort: {2, ["Date", "Seeders", "Size"]}))])

      row = row(preview!(), 1)
      assert row.plan.attrs["settings"]["sort"] == "size"
      assert row.notes == []
    end

    for {name, options, prowlarr} <- [
          {"twice in Prowlarr's options", %{"date" => "Date", "size" => "Size"},
           {1, ["Date", "Size", "Size"]}},
          {"twice in the running copy's options",
           %{"date" => "Date", "a" => "Size", "b" => "Size"}, {1, ["Date", "Size"]}},
          {"at a position Prowlarr does not list", %{"date" => "Date", "size" => "Size"},
           {5, ["Date", "Size"]}},
          {"missing from the running copy", %{"date" => "Date", "big" => "Biggest"},
           {1, ["Date", "Size"]}}
        ] do
      @options_case options
      @prowlarr prowlarr

      test "a label #{name} takes the default, and the report names the setting" do
        mirror!(sort_definition(@options_case, "date"))
        stub_api([tracker(1, fields: tracker_fields(sort: @prowlarr))])

        preview = preview!()
        row = row(preview, 1)
        assert row.state == :direct
        refute Map.has_key?(row.plan.attrs["settings"], "sort")
        assert row.notes == [{:took_default, "Sort order"}]

        assert {:ok, report} = ProwlarrImport.commit(preview, Map.new([tick(1, "Def")]))
        assert [%{notes: [{:took_default, "Sort order"}]}] = report.created
        assert [%ConfiguredIndexer{settings: %{"sort" => "date"}}] = configured()
      end

      test "a label #{name} with no default cannot go direct" do
        mirror!(sort_definition(@options_case, nil))
        stub_api([tracker(1, fields: tracker_fields(sort: @prowlarr))])

        assert via(preview!(), 1) ==
                 {:via_prowlarr, :torznab, true, false, [{:select_no_default, "Sort order"}]}
      end
    end

    test "a select Prowlarr holds no value for takes the default with no note" do
      mirror!(sort_definition(@options, "date"))
      stub_api([tracker(1, fields: tracker_fields(sort: {nil, ["Date", "Seeders", "Size"]}))])

      row = row(preview!(), 1)
      assert {row.state, row.notes} == {:direct, []}
    end

    test "a select Prowlarr holds no value for, with no default, cannot go direct" do
      mirror!(sort_definition(@options, nil))
      stub_api([tracker(1, fields: tracker_fields(sort: {nil, ["Date", "Seeders", "Size"]}))])

      assert via(preview!(), 1) ==
               {:via_prowlarr, :torznab, true, false, [{:select_no_default, "Sort order"}]}
    end

    test "a select with no label and no setting label is named by its setting name" do
      setting = %{"name" => "order", "type" => "select", "options" => %{"a" => "A", "b" => "A"}}
      mirror!(definition(%{"settings" => [setting]}))
      stub_api([tracker(1, fields: [select_field("order", 0, ["A", "A"])])])

      assert via(preview!(), 1) ==
               {:via_prowlarr, :torznab, true, false, [{:select_no_default, "order"}]}
    end

    test "a checkbox takes Prowlarr's boolean, and its default with none" do
      mirror!()

      stub_api([
        tracker(1, fields: tracker_fields(freeleech: true)),
        tracker(2, fields: tracker_fields(freeleech: nil))
      ])

      preview = preview!()
      assert row(preview, 1).plan.attrs["settings"]["freeleech"] == true
      refute Map.has_key?(row(preview, 2).plan.attrs["settings"], "freeleech")
    end
  end

  describe "masked secrets" do
    test "a masked secret left blank creates the indexer disabled with no value" do
      mirror!()
      stub_api([tracker(1, fields: tracker_fields(password: masked()))])

      preview = preview!()
      assert row(preview, 1).secret_inputs == [%{field: "password", label: "Password"}]

      assert {:ok, report} =
               ProwlarrImport.commit(
                 preview,
                 Map.new([tick(1, "Blank", %{secrets: %{"password" => ""}})])
               )

      assert [%{enabled: false, notes: [{:secrets_not_entered, ["Password"]}]}] = report.created
      assert report.tests_started == []
      assert [indexer] = configured()
      refute indexer.enabled
      assert secrets(indexer)["password"] == ""
      assert secrets(indexer)["username"] == "alice"
    end

    test "a typed masked secret is stored and the indexer keeps Prowlarr's enabled state" do
      mirror!()
      stub_api([tracker(1, fields: tracker_fields(password: masked()))])

      assert {:ok, report} =
               ProwlarrImport.commit(
                 preview!(),
                 Map.new([tick(1, "Typed", %{secrets: %{"password" => "typed-pw"}})])
               )

      assert [%{enabled: true, notes: []}] = report.created
      assert secrets(hd(configured()))["password"] == "typed-pw"
    end

    test "one of two masked secrets typed names only the blank one" do
      mirror!()
      stub_api([tracker(1, fields: tracker_fields(password: masked(), username: masked()))])

      assert {:ok, report} =
               ProwlarrImport.commit(
                 preview!(),
                 Map.new([tick(1, "Half", %{secrets: %{"password" => "typed-pw"}})])
               )

      assert [%{enabled: false, notes: [{:secrets_not_entered, ["Username"]}]}] = report.created
    end

    test "a typed value for a secret Prowlarr answered in clear is refused" do
      mirror!()
      stub_api([tracker(1, fields: tracker_fields(password: masked()))])

      assert {:error, {:rows, %{1 => [:settings_invalid]}}} =
               ProwlarrImport.commit(
                 preview!(),
                 Map.new([tick(1, "Forged", %{secrets: %{"username" => "mallory"}})])
               )

      assert configured() == []
    end

    for {name, secrets} <- [
          {"secrets that are not a map", :invalid},
          {"a typed secret that is not text", %{"password" => %{"x" => "y"}}},
          {"a typed secret that is not UTF-8", %{"password" => <<0xFF, 0xFE>>}},
          {"a clear_ key beside a masked secret", %{"clear_password" => "true"}}
        ] do
      @secrets secrets

      test "#{name} are refused" do
        mirror!()
        stub_api([tracker(1, fields: tracker_fields(password: masked()))])

        assert {:error, {:rows, %{1 => [:settings_invalid]}}} =
                 ProwlarrImport.commit(
                   preview!(),
                   Map.new([tick(1, "Bad", %{secrets: @secrets})])
                 )

        assert configured() == []
      end
    end
  end

  describe "preview to commit" do
    test "a definition update between preview and commit refuses the whole batch" do
      mirror!()
      stub_api([tracker(1), newznab(2, api_key: nil)])
      preview = preview!()

      mirror!(definition(%{"description" => "updated upstream"}))

      assert {:error, {:changed, %Preview{} = fresh}} =
               ProwlarrImport.commit(preview, Map.new([tick(1, "One"), tick(2, "Two")]))

      assert row(fresh, 1).state == :direct
      assert configured() == []
    end

    test "a clear secret changed in Prowlarr between preview and commit refuses the batch" do
      mirror!()
      stub_api([tracker(1)])
      preview = preview!()

      stub_api([tracker(1, fields: tracker_fields(password: "changed-pw"))])

      assert {:error, {:changed, _fresh}} =
               ProwlarrImport.commit(preview, Map.new([tick(1, "One")]))

      assert configured() == []
    end

    test "a blank clear secret is no value, so blanking it again in Prowlarr changes nothing" do
      mirror!()
      stub_api([tracker(1, fields: tracker_fields(apikey: "  "))])
      preview = preview!()

      stub_api([tracker(1, fields: tracker_fields(apikey: ""))])

      assert {:ok, _report} = ProwlarrImport.commit(preview, Map.new([tick(1, "Blank")]))
      assert [indexer] = configured()
      assert secrets(indexer)["apikey"] == "public-key"
    end

    test "the create's own pin check refuses a copy the mirror no longer holds" do
      mirror!()
      stub_api([tracker(1)])
      attrs = Map.put(row(preview!(), 1).plan.attrs, "name", "Stale")

      mirror!(definition(%{"description" => "updated upstream"}))

      assert {:error, {:rows, %{1 => [{:definition, :definition_not_in_mirror}]}}} =
               Indexers.import_batch(nil, [%{prowlarr_id: 1, attrs: attrs, secrets: %{}}])

      assert configured() == []
    end

    test "an import of the same Prowlarr indexer again shows already imported and changes nothing" do
      mirror!()
      stub_api([tracker(1)])
      assert {:ok, _report} = ProwlarrImport.commit(preview!(), Map.new([tick(1, "Once")]))
      before = configured()

      preview = preview!()
      assert via(preview, 1) == {:already_imported, nil, false, false, []}

      assert {:error, {:rows, %{1 => [:not_importable]}}} =
               ProwlarrImport.commit(preview, Map.new([tick(1, "Twice")]))

      assert configured() == before
    end

    test "limits, query timeout and seed settings set in Prowlarr are listed as not carried" do
      mirror!()

      fields =
        tracker_fields() ++
          [
            field("baseSettings.grabLimit", 5),
            field("baseSettings.queryTimeout", 30),
            field("torrentBaseSettings.seedTime", 60)
          ]

      indexer = tracker(1, fields: fields)

      indexer =
        update_in(indexer["fields"], fn fields ->
          Enum.map(fields, fn
            %{"name" => "baseSettings.queryLimit"} = f -> Map.put(f, "value", 10)
            f -> f
          end)
        end)

      stub_api([indexer])

      # The fixtures' app profile 1 is set too.
      assert row(preview!(), 1).not_carried == [
               :app_profile,
               :grab_limit,
               :query_limit,
               :query_timeout,
               :seed_settings
             ]
    end
  end

  describe "Answer" do
    test "Cardigann clear values never show in inspect, generic field names included" do
      url = "https://alice:url-SENTINEL@tracker.invalid/"
      fields = tracker_fields() ++ [field("apiKey", "apikey-SENTINEL")]

      assert {:ok, [indexer]} = Answer.indexers([tracker(1, fields: fields, base_url: url)])
      assert indexer.cardigann.values["password"] == @password
      assert indexer.cardigann.values["apiKey"] == "apikey-SENTINEL"
      assert indexer.cardigann.values["baseUrl"] == url

      shown = inspect(indexer, limit: :infinity, printable_limit: :infinity)
      refute shown =~ @password
      refute shown =~ "SENTINEL"
    end

    for {name, field, value} <- [
          {"no definitionFile field", "definitionFile", :drop},
          {"an empty definitionFile", "definitionFile", ""},
          {"a definitionFile that is not text", "definitionFile", 3},
          {"a baseUrl that is not text", "baseUrl", 3}
        ] do
      @field field
      @value value

      test "#{name} refuses the whole answer" do
        good = tracker(2)
        bad = update_in(tracker(1)["fields"], &edit_field(&1, @field, @value))

        assert {:ok, [_]} = Answer.indexers([good])
        assert {:error, :unexpected_response} = Answer.indexers([bad, good])
      end
    end

    defp edit_field(fields, name, :drop), do: Enum.reject(fields, &(&1["name"] == name))

    defp edit_field(fields, name, value),
      do: Enum.map(fields, &if(&1["name"] == name, do: Map.put(&1, "value", value), else: &1))

    test "a selectOptions that is not a list of labelled positions reads as no options" do
      broken = %{"value" => "x", "name" => "Size"}

      fields =
        tracker_fields()
        |> Enum.map(fn
          %{"name" => "sort"} = f -> Map.put(f, "selectOptions", [broken])
          %{"name" => "username"} = f -> Map.put(f, "selectOptions", "not a list")
          f -> f
        end)

      assert {:ok, [indexer]} = Answer.indexers([tracker(1, fields: fields)])
      assert indexer.cardigann.select_options == %{}

      unnamed =
        Enum.map(tracker_fields(), fn
          %{"name" => "sort"} = f ->
            Map.put(f, "selectOptions", [
              %{"value" => 0, "name" => 5},
              %{"value" => 1, "name" => "Size"}
            ])

          f ->
            f
        end)

      assert {:ok, [indexer]} = Answer.indexers([tracker(1, fields: unnamed)])
      assert indexer.cardigann.select_options == %{}

      assert {:ok, [indexer]} = Answer.indexers([tracker(1)])
      assert indexer.cardigann.select_options == %{"sort" => [{0, "Date"}, {1, "Size"}]}
    end
  end
end
