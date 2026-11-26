defmodule CinderWeb.SettingsIndexerDialogsTest do
  # The Add and Edit dialogs of the indexers table in /settings (#1661). Each dialog is a
  # `<.portal>` to `body`, so the view's selectors do not reach its content: a test renders the
  # portal with `render(element(view, "#indexer-dialog"))` and sends its events with
  # `with_target(view, "#indexers")`, the component's root. The names of the submitted fields
  # come from the rendered form (`form_params/2`), so a misnamed input fails here too.
  #
  # Not async: the Test runner, its supervisor, Native's clock, the adapter map and the Logger
  # level are app-wide, and the LiveView and the Test tasks reach the database through the
  # shared sandbox.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.NewznabFixtures, only: [indexer!: 3, undecryptable!: 1]
  import Cinder.TestRunnerHelpers
  import ExUnit.CaptureLog

  alias Cinder.Acquisition.IndexerSource.{Native, Prowlarr}
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerStatus, TestRunner}
  alias Cinder.{ConfigCase, DefinitionFixtures}
  alias Cinder.Indexers
  alias Cinder.Indexers.ConfiguredIndexer

  @now ~U[2026-11-26 12:00:00Z]
  @key "SYNTH-key-5f0e1d2c3b4a"

  setup :register_and_log_in_admin
  setup :reset_cinder_env
  setup {Mox, :set_mox_global}

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    block_tests()
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

  defp target(lv), do: with_target(lv, "#indexers")

  defp open_add(lv, type) do
    lv |> element("#indexers-add") |> render_click()
    lv |> target() |> render_click("pick", %{"type" => type})
  end

  defp open_edit(lv, id), do: lv |> element("#indexer-#{id}-edit") |> render_click()

  # The form's own field names with the values the test types over them: every input of
  # `#indexer-form` must be named in `typed`, or carry its rendered value. A key of `typed` that
  # names no input fails the test.
  defp form_params(lv, typed) do
    inputs =
      lv
      |> dialog_doc()
      |> LazyHTML.query("#indexer-form input[name]")
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

    Enum.reduce(inputs, %{}, fn input, acc ->
      value =
        cond do
          Map.has_key?(typed, input.name) -> Map.fetch!(typed, input.name)
          input.type == "checkbox" -> if input.checked?, do: input.value
          true -> input.value || ""
        end

      if value == nil, do: acc, else: put_param(acc, input.name, value)
    end)
  end

  # "a[b]" puts b under a, as Plug's query decoder does; a later input of the same name wins.
  defp put_param(acc, name, value) do
    case Regex.run(~r/\A([^\[]+)\[([^\]]+)\]\z/, name) do
      [_whole, outer, inner] ->
        Map.update(acc, outer, %{inner => value}, &Map.put(&1, inner, value))

      nil ->
        Map.put(acc, name, value)
    end
  end

  defp submit(lv, typed), do: lv |> target() |> render_submit("save", form_params(lv, typed))

  describe "Add" do
    test "picks Newznab, fills the form and saves it with priority 25, then lists it",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv, "newznab")

      submit(lv, %{
        "indexer[name]" => "My Usenet",
        "indexer[base_url]" => "https://nzb.example",
        "indexer[api_path]" => "/api",
        "secrets[api_key]" => @key
      })

      assert [row] = Indexers.list()

      assert %{name: "My Usenet", type: :newznab, base_url: "https://nzb.example"} = row
      assert %{api_path: "/api", priority: 25, enabled: true} = row
      assert {:ok, %{secrets: %{"api_key" => @key}}} = Indexers.fetch_with_secrets(row.id)
      assert has_element?(lv, "#indexer-#{row.id}", "My Usenet")
      assert has_element?(lv, "#indexers-notice", "My Usenet added.")
      refute has_element?(lv, "#indexer-dialog")
    end

    test "the Add button is a plain button that opens step 1, a search over both types",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexers-add[type=button]:not([name])", "Add indexer")
      refute has_element?(lv, "#indexer-dialog")

      lv |> element("#indexers-add") |> render_click()

      assert has_dialog_element?(lv, "label[for=indexer-kind-query]", "Search indexer types")
      assert has_dialog_element?(lv, "#indexer-kind-query[type=search]")

      assert has_dialog_element?(
               lv,
               "#indexer-kind-newznab",
               "Any Usenet indexer with an API key"
             )

      assert has_dialog_element?(
               lv,
               "#indexer-kind-torznab",
               "Any torrent indexer with a Torznab API, or Jackett and Prowlarr"
             )

      lv |> target() |> render_change("search", %{"query" => "torz"})
      assert has_dialog_element?(lv, "#indexer-kind-torznab")
      refute has_dialog_element?(lv, "#indexer-kind-newznab")

      lv |> target() |> render_change("search", %{"query" => "USENET"})
      assert has_dialog_element?(lv, "#indexer-kind-newznab")
      refute has_dialog_element?(lv, "#indexer-kind-torznab")

      lv |> target() |> render_change("search", %{"query" => "nothing like it"})
      refute has_dialog_element?(lv, "#indexer-kinds button")
      assert has_dialog_element?(lv, "#indexer-kinds-none", "No indexer type matches.")
    end

    test "step 2 has Back, Cancel and Save and test; Back returns to step 1", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv, "torznab")

      assert has_dialog_element?(lv, "#indexer-form-kind", "Torznab")
      assert has_dialog_element?(lv, "#indexer-form-back[type=button]", "Back")
      assert has_dialog_element?(lv, "#indexer-form button[type=button]", "Cancel")
      assert has_dialog_element?(lv, "#indexer-form-save[type=submit]", "Save and test")

      lv |> target() |> render_click("back", %{})
      assert has_dialog_element?(lv, "#indexer-kind-query")
      refute has_dialog_element?(lv, "#indexer-form")

      lv |> target() |> render_click("close", %{})
      refute has_element?(lv, "#indexer-dialog")
    end

    test "the Newznab form has an additional parameters field, the Torznab form none, and neither a FlareSolverr one",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")

      open_add(lv, "newznab")

      assert lv |> form_params(%{}) |> Map.keys() |> Enum.sort() == ["indexer", "secrets"]

      assert lv |> form_params(%{}) |> Map.fetch!("indexer") |> Map.keys() |> Enum.sort() ==
               ~w(additional_parameters api_path base_url enabled name priority)

      assert has_dialog_element?(
               lv,
               "label[for=indexer-form-additional-parameters]",
               "Additional parameters"
             )

      lv |> target() |> render_click("back", %{})
      lv |> target() |> render_click("pick", %{"type" => "torznab"})

      assert lv |> form_params(%{}) |> Map.fetch!("indexer") |> Map.keys() |> Enum.sort() ==
               ~w(api_path base_url enabled name priority)

      refute dialog(lv) =~ ~r/flaresolverr/i
    end

    test "the form opens with priority 25, enabled, its help, and the save line",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv, "newznab")

      assert has_dialog_element?(lv, "#indexer-form-priority[value='25']")
      assert has_dialog_element?(lv, "#indexer-form-enabled[checked]")

      assert has_dialog_element?(
               lv,
               "#indexer-form-priority-help",
               "1 to 50. A lower number comes first in results."
             )

      assert has_dialog_element?(
               lv,
               "#indexer-form-priority[aria-describedby~=indexer-form-priority-help]"
             )

      assert has_dialog_element?(
               lv,
               "#indexer-form",
               "Cinder tests an enabled indexer when you save it."
             )

      refute has_dialog_element?(lv, "#indexer-form-drops")
    end

    test "creating an enabled indexer starts one Test, a disabled one none", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv, "newznab")
      submit(lv, filled("Off", %{"indexer[enabled]" => "false"}))
      assert [%{enabled: false}] = Indexers.list()
      assert TestRunner.running() == MapSet.new()

      open_add(lv, "newznab")
      submit(lv, filled("On"))
      assert [%{name: "Off"}, %{name: "On", id: id}] = Enum.sort_by(Indexers.list(), & &1.name)
      assert_receive {:test_started, _task_pid, ^id}
      assert TestRunner.running() == MapSet.new([id])
      refute_received {:test_started, _task_pid, _other}
    end
  end

  # The typed fields of a valid Newznab or Torznab add, with `overrides` on top.
  defp filled(name, overrides \\ %{}) do
    Map.merge(
      %{
        "indexer[name]" => name,
        "indexer[base_url]" => "https://#{String.downcase(name)}.example",
        "secrets[api_key]" => @key
      },
      Map.new(overrides)
    )
  end

  defp change(lv, typed), do: lv |> target() |> render_change("change", form_params(lv, typed))

  describe "the dialog" do
    test "is a portal to body, a labelled modal, and every input has a label", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{settings: %{"additional_parameters" => "&c=1"}})
      {:ok, lv, _html} = live(conn, ~p"/settings")

      for open <- [fn -> open_add(lv, "newznab") end, fn -> open_edit(lv, indexer.id) end] do
        open.()
        assert dialog(lv) =~ ~r/\A\s*<template id="indexer-dialog" data-phx-portal="body">/

        assert has_dialog_element?(
                 lv,
                 "[role=dialog][aria-modal=true][aria-labelledby=indexer-dialog-title]"
               )

        assert has_dialog_element?(lv, "[phx-hook='Phoenix.FocusWrap'][role=dialog]")

        assert has_dialog_element?(
                 lv,
                 "#indexer-dialog-backdrop[phx-key=Escape][phx-window-keydown]"
               )

        assert has_dialog_element?(lv, "h2#indexer-dialog-title")
        doc = dialog_doc(lv)

        inputs =
          for input <- LazyHTML.query(doc, "input:not([type=hidden])"),
              do: input |> LazyHTML.attribute("id") |> List.first()

        assert length(inputs) >= 6

        for id <- inputs,
            do: assert(Enum.count(LazyHTML.query(doc, "label[for='#{id}']")) == 1, id)

        lv |> target() |> render_click("close", %{})
      end
    end

    test "Edit opens the same form with Cancel and Save, the row's values and the drops line",
         %{conn: conn} do
      indexer =
        indexer!(:newznab, "a.example", %{
          priority: 7,
          settings: %{"additional_parameters" => "&cat=2000"}
        })

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexer-#{indexer.id}-edit[type=button]:not([name])", "Edit")
      open_edit(lv, indexer.id)

      assert form_params(lv, %{})["indexer"] == %{
               "name" => indexer.name,
               "base_url" => "https://a.example",
               "api_path" => "/api",
               "additional_parameters" => "&cat=2000",
               "priority" => "7",
               "enabled" => "true"
             }

      assert has_dialog_element?(lv, "#indexer-form-kind", "Newznab")
      assert has_dialog_element?(lv, "#indexer-form-save[type=submit]", "Save")
      refute has_dialog_element?(lv, "#indexer-form-save", "Save and test")
      refute has_dialog_element?(lv, "#indexer-form-back")

      assert has_dialog_element?(
               lv,
               "#indexer-form",
               "Cinder tests an enabled indexer when you save it."
             )

      assert has_dialog_element?(
               lv,
               "#indexer-form-drops",
               "A new base URL or any changed credential drops this indexer's grabs still waiting to be sent: movies and episodes search again, books wait for you."
             )

      submit(lv, %{"indexer[name]" => "Renamed"})
      assert has_element?(lv, "#indexers-notice", "Renamed saved.")
      refute has_element?(lv, "#indexer-dialog")
    end

    test "a Cardigann row has no Edit button", %{conn: conn} do
      base = DefinitionFixtures.definition()
      DefinitionFixtures.mirror!(base)
      cardigann = DefinitionFixtures.cardigann!(base)
      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexer-#{cardigann.id}")
      refute has_element?(lv, "#indexer-#{cardigann.id}-edit")
      lv |> target() |> render_click("open_edit", %{"id" => to_string(cardigann.id)})
      refute has_element?(lv, "#indexer-dialog")
    end

    test "the secret input ignores patches and gets a new id on each open", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")

      ids =
        for _open <- 1..2 do
          open_edit(lv, indexer.id)

          [input] =
            lv
            |> dialog_doc()
            |> LazyHTML.query("input[name='secrets[api_key]']")
            |> Enum.to_list()

          assert LazyHTML.attribute(input, "phx-update") == ["ignore"]
          assert LazyHTML.attribute(input, "type") == ["password"]
          lv |> target() |> render_click("close", %{})
          input |> LazyHTML.attribute("id") |> List.first()
        end

      assert length(Enum.uniq(ids)) == 2
    end
  end

  describe "focus on close" do
    test "goes back to the button that opened the dialog, on a close and on a save",
         %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")

      lv |> element("#indexers-add") |> render_click()
      lv |> target() |> render_click("close", %{})
      assert_push_event(lv, "focus-invalid", %{id: "indexers-add"})

      open_add(lv, "torznab")
      submit(lv, filled("Added"))
      assert_push_event(lv, "focus-invalid", %{id: "indexers-add"})

      edit = "indexer-#{indexer.id}-edit"
      open_edit(lv, indexer.id)
      lv |> target() |> render_click("close", %{})
      assert_push_event(lv, "focus-invalid", %{id: ^edit})

      open_edit(lv, indexer.id)
      submit(lv, %{"indexer[name]" => "Renamed"})
      assert_push_event(lv, "focus-invalid", %{id: ^edit})
      assert has_element?(lv, "##{edit}")
    end

    test "goes to Add indexer when the edited indexer was deleted, whose row goes",
         %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, indexer.id)
      :ok = Indexers.delete(nil, indexer.id)
      submit(lv, %{"indexer[name]" => "Mine"})
      assert has_dialog_element?(lv, "#indexer-form-deleted")

      lv |> target() |> render_click("close", %{})
      assert_push_event(lv, "focus-invalid", %{id: "indexers-add"})
      refute has_element?(lv, "#indexer-#{indexer.id}")
    end

    test "a save of a refused form whose indexer was deleted moves no focus to a field",
         %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, indexer.id)
      submit(lv, %{"indexer[priority]" => "0"})
      assert_push_event(lv, "focus-invalid", %{id: "indexer-form-priority"})

      :ok = Indexers.delete(nil, indexer.id)
      submit(lv, %{"indexer[priority]" => "0"})
      assert has_dialog_element?(lv, "#indexer-form-deleted")
      refute_push_event(lv, "focus-invalid", %{})
    end

    test "goes to Add indexer when a reload dropped the edited indexer's row", %{conn: conn} do
      edited = indexer!(:newznab, "a.example", %{})
      other = indexer!(:newznab, "b.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, edited.id)
      :ok = Indexers.delete(nil, edited.id)

      # Another indexer's Test finish reads the rows again, which drops the edited one's row.
      id = other.id
      :ok = TestRunner.start(id)
      assert_receive {:test_started, task_pid, ^id}
      answer(task_pid, :test_success)
      assert_receive {TestRunner, :finished, ^id, {:ok, _}}
      eventually(fn -> not has_element?(lv, "#indexer-#{edited.id}") end)

      lv |> target() |> render_click("close", %{})
      assert_push_event(lv, "focus-invalid", %{id: "indexers-add"})
    end

    test "a close with no dialog open pushes nothing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> target() |> render_click("close", %{})
      refute_push_event(lv, "focus-invalid", %{})
    end
  end

  describe "the API key" do
    setup %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      %{indexer: indexer, lv: lv}
    end

    defp stored_key(indexer) do
      {:ok, row} = Indexers.fetch_with_secrets(indexer.id)
      row.secrets["api_key"]
    end

    # Neither the fixture's stored key nor the typed one shows in the view, the portal or the
    # LiveView's state, assigns included.
    defp refute_key_anywhere(lv, keys) do
      state = inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity)
      # The state holds the indexers component's assigns, its rows included.
      assert state =~ "only_source?:"
      assert state =~ "secrets_readable: true"
      portal = if has_element?(lv, "#indexer-dialog"), do: dialog(lv), else: ""

      for key <- keys do
        refute render(lv) =~ key
        refute portal =~ key
        refute state =~ key
      end
    end

    test "a saved key renders an empty input with the saved placeholder and a Clear box",
         %{lv: lv, indexer: indexer} do
      open_edit(lv, indexer.id)

      [input] =
        lv |> dialog_doc() |> LazyHTML.query("input[name='secrets[api_key]']") |> Enum.to_list()

      assert LazyHTML.attribute(input, "value") == []
      assert LazyHTML.attribute(input, "placeholder") == ["•••• saved (leave blank to keep)"]
      assert has_dialog_element?(lv, "label[for=indexer-form-clear-api-key]", "Clear saved value")
      assert has_dialog_element?(lv, "input[name='secrets[clear_api_key]'][type=checkbox]")
      refute_key_anywhere(lv, [stored_key(indexer)])
    end

    test "the Add form has no saved placeholder and no Clear box", %{lv: lv} do
      open_add(lv, "torznab")

      [input] =
        lv |> dialog_doc() |> LazyHTML.query("input[name='secrets[api_key]']") |> Enum.to_list()

      assert LazyHTML.attribute(input, "placeholder") in [[], [""]]
      refute has_dialog_element?(lv, "#indexer-form-clear-api-key")
    end

    test "is never rendered or assigned, after a change, a failed submit and a save",
         %{lv: lv, indexer: indexer} do
      keys = [stored_key(indexer), @key]
      open_edit(lv, indexer.id)
      change(lv, %{"secrets[api_key]" => @key, "indexer[name]" => "Typed"})
      assert form_params(lv, %{})["indexer"]["name"] == "Typed"
      refute_key_anywhere(lv, keys)

      submit(lv, %{"secrets[api_key]" => @key, "indexer[priority]" => "0"})
      assert has_dialog_element?(lv, "#indexer-form-priority-error")
      refute_key_anywhere(lv, keys)

      submit(lv, %{"secrets[api_key]" => @key, "indexer[priority]" => "3"})
      assert has_element?(lv, "#indexers-notice", "Typed saved.")
      refute_key_anywhere(lv, keys)
      assert stored_key(indexer) == @key
    end

    test "a blank key keeps the stored one, Clear removes it, a typed one replaces it",
         %{lv: lv, indexer: indexer} do
      before = stored_key(indexer)
      assert before not in [nil, @key]

      open_edit(lv, indexer.id)
      submit(lv, %{"secrets[api_key]" => "", "indexer[name]" => "Kept"})
      assert stored_key(indexer) == before

      open_edit(lv, indexer.id)
      submit(lv, %{"secrets[api_key]" => @key})
      assert stored_key(indexer) == @key

      open_edit(lv, indexer.id)
      submit(lv, %{"secrets[clear_api_key]" => "true"})
      assert stored_key(indexer) == nil
      assert {:ok, %{secrets: secrets}} = Indexers.fetch_with_secrets(indexer.id)
      assert secrets == %{}
    end
  end

  describe "refusals" do
    setup %{conn: conn} do
      taken = indexer!(:newznab, "taken.example", %{name: "Taken"})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv, "newznab")
      %{lv: lv, taken: taken}
    end

    for {label, field, typed, message} <- [
          {"userinfo", "base-url", %{"indexer[base_url]" => "https://u:p@example.com"},
           "Remove the user name and password from the URL."},
          {"a query", "base-url", %{"indexer[base_url]" => "https://example.com?x=1"},
           "Remove the query, from the ? on, from the URL."},
          {"a fragment", "base-url", %{"indexer[base_url]" => "https://example.com#x"},
           "Remove the part from the # on from the URL."},
          {"a blank API path", "api-path", %{"indexer[api_path]" => ""},
           "Enter a path that starts with a single /, such as /api."},
          {"an API path with an authority", "api-path",
           %{"indexer[api_path]" => "//evil.example/api"},
           "Enter a path that starts with a single /, such as /api."},
          {"a credential in additional parameters", "additional-parameters",
           %{"indexer[additional_parameters]" => "&apikey=x"},
           "Put the API key in the API key field, not in additional parameters."},
          {"a taken name", "name", %{"indexer[name]" => "Taken"},
           "Another indexer already has this name."},
          {"priority 0", "priority", %{"indexer[priority]" => "0"},
           "Enter a whole number from 1 to 50."},
          {"priority 51", "priority", %{"indexer[priority]" => "51"},
           "Enter a whole number from 1 to 50."}
        ] do
      @typed typed
      test "#{label} shows its message under its field and keeps the typed name", %{lv: lv} do
        typed = Map.merge(filled("Fresh"), @typed)
        submit(lv, typed)

        assert has_dialog_element?(lv, "#indexer-form-#{unquote(field)}-error", unquote(message))
        assert has_dialog_element?(lv, "#indexer-form-#{unquote(field)}[aria-invalid=true]")
        id = "indexer-form-#{unquote(field)}"
        assert_push_event(lv, "focus-invalid", %{id: ^id})
        assert form_params(lv, %{})["indexer"]["name"] == typed["indexer[name]"]
        assert [%{name: "Taken"}] = Indexers.list()
      end
    end

    test "priority 1 and 50 save", %{lv: lv} do
      submit(lv, filled("One", %{"indexer[priority]" => "1"}))
      open_add(lv, "newznab")
      submit(lv, filled("Fifty", %{"indexer[priority]" => "50"}))

      assert Enum.map(Indexers.list(), &{&1.name, &1.priority}) ==
               [{"One", 1}, {"Taken", 25}, {"Fifty", 50}]

      assert has_element?(lv, "#indexers-notice", "Fifty added.")
    end

    test "a French admin reads the refusal in French", %{conn: conn} do
      admin = Cinder.AccountsFixtures.admin_fixture()
      {:ok, admin} = Cinder.Accounts.update_user_locale(admin, %{locale: "fr"})
      {:ok, lv, _html} = live(log_in_user(conn, admin), ~p"/settings")
      open_add(lv, "newznab")
      submit(lv, filled("Fresh", %{"indexer[priority]" => "51"}))
      refute has_dialog_element?(lv, "#indexer-form-priority-error", "Enter a whole number")
      assert has_dialog_element?(lv, "#indexer-form-priority-error", "50")
    end

    test "a refusal of two fields moves focus to the first in the form's order", %{lv: lv} do
      submit(
        lv,
        filled("Fresh", %{
          "indexer[base_url]" => "https://u:p@example.com",
          "indexer[priority]" => "0"
        })
      )

      assert has_dialog_element?(lv, "#indexer-form-priority-error")
      assert has_dialog_element?(lv, "#indexer-form-base-url-error")
      assert_push_event(lv, "focus-invalid", %{id: "indexer-form-base-url"})
      refute_push_event(lv, "focus-invalid", %{id: "indexer-form-priority"})
    end

    test "a Torznab settings refusal goes to the messages above the fields" do
      # The Torznab form sends no settings, so no Torznab save gets this refusal today.
      assert CinderWeb.IndexerFormText.errors(
               %Ecto.Changeset{errors: [settings: {"is invalid", validation: :settings_keys}]},
               :torznab
             ) == %{form: ["Enter the parameters as &name=value pairs, such as &cat=2000."]}
    end
  end

  # #1697: a refused base URL, API path or additional parameters value can carry a credential,
  # so a refused submit empties that input; a change keeps what the admin types.
  describe "a refused credential" do
    @credential "SYNTH-cred-d41c3b"

    setup %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      %{indexer: indexer, lv: lv}
    end

    defp open(lv, :add, _indexer), do: open_add(lv, "newznab")
    defp open(lv, :edit, indexer), do: open_edit(lv, indexer.id)

    defp state(lv),
      do: inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity)

    for mode <- [:add, :edit],
        {label, key, value, message} <- [
          {"base URL", "base_url", "https://u:#{@credential}@indexer.example",
           "Remove the user name and password from the URL."},
          {"API path", "api_path", "/api?apikey=#{@credential}",
           "Enter a path that starts with a single /, such as /api."},
          {"additional parameters", "additional_parameters", "&apikey=#{@credential}",
           "Put the API key in the API key field, not in additional parameters."}
        ] do
      @mode mode
      @key_name key
      @value value
      @message message
      test "#{mode}: a refused #{label} renders empty with its error and is held nowhere",
           %{indexer: indexer, lv: lv} do
        open(lv, @mode, indexer)
        id = "indexer-form-" <> String.replace(@key_name, "_", "-")
        typed = %{"indexer[name]" => "Typed name", "indexer[#{@key_name}]" => @value}

        change(lv, typed)
        # The controls: a change keeps the typed value in the form and in the assigns.
        assert form_params(lv, %{})["indexer"][@key_name] == @value
        assert state(lv) =~ @credential

        submit(lv, typed)

        assert has_dialog_element?(lv, "##{id}-error", @message)
        assert form_params(lv, %{})["indexer"][@key_name] == ""
        assert form_params(lv, %{})["indexer"]["name"] == "Typed name"
        refute render(lv) =~ @credential
        refute dialog(lv) =~ @credential
        refute state(lv) =~ @credential
        assert [%{name: "newznab a.example", base_url: "https://a.example"}] = Indexers.list()
      end
    end

    test "a save of an indexer deleted in another tab keeps no typed value",
         %{indexer: indexer, lv: lv} do
      open_edit(lv, indexer.id)
      typed = %{"indexer[base_url]" => "https://u:#{@credential}@indexer.example"}
      change(lv, typed)
      # The control: the change put the credential in the assigns.
      assert state(lv) =~ @credential

      :ok = Indexers.delete(nil, indexer.id)
      submit(lv, typed)

      assert has_dialog_element?(lv, "#indexer-form-deleted[role=alert]")
      refute state(lv) =~ @credential
      refute render(lv) =~ @credential
    end

    test "the next change keeps what the admin types into the emptied input", %{lv: lv} do
      open_add(lv, "newznab")
      refused = "https://u:#{@credential}@indexer.example"
      submit(lv, %{"indexer[name]" => "Typed name", "indexer[base_url]" => refused})
      assert form_params(lv, %{})["indexer"]["base_url"] == ""

      change(lv, %{"indexer[base_url]" => "https://retyped.example"})

      assert form_params(lv, %{})["indexer"]["base_url"] == "https://retyped.example"
      assert has_dialog_element?(lv, "#indexer-form-base-url-error")
    end

    test "a refusal of another field empties none", %{lv: lv} do
      open_add(lv, "newznab")

      typed = %{
        "indexer[name]" => "Typed name",
        "indexer[base_url]" => "https://typed.example",
        "indexer[api_path]" => "/typed/api",
        "indexer[additional_parameters]" => "&cat=5000",
        "indexer[priority]" => "0"
      }

      submit(lv, typed)

      assert has_dialog_element?(lv, "#indexer-form-priority-error")

      assert Map.take(
               form_params(lv, %{})["indexer"],
               ~w(base_url api_path additional_parameters)
             ) ==
               %{
                 "base_url" => "https://typed.example",
                 "api_path" => "/typed/api",
                 "additional_parameters" => "&cat=5000"
               }
    end
  end

  defp ciphertext(id), do: Cinder.Repo.get!(ConfiguredIndexer, id).secrets_ciphertext

  describe "secrets that do not decrypt" do
    test "the edit dialog asks to re-enter them, and a name-only save keeps the ciphertext",
         %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      :ok = undecryptable!(indexer)
      before = ciphertext(indexer.id)
      {:ok, lv, _html} = live(conn, ~p"/settings")

      open_edit(lv, indexer.id)

      assert has_dialog_element?(
               lv,
               "#indexer-form-unreadable[role=alert]",
               "This indexer's saved secrets can't be decrypted. Type every secret again, or tick its Clear box, before you save a secret."
             )

      assert has_dialog_element?(lv, "#indexer-form-clear-api-key")
      submit(lv, %{"indexer[name]" => "Renamed"})

      assert has_element?(lv, "#indexers-notice", "Renamed saved.")
      assert [%{name: "Renamed"}] = Indexers.list()
      assert ciphertext(indexer.id) == before
    end

    test "a readable indexer's edit shows no such alert", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, indexer.id)
      assert has_dialog_element?(lv, "#indexer-form-name")
      refute has_dialog_element?(lv, "#indexer-form-unreadable")
    end
  end

  describe "races" do
    setup %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, indexer.id)
      %{indexer: indexer, lv: lv}
    end

    test "a save on an older lock_version says the indexer changed and keeps the typed name",
         %{indexer: indexer, lv: lv} do
      {:ok, _row} = Indexers.update(nil, indexer.id, indexer.lock_version, %{name: "Other tab"})

      submit(lv, %{"indexer[name]" => "Mine", "indexer[priority]" => "9"})

      assert has_dialog_element?(
               lv,
               "#indexer-form-stale[role=alert]",
               "This indexer changed in another tab: reload it before saving."
             )

      assert form_params(lv, %{})["indexer"]["name"] == "Mine"
      assert [%{name: "Other tab", priority: 25}] = Indexers.list()
      # The stale line is an alert; no field was refused, so focus stays where it was.
      refute_push_event(lv, "focus-invalid", %{})
    end

    test "an Edit opened after a delete in another tab says so", %{conn: conn} do
      indexer = indexer!(:newznab, "b.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      :ok = Indexers.delete(nil, indexer.id)
      open_edit(lv, indexer.id)

      assert has_dialog_element?(
               lv,
               "#indexer-form-deleted",
               "This indexer was deleted in another tab."
             )

      refute has_dialog_element?(lv, "#indexer-form")
    end

    test "a save on the current lock_version shows no stale line", %{lv: lv} do
      submit(lv, %{"indexer[name]" => "Mine"})
      assert [%{name: "Mine"}] = Indexers.list()
      assert has_element?(lv, "#indexers-notice", "Mine saved.")
    end

    test "a save after a delete in another tab says so and offers only Close",
         %{indexer: indexer, lv: lv} do
      :ok = Indexers.delete(nil, indexer.id)
      submit(lv, %{"indexer[name]" => "Mine"})

      assert has_dialog_element?(
               lv,
               "#indexer-form-deleted[role=alert]",
               "This indexer was deleted in another tab."
             )

      buttons = lv |> dialog_doc() |> LazyHTML.query("button") |> Enum.map(&LazyHTML.text/1)
      assert Enum.map(buttons, &String.trim/1) == ["Close"]
      refute has_dialog_element?(lv, "#indexer-form")
      assert Indexers.list() == []

      lv |> target() |> render_submit("save", %{"indexer" => %{"name" => "Again"}})
      assert Indexers.list() == []
      lv |> target() |> render_click("close", %{})
      refute has_element?(lv, "#indexer-dialog")
    end
  end

  describe "typed values" do
    test "survive a Test's finish for another row and for the edited row", %{conn: conn} do
      edited = indexer!(:newznab, "a.example", %{})
      other = indexer!(:newznab, "b.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, edited.id)

      change(lv, %{
        "indexer[name]" => "Typed name",
        "indexer[base_url]" => "https://typed.example"
      })

      for %{id: id} <- [other, edited] do
        :ok = TestRunner.start(id)
        assert_receive {:test_started, task_pid, ^id}
        answer(task_pid, :test_success)
        assert_receive {TestRunner, :finished, ^id, {:ok, _}}
        eventually(fn -> has_element?(lv, "#indexer-#{id}-last-test") end)

        typed = form_params(lv, %{})["indexer"]
        assert {typed["name"], typed["base_url"]} == {"Typed name", "https://typed.example"}
      end
    end
  end

  # Polls until `check` holds, up to 5 s: a runner message reaches the page and the test process
  # in no fixed order.
  defp eventually(check, rounds \\ 250) do
    cond do
      check.() ->
        :ok

      rounds == 0 ->
        flunk("the page never matched")

      true ->
        Process.sleep(20)
        eventually(check, rounds - 1)
    end
  end

  describe "Test-on-save" do
    defp last_test(lv, id), do: lv |> element("#indexer-#{id}-last-test") |> render()

    for {label, settings} <- [
          {"no stored additional parameters", %{}},
          {"stored additional parameters", %{"additional_parameters" => "&cat=2000"}}
        ] do
      @settings settings
      test "an edit of only the name, the priority or the enabled state starts none, with #{label}",
           %{conn: conn} do
        indexer = indexer!(:newznab, "a.example", %{settings: @settings})

        {:written, _} =
          IndexerStatus.record_test(indexer, :test_success, ~U[2026-11-26 11:00:00Z])

        {:ok, lv, _html} = live(conn, ~p"/settings")
        shown = last_test(lv, indexer.id)
        assert shown =~ "Last Test: worked"

        # An enabled indexer, so only `test_on_save?/2` stands between each save and a Test;
        # the last save enables it again, an enabled-only edit on a disabled indexer.
        for typed <- [
              %{"indexer[name]" => "Renamed"},
              %{"indexer[priority]" => "3"},
              %{"indexer[enabled]" => "false"},
              %{"indexer[enabled]" => "true"}
            ] do
          open_edit(lv, indexer.id)
          submit(lv, typed)
          assert has_element?(lv, "#indexers-notice", "saved.")
          assert TestRunner.running() == MapSet.new()
          assert last_test(lv, indexer.id) =~ "Last Test: worked"
        end

        assert [%{name: "Renamed", priority: 3, enabled: true, config_version: 1} = row] =
                 Indexers.list()

        assert row.settings == @settings
        refute_received {:test_started, _task_pid, _id}
      end
    end

    test "an edit of the base URL of an enabled indexer starts one Test", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, id)
      submit(lv, %{"indexer[base_url]" => "https://moved.example"})

      assert_receive {:test_started, _task_pid, ^id}
      assert TestRunner.running() == MapSet.new([id])
      assert [%{config_version: 2}] = Indexers.list()
    end

    test "an edit of the API key of an enabled indexer starts one Test", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, id)
      submit(lv, %{"secrets[api_key]" => @key})
      assert_receive {:test_started, _task_pid, ^id}
    end

    test "an edit of the base URL of a disabled indexer starts none", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{enabled: false})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, indexer.id)
      submit(lv, %{"indexer[base_url]" => "https://moved.example"})

      assert [%{config_version: 2, enabled: false}] = Indexers.list()
      assert TestRunner.running() == MapSet.new()
    end

    test "a save while a Test of that indexer runs starts no second Test", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      id = indexer.id
      {:ok, lv, _html} = live(conn, ~p"/settings")
      :ok = TestRunner.start(id)
      assert_receive {:test_started, task_pid, ^id}

      open_edit(lv, id)
      submit(lv, %{"indexer[base_url]" => "https://moved.example"})

      assert has_element?(lv, "#indexers-notice", "saved.")
      assert [^task_pid] = Task.Supervisor.children(TestRunner.TaskSupervisor)
      refute_received {:test_started, _task_pid, _id}
    end
  end

  describe "through Prowlarr" do
    @prowlarr "https://media.example.com/prowlarr"
    @text "Searched through Prowlarr: Prowlarr drops results that have no size or no categories, and dates undated results now."

    setup do
      ConfigCase.put_config(Prowlarr, base_url: @prowlarr)
      :ok
    end

    test "the text follows the typed base URL and API path", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv, "torznab")
      refute has_dialog_element?(lv, "#indexer-form-through-prowlarr")

      change(lv, %{"indexer[base_url]" => @prowlarr <> "/", "indexer[api_path]" => "/12/api"})
      assert has_dialog_element?(lv, "#indexer-form-through-prowlarr", @text)

      change(lv, %{"indexer[base_url]" => @prowlarr, "indexer[api_path]" => "/api"})
      refute has_dialog_element?(lv, "#indexer-form-through-prowlarr")

      change(lv, %{
        "indexer[base_url]" => "https://other.example",
        "indexer[api_path]" => "/12/api"
      })

      refute has_dialog_element?(lv, "#indexer-form-through-prowlarr")
    end

    test "an indexer saved through Prowlarr shows the text in its edit dialog", %{conn: conn} do
      indexer = indexer!(:torznab, "x.example", %{base_url: @prowlarr, api_path: "/12/api"})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, indexer.id)
      assert has_dialog_element?(lv, "#indexer-form-through-prowlarr", @text)
    end
  end

  describe "logs" do
    setup do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)
    end

    test "Phoenix.Logger filters the whole secrets map" do
      assert Phoenix.Logger.filter_values(%{"secrets" => %{"api_key" => "SYNTH"}}) ==
               %{"secrets" => "[FILTERED]"}
    end

    test "Phoenix.Logger filters the base URL, the API path and the additional parameters" do
      assert Phoenix.Logger.filter_values(%{
               "base_url" => "https://u:KEY@x",
               "api_path" => "/api?apikey=KEY",
               "settings" => %{"additional_parameters" => "&apikey=KEY"},
               "name" => "kept"
             }) == %{
               "base_url" => "[FILTERED]",
               "api_path" => "[FILTERED]",
               "settings" => %{"additional_parameters" => "[FILTERED]"},
               "name" => "kept"
             }
    end

    test "the change and save events log no credential typed into those three fields",
         %{conn: conn} do
      credential = "SYNTH-cred-0e7a52"
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv, "newznab")

      typed = %{
        "indexer[name]" => "Logged name",
        "indexer[base_url]" => "https://u:#{credential}@indexer.example",
        "indexer[api_path]" => "/api?apikey=#{credential}",
        "indexer[additional_parameters]" => "&apikey=#{credential}"
      }

      log =
        capture_log([level: :debug], fn ->
          change(lv, typed)
          submit(lv, typed)
        end)

      assert log =~ ~s(HANDLE EVENT "change")
      assert log =~ ~s(HANDLE EVENT "save")
      assert log =~ "Logged name"

      for key <- ~w(base_url api_path additional_parameters),
          do: assert(log =~ ~s("#{key}" => "[FILTERED]"))

      refute log =~ credential
      assert has_dialog_element?(lv, "#indexer-form-base-url-error")
      assert Indexers.list() == []
    end

    test "the change and save events log the form without the key", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv, "newznab")

      log =
        capture_log([level: :debug], fn ->
          change(lv, filled("Logged"))
          submit(lv, filled("Logged"))
        end)

      assert log =~ ~s(HANDLE EVENT "change")
      assert log =~ ~s(HANDLE EVENT "save")
      assert log =~ "Logged"
      assert log =~ ~s("secrets" => "[FILTERED]")
      refute log =~ @key
      assert [%{name: "Logged"}] = Indexers.list()
    end

    test "a payload of any other shape raises nothing and logs no key", %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      key = stored_key(indexer)
      {:ok, lv, _html} = live(conn, ~p"/settings")

      # A save whose `indexer` or `secrets` is not a map changes nothing and keeps the dialog.
      ignored = [
        %{"indexer" => "x", "secrets" => @key},
        %{"indexer" => ["x"], "secrets" => [@key]},
        %{"indexer" => %{"name" => "Forged"}, "secrets" => "x"},
        %{"secrets" => %{"api_key" => @key}},
        %{}
      ]

      # A save with both maps drops each value that is not text, and each unknown key, and saves
      # the rest as opened. The test encodes a payload as a query, which drops an empty map.
      saved = [
        %{"indexer" => %{"other" => "x"}, "secrets" => %{"api_key" => %{"x" => @key}}},
        %{
          "indexer" => %{"name" => %{"x" => "y"}, "priority" => ["1"]},
          "secrets" => %{"api_key" => [@key], "clear_api_key" => %{"x" => @key}, "other" => @key}
        }
      ]

      log =
        capture_log([level: :debug], fn ->
          for payload <- ignored do
            open_edit(lv, indexer.id)
            lv |> target() |> render_submit("change", payload)
            lv |> target() |> render_submit("save", payload)
            assert has_element?(lv, "#indexer-dialog")
            refute has_dialog_element?(lv, "#indexer-form-stale")
          end

          for payload <- saved do
            open_edit(lv, indexer.id)
            lv |> target() |> render_submit("change", payload)
            lv |> target() |> render_submit("save", payload)
            refute has_element?(lv, "#indexer-dialog")
          end
        end)

      assert Process.alive?(lv.pid)
      assert log =~ ~s(HANDLE EVENT "save")
      refute log =~ @key
      refute render(lv) =~ @key

      assert [%{name: "newznab a.example", priority: 25, lock_version: lock_version}] =
               Indexers.list()

      assert lock_version == indexer.lock_version + length(saved)
      assert stored_key(indexer) == key
    end
  end

  describe "forged events" do
    test "an unknown type, an id with no row and a non-map payload change nothing",
         %{conn: conn} do
      indexer = indexer!(:newznab, "a.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")

      for raw <- ["abc", "#{indexer.id}x", "999999", 7, nil],
          do: lv |> target() |> render_click("open_edit", %{"id" => raw})

      lv |> target() |> render_click("open_edit", %{})
      refute has_element?(lv, "#indexer-dialog")

      for event <- ~w(change save back pick search),
          do: lv |> target() |> render_click(event, %{"type" => "newznab"})

      refute has_element?(lv, "#indexer-dialog")

      lv |> element("#indexers-add") |> render_click()

      for type <- ["cardigann", "x", 1, nil],
          do: lv |> target() |> render_click("pick", %{"type" => type})

      lv |> target() |> render_click("search", %{"query" => ["x"]})
      assert has_dialog_element?(lv, "#indexer-kind-newznab")
      assert has_dialog_element?(lv, "#indexer-kind-torznab")
      refute has_dialog_element?(lv, "#indexer-form")
      assert [%{name: "newznab a.example"}] = Indexers.list()
    end
  end
end
