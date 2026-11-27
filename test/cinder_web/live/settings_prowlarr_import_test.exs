defmodule CinderWeb.SettingsProwlarrImportTest do
  # The Import from Prowlarr dialog of the indexers table (#1674), on /settings. The dialog is a
  # `<.portal>` to `body`, so a test renders it with `render(element(view, "#indexer-dialog"))`
  # and sends its events with `with_target(view, "#indexers")`, the component's root. Prowlarr's
  # answers come from `Cinder.Indexers.ProwlarrApiMock`, shaped by `Cinder.ProwlarrApiFixtures`.
  #
  # Not async: the Prowlarr source's config, the import lock, the Test runner, its supervisor and
  # the adapter map are app-wide, and the LiveView and the Test tasks reach the database through
  # the shared sandbox.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.ProwlarrApiFixtures
  import Cinder.TestRunnerHelpers

  alias Cinder.Accounts.User
  alias Cinder.Acquisition.IndexerAdapterMock
  alias Cinder.Acquisition.IndexerSource.Native.TestRunner
  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.{CallTrace, ConfigCase, Settings}
  alias Cinder.Indexers
  alias Cinder.Indexers.{ProwlarrApiMock, ProwlarrImport}
  alias Plug.Conn.Query

  @prowlarr_url "https://media.example.com/prowlarr"
  @prowlarr_key "stored-prowlarr-key-3e9a"

  setup :register_and_log_in_admin
  setup :reset_cinder_env
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

  defp dialog(lv), do: lv |> element("#indexer-dialog") |> render()

  # The portal's content as a parsed tree: a `<template>`'s content is inert, so LazyHTML finds
  # nothing inside it until the wrapper is dropped.
  defp dialog_doc(lv) do
    lv
    |> dialog()
    |> String.replace(~r/\A\s*<template[^>]*>/, "")
    |> String.replace(~r/<\/template>\s*\z/, "")
    |> LazyHTML.from_fragment()
  end

  defp has_dialog_element?(lv, selector, text \\ nil) do
    nodes = lv |> dialog_doc() |> LazyHTML.query(selector)
    Enum.any?(nodes, &(text == nil or LazyHTML.text(&1) =~ text))
  end

  defp open_import(lv), do: lv |> element("#indexers-import") |> render_click()

  defp target(lv), do: with_target(lv, "#indexers")

  # The import form's own inputs, in document order, with the values the test types over them:
  # a key of `typed` that names no input fails the test. A box posts its hidden "false", then
  # "true" when checked; Plug's decoder keeps the later value of a name, as the browser's
  # submit does.
  defp form_params(lv, typed) do
    inputs =
      lv
      |> dialog_doc()
      |> LazyHTML.query("#indexer-import-form input[name]")
      |> Enum.map(fn input ->
        attribute = &(input |> LazyHTML.attribute(&1) |> List.first())

        %{
          name: attribute.("name"),
          type: attribute.("type"),
          value: attribute.("value"),
          checked?: LazyHTML.attribute(input, "checked") != []
        }
      end)

    names = Enum.map(inputs, & &1.name)

    for name <- Map.keys(typed),
        name not in names,
        do: flunk("no input named #{name} in the form: #{inspect(names)}")

    inputs
    |> Enum.flat_map(&posted(&1, typed))
    |> URI.encode_query()
    |> Query.decode()
  end

  # What one input posts: a hidden input its value, a box "true" when ticked, a text its value.
  defp posted(%{type: "hidden"} = input, _typed), do: [{input.name, input.value}]

  defp posted(%{type: "checkbox"} = input, typed) do
    ticked? = Map.get(typed, input.name, if(input.checked?, do: "true", else: "false")) == "true"
    if ticked?, do: [{input.name, "true"}], else: []
  end

  defp posted(input, typed), do: [{input.name, Map.get(typed, input.name, input.value || "")}]

  defp change(lv, typed),
    do: lv |> target() |> render_change("import_change", form_params(lv, typed))

  defp submit(lv, typed),
    do: lv |> target() |> render_submit("import_submit", form_params(lv, typed))

  defp configured, do: Enum.sort_by(Indexers.list(), & &1.id)

  # Every byte the view process holds, the component's assigns included, as one binary.
  defp view_state(lv), do: :erlang.term_to_binary(:sys.get_state(lv.pid))

  describe "the button" do
    test "sits beside Add indexer as a plain button and opens the dialog", %{conn: conn} do
      stub_api([newznab(1, name: "NZBgeek")])
      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert has_element?(
               lv,
               "#indexers #indexers-import[type=button]:not([name])[phx-disable-with='Loading…']",
               "Import from Prowlarr"
             )

      refute has_element?(lv, "#indexer-dialog")
      open_import(lv)

      assert has_dialog_element?(lv, "#indexer-dialog-title", "Import from Prowlarr")
      assert has_dialog_element?(lv, "#indexer-dialog-box[aria-modal=true]")
      assert has_dialog_element?(lv, "#indexer-dialog-box[aria-labelledby=indexer-dialog-title]")
    end
  end

  describe "with no Prowlarr saved" do
    for {name, overrides} <- [
          {"no URL", [base_url: nil]},
          {"no API key", [api_key: nil]},
          {"a blank key", [api_key: " "]}
        ] do
      @overrides overrides

      test "#{name}: asks to save Prowlarr first, with Close, and reads nothing", %{conn: conn} do
        ConfigCase.put_config(Prowlarr, @overrides)
        expect(ProwlarrApiMock, :get, 0, fn _connection, _path, _query -> {:ok, []} end)
        {:ok, lv, _html} = live(conn, ~p"/settings")
        open_import(lv)

        assert has_dialog_element?(
                 lv,
                 "#import-message",
                 "Save Prowlarr's URL and API key first"
               )

        assert has_dialog_element?(lv, "#import-close[type=button]", "Close")
        refute has_dialog_element?(lv, "#indexer-import-form")
        assert Indexers.list() == []
      end
    end
  end

  describe "the preview" do
    test "prod's shape: three Newznab rows with a labelled key input, three Cardigann rows greyed",
         %{conn: conn} do
      stub_api(
        [
          newznab(1, name: "NZBgeek"),
          newznab(2, name: "altHUB"),
          newznab(3, name: "NinjaCentral"),
          cardigann(4, "nyaasi", name: "Nyaa.si"),
          cardigann(5, "torrent9", name: "Torrent9"),
          cardigann(6, "1337x", name: "1337x", tags: [1])
        ],
        [proxy(1, "FlareSolverr", [1])]
      )

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      for {id, name} <- [{1, "NZBgeek"}, {2, "altHUB"}, {3, "NinjaCentral"}] do
        assert has_dialog_element?(lv, "#import-row-#{id} legend", name)
        assert has_dialog_element?(lv, "#import-row-#{id}-becomes", "Newznab, searched by Cinder")
        assert has_dialog_element?(lv, "#import-row-#{id}-ticked[checked]")
        assert has_dialog_element?(lv, "#import-row-#{id}-name[value='#{name}']")

        [key] =
          lv
          |> dialog_doc()
          |> LazyHTML.query("#import-row-#{id} input[name='secrets[#{id}][api_key]']")
          |> Enum.to_list()

        key_id = key |> LazyHTML.attribute("id") |> List.first()
        assert key |> LazyHTML.attribute("type") == ["password"]
        assert key |> LazyHTML.attribute("phx-update") == ["ignore"]
        assert has_dialog_element?(lv, "label[for='#{key_id}']", "API key")
        assert has_dialog_element?(lv, "label[for='import-row-#{id}-name']", "Name in Cinder")
        assert has_dialog_element?(lv, "label[for='import-row-#{id}-ticked']", "Import")
      end

      for {id, name} <- [{4, "Nyaa.si"}, {5, "Torrent9"}, {6, "1337x"}] do
        assert has_dialog_element?(lv, "#import-row-#{id}.import-row-greyed legend", name)

        assert has_dialog_element?(
                 lv,
                 "#import-row-#{id}-becomes",
                 "Not imported: indexer definitions not loaded yet"
               )

        refute has_dialog_element?(lv, "#import-row-#{id} input")
      end
    end

    test "an already imported row is greyed with no tick; a C# row offers Prowlarr unticked; a //host path is refused",
         %{conn: conn} do
      stub_api([newznab(1, name: "Linked")])
      {:ok, preview} = ProwlarrImport.preview()

      {:ok, _report} =
        ProwlarrImport.commit(preview, %{
          1 => %{ticked: true, name: "Linked", via_prowlarr: false, secrets: %{}}
        })

      stub_api([
        newznab(1, name: "Linked"),
        csharp(2, "BroadcastheNet", "torrent", name: "BTN"),
        newznab(3, name: "Evil", api_path: "//evil.example/api")
      ])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      assert has_dialog_element?(lv, "#import-row-1.import-row-greyed")
      assert has_dialog_element?(lv, "#import-row-1-becomes", "Already imported")
      refute has_dialog_element?(lv, "#import-row-1 input")
      assert has_dialog_element?(lv, "#import-submit")

      assert has_dialog_element?(
               lv,
               "#import-row-2-becomes",
               "Torznab, searched through Prowlarr"
             )

      assert has_dialog_element?(
               lv,
               "#import-row-2-reasons",
               "Cinder can't search a BroadcastheNet indexer itself."
             )

      assert has_dialog_element?(lv, "#import-row-2-via[type=checkbox]:not([checked])")
      assert has_dialog_element?(lv, "label[for=import-row-2-via]", "Add it through Prowlarr")
      refute has_dialog_element?(lv, "#import-row-2-ticked")
      refute has_dialog_element?(lv, "#import-row-2 input[name^=secrets]")

      assert has_dialog_element?(lv, "#import-row-3.import-row-greyed")
      assert has_dialog_element?(lv, "#import-row-3-becomes", "Can't be imported")

      assert has_dialog_element?(
               lv,
               "#import-row-3-reasons",
               "API path: Enter a path that starts with a single /, such as /api."
             )

      refute has_dialog_element?(lv, "#import-row-3 input")
    end

    test "with no row to tick, the dialog offers Cancel and no Import", %{conn: conn} do
      stub_api([
        cardigann(1, "nyaasi", name: "Nyaa"),
        newznab(2, name: "Evil", api_path: "//e.example/api")
      ])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      assert has_dialog_element?(lv, "#import-close", "Cancel")
      refute has_dialog_element?(lv, "#import-submit")
    end

    test "a row behind a proxy, Torznab parameters or the global proxy says why it goes through Prowlarr",
         %{conn: conn} do
      stub_api(
        [
          newznab(1, name: "Http", tags: [1]),
          newznab(2, name: "Socks", tags: [2]),
          newznab(3, name: "Flare", tags: [3]),
          torznab(4, name: "Params", additional_parameters: "&cat=5000")
        ],
        [proxy(11, "Http", [1]), proxy(12, "Socks5", [2]), proxy(13, "FlareSolverr", [3])]
      )

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      for {id, text} <- [
            {1, "It goes through an HTTP proxy in Prowlarr."},
            {2, "It goes through a SOCKS proxy in Prowlarr."},
            {3,
             "It goes through FlareSolverr in Prowlarr, which Cinder uses for Cardigann only."},
            {4, "It has additional parameters, which Cinder keeps for Newznab only."}
          ] do
        assert has_dialog_element?(lv, "#import-row-#{id}-reasons", text)
        assert has_dialog_element?(lv, "#import-row-#{id}-via")
      end

      lv |> target() |> render_click("close", %{})
      stub_api([newznab(1, name: "Global")], [], host(true))
      open_import(lv)

      assert has_dialog_element?(lv, "#import-row-1-reasons", "Prowlarr's global proxy is on.")
      assert has_dialog_element?(lv, "#import-row-1-via")
    end

    test "a through-Prowlarr row's box imports it through Prowlarr; unticked, it creates nothing",
         %{conn: conn} do
      stub_api([csharp(2, "BroadcastheNet", "torrent", name: "BTN"), newznab(3, name: "Three")])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      submit(lv, %{})
      assert for(c <- configured(), do: c.prowlarr_indexer_id) == [3]

      lv |> target() |> render_click("close", %{})
      stub_api([csharp(2, "BroadcastheNet", "torrent", name: "BTN"), newznab(3, name: "Three")])
      open_import(lv)
      submit(lv, %{"rows[2][via_prowlarr]" => "true"})

      assert [_three, btn] = configured()
      assert {btn.prowlarr_indexer_id, btn.name, btn.type} == {2, "BTN", :torznab}
      assert btn.base_url == @prowlarr_url
      assert btn.api_path == "/2/api"
    end

    test "the notes list the settings the import does not carry", %{conn: conn} do
      # The fixture's own limit fields are unset, and a second field of one name makes the
      # answer unreadable, so the test sets their values in place.
      stub_api([
        Map.update!(newznab(1), "fields", fn fields ->
          Enum.map(fields, fn
            %{"name" => "baseSettings.queryLimit"} = f -> Map.put(f, "value", 100)
            %{"name" => "baseSettings.queryTimeout"} = f -> Map.put(f, "value", 30)
            f -> f
          end)
        end)
      ])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      assert has_dialog_element?(
               lv,
               "#import-row-1-notes",
               "Not carried: app profile, query limit, query timeout."
             )
    end
  end

  describe "names" do
    test "two ticked rows with one name show an error on each and create nothing; a rename creates both",
         %{conn: conn} do
      stub_api([newznab(1, name: "Same", api_key: nil), newznab(2, name: "Same", api_key: nil)])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      submit(lv, %{})
      assert configured() == []

      for id <- [1, 2] do
        assert has_dialog_element?(
                 lv,
                 "#import-row-#{id}-errors[role=alert] > ul > li",
                 "Another ticked indexer has this name."
               )

        assert has_dialog_element?(
                 lv,
                 "#import-row-#{id}-name[aria-describedby=import-row-#{id}-errors][aria-invalid=true]"
               )
      end

      assert_push_event(lv, "focus-invalid", %{id: "import-row-1-name"})

      submit(lv, %{"rows[2][name]" => "Other"})
      assert for(c <- configured(), do: c.name) == ["Same", "Other"]
    end

    test "a name another indexer holds is an error on its row", %{conn: conn} do
      {:ok, _} =
        Indexers.create(nil, %{
          name: "Taken",
          type: :newznab,
          base_url: "https://t.example",
          api_path: "/api"
        })

      stub_api([newznab(1, name: "Taken", api_key: nil)])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)
      submit(lv, %{})

      assert has_dialog_element?(
               lv,
               "#import-row-1-errors",
               "Another indexer already has this name."
             )

      assert has_dialog_element?(lv, "#import-row-1-name[aria-invalid=true]")
      assert length(configured()) == 1
    end
  end

  describe "keys" do
    @key "SYNTH-import-key-7a1c"
    @other_key "SYNTH-import-key-unticked-4e2d"

    test "a key typed, then another row renamed, creates its indexer enabled with that key",
         %{conn: conn} do
      stub_api([newznab(1, name: "One"), newznab(2, name: "Two")])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      typed = %{"secrets[1][api_key]" => @key}
      change(lv, typed)
      change(lv, Map.put(typed, "rows[2][name]", "Two renamed"))

      # The key input of row 1 keeps its id across the re-render, so the browser keeps its value.
      assert has_dialog_element?(lv, "#import-row-1 input[name='secrets[1][api_key]']")
      refute render(lv) =~ @key
      refute dialog(lv) =~ @key

      submit(lv, Map.put(typed, "rows[2][name]", "Two renamed"))

      assert [one, two] = configured()
      assert {one.name, one.enabled} == {"One", true}
      assert {two.name, two.enabled} == {"Two renamed", false}
      assert {:ok, %{secrets: %{"api_key" => @key}}} = Indexers.fetch_with_secrets(one.id)
      assert {:ok, %{secrets: two_secrets}} = Indexers.fetch_with_secrets(two.id)
      assert two_secrets == %{}

      assert has_dialog_element?(lv, "#import-report-1", "One: created")
      refute has_dialog_element?(lv, "#import-report-1", "created disabled")

      assert has_dialog_element?(
               lv,
               "#import-report-2",
               "Two renamed: API key not entered: created disabled"
             )

      refute render(lv) =~ @key
      refute dialog(lv) =~ @key
      refute view_state(lv) =~ @key
    end

    test "a key typed in an unticked row reaches no commit call and no assign", %{conn: conn} do
      stub_api([newznab(1, name: "One"), newznab(2, name: "Two")])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      typed = %{
        "secrets[1][api_key]" => @key,
        "secrets[2][api_key]" => @other_key,
        "rows[2][ticked]" => "false",
        "rows[1][name]" => "Typed name"
      }

      change(lv, typed)
      # The positive control: the typed name is in the view's state, the keys are not.
      assert view_state(lv) =~ "Typed name"
      refute view_state(lv) =~ @key
      refute view_state(lv) =~ @other_key

      {_html, [call]} =
        CallTrace.calls(
          {ProwlarrImport, :commit, 4},
          fn -> submit(lv, typed) end,
          pid: lv.pid
        )

      assert [_preview, choices, actor, [save_flaresolverr_url: false]] = call.args
      assert %User{} = actor

      assert choices == %{
               1 => %{
                 ticked: true,
                 name: "Typed name",
                 via_prowlarr: false,
                 secrets: %{"api_key" => @key}
               },
               2 => %{ticked: false, name: "Two", via_prowlarr: false, secrets: %{}}
             }

      assert for(c <- configured(), do: c.name) == ["Typed name"]
      refute view_state(lv) =~ @key
      refute view_state(lv) =~ @other_key
    end

    test "a forged secret reaches the commit only as the api_key of a row with a key input",
         %{conn: conn} do
      stub_api([
        newznab(1, name: "Masked"),
        newznab(2, name: "No key", api_key: nil),
        csharp(3, "BroadcastheNet", "torrent", name: "BTN")
      ])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      params =
        lv
        |> form_params(%{"secrets[1][api_key]" => @key, "rows[3][via_prowlarr]" => "true"})
        |> put_in(["secrets", "1", "clear_api_key"], "true")
        |> put_in(["secrets", "2"], %{"api_key" => @other_key})
        |> put_in(["secrets", "3"], %{"api_key" => @other_key})

      {_html, [call]} =
        CallTrace.calls(
          {ProwlarrImport, :commit, 4},
          fn -> lv |> target() |> render_submit("import_submit", params) end,
          pid: lv.pid
        )

      assert [_preview, choices, _actor, _opts] = call.args

      assert for({id, choice} <- choices, into: %{}, do: {id, choice.secrets}) == %{
               1 => %{"api_key" => @key},
               2 => %{},
               3 => %{}
             }

      assert [masked, no_key, btn] = configured()
      assert {:ok, %{secrets: %{"api_key" => @key}}} = Indexers.fetch_with_secrets(masked.id)
      assert {:ok, %{secrets: no_key_secrets}} = Indexers.fetch_with_secrets(no_key.id)
      assert no_key_secrets == %{}

      assert {:ok, %{secrets: %{"api_key" => @prowlarr_key}}} =
               Indexers.fetch_with_secrets(btn.id)
    end
  end

  describe "a refused batch" do
    test "a change in Prowlarr shows the alert and the new preview, whose key inputs are new",
         %{conn: conn} do
      stub_api([newznab(1, name: "One")])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      [old_id] = key_ids(lv)
      stub_api([newznab(1, name: "One", base_url: "https://moved.example")])
      submit(lv, %{"secrets[1][api_key]" => @key})

      assert configured() == []

      assert has_dialog_element?(
               lv,
               "#import-alert[role=alert]",
               "Prowlarr or a definition changed: check the preview again."
             )

      assert_push_event(lv, "focus-invalid", %{id: "import-alert"})
      assert [new_id] = key_ids(lv)
      assert new_id != old_id
      refute has_dialog_element?(lv, "#import-row-1 input[name^=secrets][value]")
      refute render(lv) =~ @key
      refute dialog(lv) =~ @key
      refute view_state(lv) =~ @key

      submit(lv, %{"secrets[1][api_key]" => @key})
      assert [%{base_url: "https://moved.example"}] = configured()
    end

    test "another import running shows its text and keeps the preview", %{conn: conn} do
      stub_api([newznab(1, name: "One", api_key: nil)])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      test_pid = self()

      holder =
        start_supervised!(
          {Task,
           fn ->
             true = :global.set_lock({ProwlarrImport, self()}, [node()], 0)
             send(test_pid, :locked)

             receive do
               :release -> :ok
             end
           end},
          id: make_ref()
        )

      assert_receive :locked
      submit(lv, %{})
      send(holder, :release)

      assert has_dialog_element?(
               lv,
               "#import-alert",
               "Another import is running. Try again when it ends."
             )

      assert has_dialog_element?(lv, "#import-row-1")
      assert configured() == []
    end
  end

  defp key_ids(lv) do
    lv
    |> dialog_doc()
    |> LazyHTML.query("#indexer-import-form input[name^=secrets]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> List.first()))
  end

  describe "the report" do
    test "says Cinder tests what it created and keeps the source, and the rows show their Tests",
         %{conn: conn} do
      stub_api([newznab(1, name: "Linked", api_key: nil)])
      {:ok, preview} = ProwlarrImport.preview()

      {:ok, _report} =
        ProwlarrImport.commit(preview, %{
          1 => %{ticked: true, name: "Linked", via_prowlarr: false, secrets: %{}}
        })

      [%{id: linked}] = configured()
      assert_receive {:test_started, linked_task, ^linked}
      answer(linked_task, :test_success)
      assert_receive {TestRunner, :finished, ^linked, _result}

      stub_api([newznab(1, name: "Linked"), newznab(2, name: "Two")])
      source_before = Settings.get("indexer_source")
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)
      submit(lv, %{"secrets[2][api_key]" => @key})

      assert [_linked, %{id: id}] = configured()
      assert_receive {:test_started, _task, ^id}

      assert has_dialog_element?(lv, "#import-report-2", "Two: created")

      assert has_dialog_element?(
               lv,
               ".import-report-skipped",
               "Linked: already imported, skipped"
             )

      assert has_dialog_element?(
               lv,
               "#import-report-testing",
               "Cinder is testing each enabled indexer it created."
             )

      assert has_dialog_element?(
               lv,
               "#import-report-source",
               "The indexer source stays as it was."
             )

      assert has_dialog_element?(
               lv,
               "#import-close[aria-describedby='import-report import-report-testing import-report-source']"
             )

      render(lv)
      assert has_element?(lv, "#indexer-#{id}-test[disabled] .loading-spinner")
      assert Settings.get("indexer_source") == source_before

      lv |> target() |> render_click("close", %{})
      refute has_element?(lv, "#indexer-dialog")
      assert_push_event(lv, "focus-invalid", %{id: "indexers-import"})
    end

    test "an import that starts no Test leaves out the testing line", %{conn: conn} do
      stub_api([newznab(1, name: "One")])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)
      submit(lv, %{})

      assert [%{enabled: false}] = configured()
      assert has_dialog_element?(lv, "#import-report-1", "created disabled")
      refute has_dialog_element?(lv, "#import-report-testing")
      assert has_dialog_element?(lv, "#import-report-source")

      assert has_dialog_element?(
               lv,
               "#import-close[aria-describedby='import-report import-report-source']"
             )
    end
  end

  describe "errors" do
    for {tag, text} <- [
          {:timeout, "Couldn't reach Prowlarr. Try again."},
          {:transport, "Couldn't reach Prowlarr. Try again."},
          {{:http_status, 401}, "Prowlarr refused the API key. Check it in the Indexers group."},
          {{:http_status, 500}, "Prowlarr gave an answer Cinder can't read."},
          {:too_large, "Prowlarr gave an answer Cinder can't read."},
          {:invalid_json, "Prowlarr gave an answer Cinder can't read."}
        ] do
      @tag_answer tag
      @text text

      test "a preview read answering #{inspect(tag)} shows its text", %{conn: conn} do
        stub_api(fn -> {:error, @tag_answer} end)
        {:ok, lv, _html} = live(conn, ~p"/settings")
        open_import(lv)

        assert has_dialog_element?(lv, "#import-message[role=alert]", @text)
        refute has_dialog_element?(lv, "#indexer-import-form")
      end
    end

    test "an answer the import cannot read shows its text", %{conn: conn} do
      stub_api([%{"id" => "not an indexer"}])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      assert has_dialog_element?(
               lv,
               "#import-message",
               "Prowlarr gave an answer Cinder can't read."
             )
    end

    test "a commit with nothing ticked says so", %{conn: conn} do
      stub_api([newznab(1, name: "One")])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)
      submit(lv, %{"rows[1][ticked]" => "false"})

      assert has_dialog_element?(lv, "#import-alert", "Tick at least one indexer to import.")
      assert configured() == []
    end
  end

  describe "forged events" do
    test "an unknown id, a row with no tick, and non-map values change nothing", %{conn: conn} do
      stub_api([
        newznab(1, name: "One", api_key: nil),
        cardigann(2, "nyaasi", name: "Nyaa"),
        newznab(3, name: "Three", api_key: nil)
      ])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      for params <- [
            %{"rows" => "x"},
            %{"rows" => %{"1" => "x"}},
            %{"rows" => %{"01" => %{"name" => "Leading zero"}}},
            %{"rows" => %{"1" => %{"name" => %{"a" => "b"}, "ticked" => "maybe"}}},
            %{"rows" => %{"99" => %{"ticked" => "true", "name" => "Ghost"}}},
            %{"rows" => %{"2" => %{"ticked" => "true", "name" => "Held"}}}
          ] do
        lv |> target() |> render_change("import_change", params)
      end

      assert has_dialog_element?(lv, "#import-row-1-name[value=One]")

      lv
      |> target()
      |> render_submit("import_submit", %{
        "rows" => %{
          "1" => %{"ticked" => "true", "via_prowlarr" => "true"},
          "2" => %{"ticked" => "true", "name" => "Held"},
          "99" => %{"ticked" => "true", "name" => "Ghost"},
          "3" => %{"ticked" => "false"}
        },
        "secrets" => "not a map"
      })

      assert for(c <- configured(), do: {c.prowlarr_indexer_id, c.name}) == [{1, "One"}]
      assert Process.alive?(lv.pid)

      # The report holds no preview: another submit, and a change, change nothing.
      lv
      |> target()
      |> render_submit("import_submit", %{"rows" => %{"3" => %{"ticked" => "true"}}})

      lv |> target() |> render_change("import_change", %{"rows" => %{"3" => %{"name" => "X"}}})
      assert length(configured()) == 1
      assert has_dialog_element?(lv, "#import-dialog-report")
    end

    test "secrets that are not a map, or an api_key that is not text, are refused on a key row",
         %{conn: conn} do
      stub_api([newznab(1, name: "One")])
      {:ok, lv, _html} = live(conn, ~p"/settings")

      for secrets <- ["flat", %{"1" => "flat"}, %{"1" => %{"api_key" => %{"x" => "y"}}}] do
        open_import(lv)

        lv
        |> target()
        |> render_submit("import_submit", %{
          "rows" => %{"1" => %{"ticked" => "true", "name" => "One"}},
          "secrets" => secrets
        })

        assert has_dialog_element?(lv, "#import-row-1-errors", "Enter the API key as plain text.")
        assert configured() == []
        lv |> target() |> render_click("close")
      end
    end

    test "with no dialog open, an import event changes nothing", %{conn: conn} do
      stub_api([newznab(1, name: "One", api_key: nil)])
      {:ok, lv, _html} = live(conn, ~p"/settings")

      lv
      |> target()
      |> render_submit("import_submit", %{"rows" => %{"1" => %{"ticked" => "true"}}})

      lv |> target() |> render_change("import_change", %{"rows" => %{}})
      refute has_element?(lv, "#indexer-dialog")
      assert configured() == []
    end
  end
end
