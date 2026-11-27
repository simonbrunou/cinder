defmodule CinderWeb.SettingsProwlarrImportCardigannTest do
  # The Cardigann rows of the Import from Prowlarr dialog (#1675), on /settings: each row code's
  # text, the masked secret inputs, and a clear secret kept out of the view. The helpers follow
  # `CinderWeb.SettingsProwlarrImportTest`: the dialog is a `<.portal>` to `body`, so a test
  # reads it with `render(element(view, "#indexer-dialog"))` and sends its events with
  # `with_target(view, "#indexers")`.
  #
  # Not async: the Prowlarr source's config, the import lock and the Test runner are app-wide,
  # and the LiveView reaches the database through the shared sandbox.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.ProwlarrApiFixtures
  import Cinder.TestRunnerHelpers

  alias Cinder.Acquisition.IndexerSource.Native.TestRunner
  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.{ConfigCase, DefinitionFixtures}
  alias Cinder.Indexers
  alias Cinder.Indexers.FlareSolverrUrl
  alias CinderWeb.ProwlarrImportText
  alias Plug.Conn.Query

  @prowlarr_url "https://media.example.com/prowlarr"
  @prowlarr_key "stored-prowlarr-key-3e9a"
  @password "clear-password-SENTINEL-77"
  @flaresolverr "http://flaresolverr.lan:8191/"

  setup :register_and_log_in_admin
  setup :reset_cinder_env
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    ConfigCase.put_config(Prowlarr, base_url: @prowlarr_url, api_key: @prowlarr_key)
    block_tests()
    stop_tests_on_exit()
    :ok = TestRunner.subscribe()
    :ok
  end

  defp dialog(lv), do: lv |> element("#indexer-dialog") |> render()

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

  # The import form's own inputs with the values the test types over them, as the browser posts
  # them; `extra` adds pairs no input names, as a forged payload would.
  defp form_params(lv, typed, extra) do
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
    |> Kernel.++(extra)
    |> URI.encode_query()
    |> Query.decode()
  end

  defp posted(%{type: "hidden"} = input, _typed), do: [{input.name, input.value}]

  defp posted(%{type: "checkbox"} = input, typed) do
    ticked? = Map.get(typed, input.name, if(input.checked?, do: "true", else: "false")) == "true"
    if ticked?, do: [{input.name, "true"}], else: []
  end

  defp posted(input, typed), do: [{input.name, Map.get(typed, input.name, input.value || "")}]

  defp submit(lv, typed, extra \\ []),
    do: lv |> target() |> render_submit("import_submit", form_params(lv, typed, extra))

  defp view_state(lv), do: :erlang.term_to_binary(:sys.get_state(lv.pid))

  defp secrets(id) do
    {:ok, %{secrets: secrets}} = Indexers.fetch_with_secrets(id)
    secrets
  end

  defp tracker_fields(password) do
    [
      field("username", "alice"),
      field("password", password),
      field("freeleech", true),
      select_field("sort", 1, ["Date", "Size"])
    ]
  end

  defp tracker(id, opts \\ []) do
    {password, opts} = Keyword.pop(opts, :password, @password)
    opts = Keyword.put_new(opts, :fields, tracker_fields(password))
    cardigann(id, "tracker", Keyword.merge([name: "Tracker #{id}"], opts))
  end

  describe "a direct Cardigann row" do
    test "reads searched by Cinder, keeps a clear password out of the view, and imports",
         %{conn: conn} do
      DefinitionFixtures.mirror!(DefinitionFixtures.definition())
      stub_api([tracker(1)])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      assert has_dialog_element?(lv, "#import-row-1-becomes", "Cardigann, searched by Cinder")
      assert has_dialog_element?(lv, "#import-row-1-ticked[checked]")
      refute has_dialog_element?(lv, "#import-row-1 input[type=password]")

      refute view_state(lv) =~ @password
      refute dialog(lv) =~ @password
      refute render(lv) =~ @password

      html = submit(lv, %{})
      refute html =~ @password
      refute view_state(lv) =~ @password

      assert has_dialog_element?(lv, "#import-report-1", "Tracker 1: created")
      assert [indexer] = Indexers.list()
      assert {indexer.type, indexer.prowlarr_indexer_id} == {:cardigann, 1}
      assert secrets(indexer.id)["password"] == @password
    end

    test "a masked secret renders its own input; typed, it is stored", %{conn: conn} do
      DefinitionFixtures.mirror!(DefinitionFixtures.definition())
      stub_api([tracker(1, password: masked())])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      assert has_dialog_element?(
               lv,
               "#import-row-1 input[type=password][name='secrets[1][password]'][phx-update=ignore]"
             )

      assert has_dialog_element?(lv, "#import-row-1 label", "Password")
      refute has_dialog_element?(lv, "#import-row-1 input[name='secrets[1][api_key]']")

      # A value posted for a setting Prowlarr answered in clear is not read.
      submit(lv, %{"secrets[1][password]" => "typed-pw-SENTINEL"}, [
        {"secrets[1][username]", "mallory"}
      ])

      assert has_dialog_element?(lv, "#import-report-1", "Tracker 1: created")
      refute view_state(lv) =~ "typed-pw-SENTINEL"
      assert [indexer] = Indexers.list()
      assert secrets(indexer.id)["password"] == "typed-pw-SENTINEL"
      assert secrets(indexer.id)["username"] == "alice"
    end

    test "a masked secret left blank: the report names it and the indexer is disabled",
         %{conn: conn} do
      DefinitionFixtures.mirror!(DefinitionFixtures.definition())
      stub_api([tracker(1, password: masked())])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)
      submit(lv, %{"secrets[1][password]" => ""})

      assert has_dialog_element?(
               lv,
               "#import-report-1",
               "Tracker 1: Password not entered: created disabled"
             )

      assert [%{enabled: false}] = Indexers.list()
    end

    test "secrets that are not a map, or a masked setting that is not text, are refused",
         %{conn: conn} do
      DefinitionFixtures.mirror!(DefinitionFixtures.definition())
      stub_api([tracker(1, password: masked())])
      {:ok, lv, _html} = live(conn, ~p"/settings")

      for secrets <- ["flat", %{"1" => "flat"}, %{"1" => %{"password" => %{"x" => "y"}}}] do
        open_import(lv)

        lv
        |> target()
        |> render_submit("import_submit", %{
          "rows" => %{"1" => %{"ticked" => "true", "name" => "Tracker 1"}},
          "secrets" => secrets
        })

        assert has_dialog_element?(
                 lv,
                 "#import-row-1-errors",
                 "Enter each setting as plain text."
               )

        assert Indexers.list() == []
        lv |> target() |> render_click("close")
      end
    end

    test "a select that took its default is named in the preview and the report",
         %{conn: conn} do
      DefinitionFixtures.mirror!(DefinitionFixtures.definition())

      stub_api([
        tracker(1,
          fields: [field("username", "alice"), select_field("sort", 1, ["Size", "Size"])]
        )
      ])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      assert has_dialog_element?(lv, "#import-row-1-defaults li", "Sort took its default value")

      submit(lv, %{})
      assert has_dialog_element?(lv, "#import-report-1 li", "Sort took its default value")
    end
  end

  describe "Prowlarr's FlareSolverr (#1682)" do
    setup do
      DefinitionFixtures.mirror!(DefinitionFixtures.definition())
      :ok
    end

    defp flaresolverr_proxy(id, tags, host) do
      id
      |> proxy("FlareSolverr", tags)
      |> Map.put("fields", [field("host", host), field("requestTimeout", 60)])
    end

    test "the preview offers Prowlarr's host unticked; ticked, the import saves it",
         %{conn: conn} do
      stub_api([tracker(1, tags: [3])], [flaresolverr_proxy(1, [3], @flaresolverr)])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      assert has_dialog_element?(
               lv,
               "#import-flaresolverr",
               "Prowlarr uses FlareSolverr at #{@flaresolverr}"
             )

      assert has_dialog_element?(lv, "label", "Save it as Cinder's FlareSolverr URL")

      assert has_dialog_element?(
               lv,
               "input#import-flaresolverr-save[type=checkbox][name='flaresolverr[save]']"
             )

      refute has_dialog_element?(lv, "#import-flaresolverr-save[checked]")

      # A change keeps the tick across the re-render.
      lv
      |> target()
      |> render_change("import_change", form_params(lv, %{"flaresolverr[save]" => "true"}, []))

      assert has_dialog_element?(lv, "#import-flaresolverr-save[checked]")

      submit(lv, %{"flaresolverr[save]" => "true"})

      assert FlareSolverrUrl.get() == @flaresolverr
      assert has_dialog_element?(lv, "#import-report-flaresolverr", "FlareSolverr URL saved.")

      assert has_dialog_element?(
               lv,
               "#import-close[aria-describedby~='import-report-flaresolverr']"
             )

      refute has_dialog_element?(lv, "#import-report-1 li", "FlareSolverr URL not set")
      assert [%{flaresolverr: true}] = Indexers.list()
      assert lv |> element("#indexers-flaresolverr-line") |> render() =~ @flaresolverr
    end

    test "a batch refused after the tick saved the URL shows the URL and drops the offer",
         %{conn: conn} do
      # The commit reads Prowlarr again; by then a row named like the ticked one exists, so the
      # batch is refused after the URL saved.
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      indexers = fn ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 1 do
          {:ok, _row} =
            Indexers.create(
              nil,
              %{
                name: "Tracker 1",
                type: :newznab,
                base_url: "https://taken.example",
                api_path: "/api"
              },
              %{}
            )
        end

        {:ok, [tracker(1, tags: [3])]}
      end

      stub_api(indexers, [flaresolverr_proxy(1, [3], @flaresolverr)])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)
      submit(lv, %{"flaresolverr[save]" => "true"})

      assert FlareSolverrUrl.get() == @flaresolverr
      assert Enum.map(Indexers.list(), & &1.name) == ["Tracker 1"]
      assert has_element?(lv, "#indexer-dialog")
      assert lv |> element("#indexers-flaresolverr-line") |> render() =~ @flaresolverr
      refute has_dialog_element?(lv, "#import-flaresolverr")
    end

    test "unticked, nothing is saved and the report names the URL not set", %{conn: conn} do
      stub_api([tracker(1, tags: [3])], [flaresolverr_proxy(1, [3], @flaresolverr)])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)
      submit(lv, %{})

      assert FlareSolverrUrl.get() == nil
      refute has_dialog_element?(lv, "#import-report-flaresolverr")
      assert has_dialog_element?(lv, "#import-report-1 li", "FlareSolverr URL not set")

      refute has_dialog_element?(
               lv,
               "#import-close[aria-describedby~='import-report-flaresolverr']"
             )

      refute has_dialog_element?(lv, "#import-close[aria-describedby~='false']")
    end

    test "with a URL already saved there is no offer, and a forged tick saves nothing",
         %{conn: conn} do
      :ok = FlareSolverrUrl.put("http://kept.lan:8191")
      stub_api([tracker(1, tags: [3])], [flaresolverr_proxy(1, [3], @flaresolverr)])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      refute has_dialog_element?(lv, "#import-flaresolverr")
      refute dialog(lv) =~ "flaresolverr[save]"

      submit(lv, %{}, [{"flaresolverr[save]", "true"}])

      assert FlareSolverrUrl.get() == "http://kept.lan:8191"
      assert has_dialog_element?(lv, "#import-report-1", "Tracker 1: created")
      refute has_dialog_element?(lv, "#import-report-flaresolverr")
    end

    test "with no FlareSolverr in Prowlarr there is no offer", %{conn: conn} do
      stub_api([tracker(1)])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_import(lv)

      assert has_dialog_element?(lv, "#import-row-1")
      refute has_dialog_element?(lv, "#import-flaresolverr")
    end
  end

  describe "a Cardigann row that cannot go direct" do
    for {name, setup, text} <- [
          {"definition not available", :absent,
           "Definition not available: add it through Prowlarr"},
          {"not supported", :not_supported, "Not supported: HTML responses"},
          {"needs a newer Cinder", :newer, "Needs a newer Cinder"},
          {"base URL", :base_url, "Base URL is not one of the definition's links"},
          {"select with no default", :no_default, "Order has no default value"}
        ] do
      @setup setup
      @text text

      test "#{name}: its reason, and the unticked through-Prowlarr offer", %{conn: conn} do
        indexer = arrange(@setup)
        stub_api([indexer])
        {:ok, lv, _html} = live(conn, ~p"/settings")
        open_import(lv)

        assert has_dialog_element?(lv, "#import-row-1-reasons li", @text)

        assert has_dialog_element?(
                 lv,
                 "#import-row-1-becomes",
                 "Torznab, searched through Prowlarr"
               )

        assert has_dialog_element?(lv, "#import-row-1-via:not([checked])")
      end
    end

    test "a French admin reads the reason in French", %{conn: conn} do
      admin = Cinder.AccountsFixtures.admin_fixture()
      {:ok, admin} = Cinder.Accounts.update_user_locale(admin, %{locale: "fr"})
      stub_api([arrange(:absent)])
      {:ok, lv, _html} = live(log_in_user(conn, admin), ~p"/settings")
      open_import(lv)

      assert has_dialog_element?(
               lv,
               "#import-row-1-reasons li",
               "Définition indisponible : ajoutez-le via Prowlarr"
             )
    end

    for {code, french} <- [
          {:needs_newer_cinder, "Nécessite une version plus récente de Cinder"},
          {:base_url_not_in_links, "L'URL de base ne fait pas partie des liens de la définition"},
          {{:select_no_default, "Tri"}, "Tri n'a pas de valeur par défaut"}
        ] do
      @code code
      @french french

      test "#{inspect(code)} reads in French" do
        Gettext.with_locale(CinderWeb.Gettext, "fr", fn ->
          row = %Cinder.Indexers.ProwlarrImport.Row{
            prowlarr_id: 1,
            name: "T",
            implementation: "Cardigann",
            protocol: "torrent",
            priority: 25,
            enabled: true,
            state: :via_prowlarr,
            reasons: [@code]
          }

          assert ProwlarrImportText.reasons(row) == [@french]
        end)
      end
    end

    test "French notes and report lines" do
      Gettext.with_locale(CinderWeb.Gettext, "fr", fn ->
        assert ProwlarrImportText.notes(%{notes: [{:took_default, "Tri"}]}) ==
                 ["Tri a pris sa valeur par défaut"]

        assert ProwlarrImportText.notes(%{notes: [:flaresolverr_url_not_set]}) ==
                 ["URL de FlareSolverr non définie"]

        assert ProwlarrImportText.created(%{
                 name: "T",
                 notes: [{:secrets_not_entered, ["Mot de passe"]}]
               }) == "T : Mot de passe à saisir : créé désactivé"

        assert ProwlarrImportText.created(%{
                 name: "T",
                 notes: [{:secrets_not_entered, ["Identifiant", "Mot de passe"]}]
               }) == "T : Identifiant, Mot de passe à saisir : créé désactivé"

        assert ProwlarrImportText.row_error(:settings_invalid) ==
                 "Saisissez chaque paramètre en texte brut."
      end)
    end
  end

  test "a feature a load result names with a value reads as words, not a term" do
    row = %Cinder.Indexers.ProwlarrImport.Row{
      prowlarr_id: 1,
      name: "T",
      implementation: "Cardigann",
      protocol: "torrent",
      priority: 25,
      enabled: true,
      state: :via_prowlarr,
      reasons: [
        {:not_supported, {:login, "form"}},
        {:not_supported, {:filter, "fuzzytime"}},
        {:not_supported, {:selector, :template}}
      ]
    }

    assert ProwlarrImportText.reasons(row) == [
             "Not supported: the form login",
             "Not supported: the fuzzytime filter",
             "Not supported: selector templates"
           ]
  end

  test "a definition the create no longer finds reads as a changed preview" do
    assert ProwlarrImportText.row_error({:definition, :definition_not_in_mirror}) ==
             "Prowlarr or a definition changed: check the preview again."

    assert ProwlarrImportText.row_error({:definition, :definition_fails}) ==
             "Prowlarr or a definition changed: check the preview again."
  end

  defp arrange(:absent) do
    DefinitionFixtures.mirror!(DefinitionFixtures.definition())
    cardigann(1, "elsewhere", name: "Tracker 1", fields: tracker_fields(@password))
  end

  defp arrange(:not_supported) do
    DefinitionFixtures.mirror!(DefinitionFixtures.definition("tracker-ns"))
    tracker(1)
  end

  defp arrange(:newer) do
    {:ok, {:loaded, _}} =
      DefinitionFixtures.apply_files([{"v13", "tracker.yml", DefinitionFixtures.definition()}])

    tracker(1)
  end

  defp arrange(:base_url) do
    DefinitionFixtures.mirror!(DefinitionFixtures.definition())
    tracker(1, base_url: "https://elsewhere.invalid/")
  end

  defp arrange(:no_default) do
    setting = %{
      "name" => "order",
      "type" => "select",
      "label" => "Order",
      "options" => %{"a" => "A", "b" => "A"}
    }

    DefinitionFixtures.mirror!(
      DefinitionFixtures.definition("tracker", %{"settings" => [setting]})
    )

    tracker(1, fields: [select_field("order", 0, ["A", "A"])])
  end
end
