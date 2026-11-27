defmodule CinderWeb.SettingsCardigannTest do
  # Cardigann sites in the indexers component of /settings (#1676): the add list's sites, the
  # Cardigann form, Accept update, Switch to %{name} (#1907) and the Test button of a copy that
  # does not run. The dialogs are a `<.portal>` to `body`: a test renders the portal and sends
  # events with `with_target(view, "#indexers")`, as `CinderWeb.SettingsIndexerDialogsTest` does.
  # Definitions come from `Cinder.DefinitionFixtures`.
  #
  # Not async: the Test runner, Native's clock, the adapter map and the Logger level are app-wide.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.DefinitionFixtures
  import Cinder.NewznabFixtures, only: [indexer!: 3]
  import Cinder.TestRunnerHelpers
  import ExUnit.CaptureLog

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerStatus, TestRunner}
  alias Cinder.ConfigCase
  alias Cinder.Indexers
  alias Cinder.Indexers.{ConfiguredIndexer, Definitions}
  alias Cinder.Repo
  alias Plug.Conn.Query

  @now ~U[2026-11-26 12:00:00Z]
  @password "SYNTH-pass-7c41e0"

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

  @base definition()

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

  defp attribute(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  defp target(lv), do: with_target(lv, "#indexers")

  defp open_add(lv), do: lv |> element("#indexers-add") |> render_click()

  defp pick(lv, name), do: lv |> target() |> render_click("pick_definition", %{"name" => name})

  # The form's own fields, as the browser would post them, with `typed` over their values: each
  # input and select of `#indexer-form`, a checkbox's hidden "false" before its "true". A key of
  # `typed` that names no field fails the test.
  defp form_params(lv, typed) do
    doc = dialog_doc(lv)

    fields =
      for node <- LazyHTML.query(doc, "#indexer-form input[name], #indexer-form select[name]"),
          do: {attribute(node, "name"), field_value(node)}

    names = Enum.map(fields, &elem(&1, 0))

    for name <- Map.keys(typed),
        name not in names,
        do: flunk("no field #{name}: #{inspect(names)}")

    fields
    |> Enum.reject(fn {_name, value} -> value == nil end)
    |> Enum.map(fn {name, value} -> {name, Map.get(typed, name, value)} end)
    |> URI.encode_query()
    |> Query.decode()
  end

  # A select posts its selected option, else its first; an unticked checkbox posts nothing.
  defp field_value(node) do
    cond do
      LazyHTML.tag(node) == ["select"] ->
        attribute(LazyHTML.query(node, "option[selected]"), "value") ||
          attribute(LazyHTML.query(node, "option"), "value")

      attribute(node, "type") == "checkbox" ->
        if LazyHTML.attribute(node, "checked") != [], do: "true"

      true ->
        attribute(node, "value") || ""
    end
  end

  defp submit(lv, typed \\ %{}),
    do: lv |> target() |> render_submit("save", form_params(lv, typed))

  defp change(lv, typed), do: lv |> target() |> render_change("change", form_params(lv, typed))

  defp stored_row(id), do: Repo.get!(ConfiguredIndexer, id)
  defp secrets(id), do: elem(Indexers.fetch_with_secrets(id), 1).secrets

  describe "the add list" do
    setup do
      public = definition("tracker", %{"type" => "public", "description" => "A long tracker"})

      assert {:ok, {:loaded, _}} =
               apply_files([
                 {"v11", "tracker.yml", public},
                 {"v11", "broken-ns.yml", definition("broken-ns", %{"name" => "Aaa Unsupported"})}
               ])

      %{public: public}
    end

    test "lists each site after Newznab and Torznab, greys one not supported, opens no form for it",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv)

      doc = dialog_doc(lv)
      items = doc |> LazyHTML.query("#indexer-kinds > li") |> Enum.map(&LazyHTML.text/1)
      assert [newznab, torznab | sites] = items
      assert newznab =~ "Newznab" and torznab =~ "Torznab"
      assert Enum.any?(sites, &(&1 =~ "Cinder Test tracker"))

      [site] =
        LazyHTML.query(doc, "button[phx-value-name='tracker.yml']") |> Enum.to_list()

      assert LazyHTML.text(site) =~ "Public"
      assert LazyHTML.text(site) =~ "en-US"
      assert LazyHTML.text(site) =~ "A long tracker"

      [greyed] = doc |> LazyHTML.query("[aria-disabled='true']") |> Enum.to_list()
      assert LazyHTML.text(greyed) =~ "Aaa Unsupported"
      assert LazyHTML.text(greyed) =~ "Not supported: HTML responses"
      assert attribute(greyed, "phx-click") == nil

      pick(lv, "broken-ns.yml")
      refute has_dialog_element?(lv, "#indexer-form")
    end

    test "the search box filters the sites by name and description", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv)
      lv |> target() |> render_change("search", %{"query" => "long trACKer"})
      assert has_dialog_element?(lv, "button[phx-value-name='tracker.yml']")
      refute has_dialog_element?(lv, "[aria-disabled='true']")
      refute has_dialog_element?(lv, "#indexer-kind-newznab")
    end

    test "a site removed upstream leaves the list", %{conn: conn} do
      assert {:ok, {:loaded, _}} = apply_files([])
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv)
      refute has_dialog_element?(lv, "button[phx-value-name='tracker.yml']")
      pick(lv, "tracker.yml")
      refute has_dialog_element?(lv, "#indexer-form")
    end
  end

  test "with no set loaded the list says so and keeps Newznab and Torznab", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")
    open_add(lv)

    assert has_dialog_element?(
             lv,
             "#indexer-definitions-none",
             "Indexer definitions not loaded yet"
           )

    assert has_dialog_element?(lv, "#indexer-kind-newznab")
    assert has_dialog_element?(lv, "#indexer-kind-torznab")
  end

  describe "the Cardigann form" do
    setup do
      second = definition("tracker", %{"links" => [link(), "https://second.invalid/"]})
      mirror!(second)
      %{copy: second}
    end

    test "creates an indexer pinned to the rendered copy, with defaults and an encrypted secret",
         %{conn: conn, copy: copy} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv)
      pick(lv, "tracker.yml")

      options =
        lv |> dialog_doc() |> LazyHTML.query("#indexer-form-base-url option") |> Enum.to_list()

      assert Enum.map(options, &attribute(&1, "value")) == [link(), "https://second.invalid/"]
      assert LazyHTML.attribute(hd(options), "selected") != []

      assert has_dialog_element?(lv, "#indexer-form-name[value='Cinder Test tracker']")
      password = secret_input(lv, "password")
      submit(lv, %{password => @password})

      assert [row] = Indexers.list()
      assert pin(row) == %{running: blob_sha(copy), held: nil, hold: nil}
      assert stored_row(row.id).secrets_ciphertext != nil
      refute stored_row(row.id).secrets_ciphertext =~ @password
      assert secrets(row.id)["password"] == @password
      assert secrets(row.id)["apikey"] == "public-key"

      lv |> element("#indexer-#{row.id}-edit") |> render_click()

      [input] =
        lv |> dialog_doc() |> LazyHTML.query("input[name='secrets[password]']") |> Enum.to_list()

      assert attribute(input, "value") in [nil, ""]
      assert attribute(input, "placeholder") == "•••• saved (leave blank to keep)"
      refute dialog(lv) =~ @password
    end

    test "an info setting's HTML shows as text, never as an element", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv)
      pick(lv, "tracker.yml")

      assert dialog(lv) =~ "&lt;a href="
      refute has_dialog_element?(lv, "a[href='https://wiki.invalid/help']")
    end

    test "an info setting with neither label nor text renders nothing", %{conn: conn} do
      blank = %{"name" => "blank", "type" => "info"}
      mirror!(definition("tracker", %{"settings" => settings() ++ [blank]}))

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv)
      pick(lv, "tracker.yml")

      assert has_dialog_element?(lv, "#indexer-form-setting-5")
      refute has_dialog_element?(lv, "#indexer-form-setting-6")
    end

    # An empty label or text counts as none (#1877), so each of these renders nothing.
    for {case_name, setting} <- [
          {"an info setting whose label is empty", %{"type" => "info", "label" => ""}},
          {"an info setting whose text is empty", %{"type" => "info", "default" => ""}},
          {"an info_category_8000 setting whose label is empty",
           %{"type" => "info_category_8000", "label" => ""}}
        ] do
      @setting Map.put(setting, "name", "blank")
      test "#{case_name} renders nothing", %{conn: conn} do
        mirror!(definition("tracker", %{"settings" => settings() ++ [@setting]}))

        {:ok, lv, _html} = live(conn, ~p"/settings")
        open_add(lv)
        pick(lv, "tracker.yml")

        assert has_dialog_element?(lv, "#indexer-form-setting-5")
        refute has_dialog_element?(lv, "#indexer-form-setting-6")
      end
    end

    # No v11 definition labels its `info_cookie` setting (#1680's cookie login), so the form says
    # how to copy the cookie itself, under the setting's own label when it has one.
    for {case_name, setting, heading} <- [
          {"with no label", %{"type" => "info_cookie"}, "How to get the cookie"},
          {"with a label", %{"type" => "info_cookie", "label" => "About the cookie"},
           "About the cookie"}
        ] do
      @cookie_setting Map.put(setting, "name", "info_cookie")
      @heading heading
      test "an info_cookie setting #{case_name} says how to copy the cookie", %{conn: conn} do
        mirror!(definition("tracker", %{"settings" => settings() ++ [@cookie_setting]}))

        {:ok, lv, _html} = live(conn, ~p"/settings")
        open_add(lv)
        pick(lv, "tracker.yml")

        assert has_dialog_element?(lv, "#indexer-form-setting-6 .font-medium", @heading)

        assert has_dialog_element?(
                 lv,
                 "#indexer-form-setting-6",
                 ~s(copy the value of that request's Cookie header, everything after "Cookie: ")
               )
      end
    end

    # An empty label counts as none (#1892), so each control is labelled with the setting's name.
    for {control, field, name} <- [
          {"secret", "secrets[username]", "username"},
          {"checkbox", "indexer[settings][freeleech]", "freeleech"},
          {"select", "indexer[settings][sort]", "sort"}
        ] do
      @field field
      @name name
      test "a #{control} setting whose label is empty is labelled with its name", %{conn: conn} do
        mirror!(definition("tracker", %{"settings" => blank_labels()}))

        {:ok, lv, _html} = live(conn, ~p"/settings")
        open_add(lv)
        pick(lv, "tracker.yml")

        assert label_of(lv, @field) == @name
      end
    end

    test "a select option shows its label, or its key when the label is empty", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv)
      pick(lv, "tracker.yml")
      assert sort_options(lv) == [{"date", "Date"}, {"size", "Size"}]

      mirror!(definition("tracker", %{"settings" => blank_labels()}))
      open_add(lv)
      pick(lv, "tracker.yml")
      assert sort_options(lv) == [{"date", "date"}, {"size", "size"}]
    end

    test "a plain text setting and a Clear box whose label is empty show the setting's name",
         %{conn: conn} do
      copy = definition("tracker", %{"settings" => blank_labels()})
      mirror!(copy)
      row = cardigann!(copy, %{"password" => @password})
      Repo.update!(Ecto.Changeset.change(stored_row(row.id), settings: %{"username" => "me"}))

      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{row.id}-edit") |> render_click()

      assert label_of(lv, "indexer[settings][username]") == "username"
      assert label_of(lv, "secrets[clear_password]") == "Clear saved password"
    end

    test "a save of a copy the mirror no longer holds is refused and writes nothing",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv)
      pick(lv, "tracker.yml")
      mirror!(definition("tracker", %{"name" => "Changed upstream"}))

      submit(lv)

      assert has_dialog_element?(
               lv,
               ".indexer-form-error",
               "This site's definition changed while the form was open: close it and open it again."
             )

      assert Indexers.list() == []
    end

    test "an edit from a copy the indexer no longer runs is refused", %{conn: conn, copy: copy} do
      row = cardigann!(copy)
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{row.id}-edit") |> render_click()
      mirror!(definition("tracker", %{"name" => "Applied upstream"}))

      submit(lv, %{"indexer[name]" => "Renamed"})
      assert has_dialog_element?(lv, ".indexer-form-error", "changed while the form was open")
      assert stored_row(row.id).name == row.name
    end

    test "a stored base URL outside the links shows as an extra first option", %{
      conn: conn,
      copy: copy
    } do
      row = cardigann!(copy, %{}, %{base_url: "https://second.invalid/"})
      mirror!(definition("tracker", %{"links" => [link()]}))
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{row.id}-edit") |> render_click()

      values =
        lv
        |> dialog_doc()
        |> LazyHTML.query("#indexer-form-base-url option")
        |> Enum.map(&attribute(&1, "value"))

      assert values == ["https://second.invalid/", link()]
    end

    # #1661's rules hold for the Cardigann form too.
    test "a save on an older lock_version says the indexer changed and keeps the typed name",
         %{conn: conn, copy: copy} do
      row = cardigann!(copy)
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{row.id}-edit") |> render_click()
      {:ok, _row} = Indexers.update(nil, row.id, row.lock_version, %{name: "Other tab"})

      submit(lv, %{"indexer[name]" => "Mine"})

      assert has_dialog_element?(
               lv,
               "#indexer-form-stale[role=alert]",
               "This indexer changed in another tab: reload it before saving."
             )

      assert form_params(lv, %{})["indexer"]["name"] == "Mine"
      assert stored_row(row.id).name == "Other tab"
    end

    test "a save of an indexer deleted in another tab says so", %{conn: conn, copy: copy} do
      row = cardigann!(copy)
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{row.id}-edit") |> render_click()
      :ok = Indexers.delete(nil, row.id)

      submit(lv, %{"indexer[name]" => "Mine"})
      assert has_dialog_element?(lv, "#indexer-form-deleted[role=alert]")
      assert Indexers.list() == []
    end

    # #1697: a base URL can carry a credential, so a typed one outside the links never comes
    # back as an option, after a change or after the save refuses it.
    test "a typed base URL outside the links is refused and never shown again", %{conn: conn} do
      typed = %{"indexer[base_url]" => "https://user:KEY@evil.invalid/"}
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv)
      pick(lv, "tracker.yml")

      change(lv, typed)
      refute dialog(lv) =~ "KEY@evil"

      submit(lv, typed)
      assert has_dialog_element?(lv, "#indexer-form-base-url-error", "Remove the user")
      refute dialog(lv) =~ "KEY@evil"
      assert Indexers.list() == []
    end

    test "neither the assigns nor the log hold the typed password", %{conn: conn} do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv)
      pick(lv, "tracker.yml")
      password = secret_input(lv, "password")

      # The state is read while the dialog is open, after a change, and once the save closed it.
      state = fn ->
        inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity)
      end

      changed = capture_log([level: :debug], fn -> change(lv, %{password => @password}) end)
      assert state.() =~ "secret_key:"
      refute state.() =~ @password

      saved = capture_log([level: :debug], fn -> submit(lv, %{password => @password}) end)

      for log <- [changed, saved] do
        assert log =~ ~s("secrets" => "[FILTERED]")
        refute log =~ @password
      end

      assert saved =~ ~s(HANDLE EVENT "save")
      assert [_row] = Indexers.list()
      assert state.() =~ "only_source?:"
      refute state.() =~ @password
    end

    test "typed values survive another row's Test ending", %{conn: conn} do
      %{id: id} = indexer!(:newznab, "b.example", %{})
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_add(lv)
      pick(lv, "tracker.yml")
      change(lv, %{"indexer[name]" => "Typed name", "indexer[settings][sort]" => "size"})

      :ok = TestRunner.start(id)
      assert_receive {:test_started, task, ^id}, 5_000
      answer(task, :test_success)
      assert_receive {TestRunner, :finished, ^id, {:ok, _}}, 5_000
      eventually(fn -> has_element?(lv, "#indexer-#{id}-last-test") end)

      assert has_dialog_element?(lv, "#indexer-form-name[value='Typed name']")

      assert has_dialog_element?(
               lv,
               "select[name='indexer[settings][sort]'] option[selected][value='size']"
             )
    end
  end

  # Polls until `check` holds, up to 5 s: a runner message reaches the page after the test sees it.
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

  # `settings/0` with every label but the info setting's empty, the select's option labels too.
  defp blank_labels do
    Enum.map(settings(), fn
      %{"type" => "info"} = setting -> setting
      %{"options" => options} = setting -> %{setting | "label" => "", "options" => blank(options)}
      setting -> Map.put(setting, "label", "")
    end)
  end

  defp blank(options), do: Map.new(options, fn {key, _label} -> {key, ""} end)

  # The text of the label of the form's field named `name`: the `.label` span of the `<label>`
  # that wraps it, which a select's options sit beside.
  defp label_of(lv, name) do
    doc = dialog_doc(lv)

    [field] =
      doc
      |> LazyHTML.query("#indexer-form [name='#{name}']:not([type='hidden'])")
      |> Enum.to_list()

    [label] =
      doc |> LazyHTML.query("label[for='#{attribute(field, "id")}'] .label") |> Enum.to_list()

    label |> LazyHTML.text() |> String.trim()
  end

  # The sort select's options as `{value, text}`.
  defp sort_options(lv) do
    lv
    |> dialog_doc()
    |> LazyHTML.query("select[name='indexer[settings][sort]'] option")
    |> Enum.map(&{attribute(&1, "value"), &1 |> LazyHTML.text() |> String.trim()})
  end

  # The id of the secret input of setting `name`, which is new on each open.
  defp secret_input(lv, name) do
    [input] =
      lv |> dialog_doc() |> LazyHTML.query("input[name='secrets[#{name}]']") |> Enum.to_list()

    assert attribute(input, "id") =~ "indexer-form-secret-"
    "secrets[#{name}]"
  end

  describe "Accept update" do
    setup do
      mirror!(@base)
      row = cardigann!(@base, %{"password" => @password})
      hosted = definition("tracker", %{"description" => "https://new.invalid/"})
      mirror!(hosted)
      %{row: row, hosted: hosted}
    end

    test "the confirm lists the new hosts and accepts the shown copy", %{conn: conn} = ctx do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{ctx.row.id}-accept") |> render_click()

      hosts =
        lv
        |> dialog_doc()
        |> LazyHTML.query("#indexer-accept-hosts li")
        |> Enum.map(&LazyHTML.text/1)

      assert hosts == ["new.invalid"]
      assert has_dialog_element?(lv, "#indexer-accept-reason", "new hosts")

      lv |> target() |> render_click("accept_update", %{})
      assert pin(ctx.row) == %{running: blob_sha(ctx.hosted), held: nil, hold: nil}
      assert has_element?(lv, "#indexers-notice", "definition update accepted")
    end

    test "a held copy that changed before the click is accepted not, and the confirm says so",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{ctx.row.id}-accept") |> render_click()
      later = definition("tracker", %{"description" => "https://later.invalid/"})
      mirror!(later)

      lv |> target() |> render_click("accept_update", %{})

      assert has_dialog_element?(
               lv,
               "#indexer-accept-changed",
               "This update changed while you were reading: check it again."
             )

      assert pin(ctx.row) == %{running: blob_sha(@base), held: blob_sha(later), hold: :hosts}

      hosts =
        lv
        |> dialog_doc()
        |> LazyHTML.query("#indexer-accept-hosts li")
        |> Enum.map(&LazyHTML.text/1)

      assert hosts == ["later.invalid"]
    end

    # The refusal removes Confirm, which held focus: focus moves to Cancel, inside the dialog, and
    # a second accept_update (a queued double click) changes nothing.
    test "a refused accept moves focus to Cancel, and another click does nothing",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{ctx.row.id}-accept") |> render_click()
      mirror!(@base)

      lv |> target() |> render_click("accept_update", %{})
      assert has_dialog_element?(lv, "#indexer-accept-message", "No update is held")
      refute has_dialog_element?(lv, "#indexer-accept-confirm")
      assert_push_event(lv, "focus-invalid", %{id: "indexer-accept-cancel"})

      lv |> target() |> render_click("accept_update", %{})
      assert has_dialog_element?(lv, "#indexer-accept-message", "No update is held")
      assert pin(ctx.row).running == blob_sha(@base)
    end
  end

  describe "Switch to %{name}" do
    setup do
      mirror!(@base)

      row =
        cardigann!(@base, %{"password" => @password}, %{
          settings: %{"freeleech" => true},
          priority: 7
        })

      newer =
        definition("newer", %{
          "replaces" => ["tracker"],
          "description" => "Mirror at https://new.invalid/"
        })

      assert {:ok, {:loaded, _}} = apply_files([{"v11", "newer.yml", newer}])
      %{row: stored_row(row.id), newer: newer}
    end

    test "opens on the replacing copy with the row's values and the new hosts; saving moves it",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{ctx.row.id}-switch", "Switch to newer.yml") |> render_click()

      assert has_dialog_element?(lv, "#indexer-dialog-title", "Switch to newer.yml")
      assert has_dialog_element?(lv, "#indexer-form-kind", "newer.yml")

      assert has_dialog_element?(
               lv,
               "#indexer-form-drops",
               "Switching drops this indexer's grabs"
             )

      assert has_dialog_element?(lv, "#indexer-form-name[value='#{ctx.row.name}']")
      assert has_dialog_element?(lv, "#indexer-form-priority[value='7']")

      assert has_dialog_element?(
               lv,
               "input[type='checkbox'][name='indexer[settings][freeleech]'][checked]"
             )

      assert has_dialog_element?(
               lv,
               "#indexer-form-hosts-region[aria-live='polite'] #indexer-form-hosts li",
               "new.invalid"
             )

      [input] =
        lv |> dialog_doc() |> LazyHTML.query("input[name='secrets[password]']") |> Enum.to_list()

      assert attribute(input, "placeholder") == "•••• saved (leave blank to keep)"

      submit(lv)

      assert stored_row(ctx.row.id).definition == "newer.yml"
      assert pin(ctx.row) == %{running: blob_sha(ctx.newer), held: nil, hold: nil}
      assert secrets(ctx.row.id)["password"] == @password
      refute has_element?(lv, "#indexer-#{ctx.row.id}-switch")

      # The Switch button is gone, so focus goes back to the row's Edit, as after Accept update.
      edit = "indexer-#{ctx.row.id}-edit"
      assert_push_event(lv, "focus-invalid", %{id: ^edit})
    end

    test "Cancel closes the dialog and moves focus to the row's Edit", %{conn: conn} = ctx do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{ctx.row.id}-switch") |> render_click()
      lv |> target() |> render_click("close", %{})

      edit = "indexer-#{ctx.row.id}-edit"
      assert_push_event(lv, "focus-invalid", %{id: ^edit})
      refute has_element?(lv, "#indexer-dialog")
      assert stored_row(ctx.row.id).definition == "tracker.yml"
    end

    # Secrets that do not decrypt let a Switch save once each is typed again. Until then the save
    # would refuse, so the form lists no host and says why; then it lists every host, since an
    # indexer whose secrets do not decrypt sends its credentials nowhere today.
    test "lists the new hosts once every secret that does not decrypt is typed again",
         %{conn: conn} = ctx do
      :ok = undecryptable!(ctx.row)

      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{ctx.row.id}-switch") |> render_click()

      assert has_dialog_element?(lv, "#indexer-form-hosts-unknown", "Re-enter every secret")
      refute has_dialog_element?(lv, "#indexer-form-hosts")

      typed = %{
        "secrets[username]" => "me",
        "secrets[password]" => @password,
        "secrets[apikey]" => "public-key"
      }

      change(lv, typed)

      refute has_dialog_element?(lv, "#indexer-form-hosts-unknown")
      assert has_dialog_element?(lv, "#indexer-form-hosts li", "new.invalid")
      assert has_dialog_element?(lv, "#indexer-form-hosts li", "tracker.invalid")

      submit(lv, typed)
      assert stored_row(ctx.row.id).definition == "newer.yml"
    end

    # The list reads what the save would store, typed secrets included, and shows a host a secret
    # fills as its template, so the typed value never reaches the page.
    test "a host a typed secret fills shows as its template", %{conn: conn} = ctx do
      newer =
        definition("newer", %{
          "replaces" => ["tracker"],
          "description" => "https://{{ .Config.username }}.evil.invalid/"
        })

      assert {:ok, {:loaded, _}} = apply_files([{"v11", "newer.yml", newer}])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{ctx.row.id}-switch") |> render_click()
      change(lv, %{"secrets[username]" => "SYNTH-user-5d2a"})

      assert has_dialog_element?(
               lv,
               "#indexer-form-hosts li",
               "https://{{ .Config.username }}.evil.invalid"
             )

      refute dialog(lv) =~ "SYNTH-user-5d2a"
      refute dialog(lv) =~ @password
    end

    # A host the indexer sends to today stays off the list until a typed secret moves it.
    test "a typed secret that changes a host the indexer sends to today lists it", %{conn: conn} do
      url = "https://{{ .Config.username }}.x.invalid/"
      running = definition("tracker", %{"description" => url})
      mirror!(running)
      row = cardigann!(running, %{"password" => @password, "username" => "own"})

      newer = definition("newer", %{"replaces" => ["tracker"], "description" => url})
      assert {:ok, {:loaded, _}} = apply_files([{"v11", "newer.yml", newer}])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{row.id}-switch") |> render_click()
      refute has_dialog_element?(lv, "#indexer-form-hosts")

      change(lv, %{"secrets[username]" => "other"})

      assert has_dialog_element?(lv, "#indexer-form-hosts li", "{{ .Config.username }}.x.invalid")
      refute dialog(lv) =~ "other.x.invalid"
    end

    # A save whose input moves a host the form did not list yet, with no change event between
    # (#1890): the store refuses it, and the refused form lists the hosts of the input it sent.
    test "a refused save lists the hosts of the input it sent", %{conn: conn} do
      url = "https://{{ .Config.username }}.x.invalid/"
      running = definition("tracker", %{"description" => url})
      mirror!(running)
      row = cardigann!(running, %{"password" => @password, "username" => "own"})

      newer = definition("newer", %{"replaces" => ["tracker"], "description" => url})
      assert {:ok, {:loaded, _}} = apply_files([{"v11", "newer.yml", newer}])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{row.id}-switch") |> render_click()
      refute has_dialog_element?(lv, "#indexer-form-hosts")

      submit(lv, %{"secrets[username]" => "other"})

      assert has_dialog_element?(lv, ".indexer-form-error", "check the list again")
      assert has_dialog_element?(lv, "#indexer-form-hosts li", "{{ .Config.username }}.x.invalid")
      assert stored_row(row.id).definition == "tracker.yml"
      refute dialog(lv) =~ "other.x.invalid"
    end

    # A submit can leave the browser before the re-render of a change the server already read.
    # The save sends the digest the form drew, so the store refuses the list the admin never saw;
    # once the form draws it, the same input saves.
    test "a save sends the digest of the list the form drew", %{conn: conn} do
      url = "https://{{ .Config.username }}.x.invalid/"
      running = definition("tracker", %{"description" => url})
      mirror!(running)
      row = cardigann!(running, %{"password" => @password, "username" => "own"})

      newer = definition("newer", %{"replaces" => ["tracker"], "description" => url})
      assert {:ok, {:loaded, _}} = apply_files([{"v11", "newer.yml", newer}])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{row.id}-switch") |> render_click()
      typed = %{"secrets[username]" => "other"}
      drawn_before = form_params(lv, typed)

      change(lv, typed)
      assert has_dialog_element?(lv, "#indexer-form-hosts li", "{{ .Config.username }}.x.invalid")

      lv |> target() |> render_submit("save", drawn_before)
      assert has_dialog_element?(lv, ".indexer-form-error", "check the list again")
      assert stored_row(row.id).definition == "tracker.yml"

      submit(lv, typed)
      assert stored_row(row.id).definition == "newer.yml"
    end

    # The name, the priority and Enabled feed no host, so a change from one of them leaves the
    # list as it was, even with a secret input that would move a host.
    test "a change from the name, the priority or Enabled reads no hosts", %{conn: conn} do
      url = "https://{{ .Config.username }}.x.invalid/"
      running = definition("tracker", %{"description" => url})
      mirror!(running)
      row = cardigann!(running, %{"password" => @password, "username" => "own"})

      newer = definition("newer", %{"replaces" => ["tracker"], "description" => url})
      assert {:ok, {:loaded, _}} = apply_files([{"v11", "newer.yml", newer}])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{row.id}-switch") |> render_click()

      for field <- ["name", "priority", "enabled"] do
        params =
          lv
          |> form_params(%{"secrets[username]" => "other"})
          |> Map.put("_target", ["indexer", field])

        lv |> target() |> render_change("change", params)
        refute has_dialog_element?(lv, "#indexer-form-hosts")
      end

      change(lv, %{"secrets[username]" => "other"})
      assert has_dialog_element?(lv, "#indexer-form-hosts li", "{{ .Config.username }}.x.invalid")
    end

    # An out-of-range priority makes the save refuse, so the form shows no list; the change that
    # puts it back reads the list again, and the first save goes through.
    test "a priority change that lifts the save's refusal reads the hosts again",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{ctx.row.id}-switch") |> render_click()

      change(lv, %{"indexer[priority]" => "0"})
      assert has_dialog_element?(lv, "#indexer-form-hosts-unknown")

      params =
        lv
        |> form_params(%{"indexer[priority]" => "7"})
        |> Map.put("_target", ["indexer", "priority"])

      lv |> target() |> render_change("change", params)
      refute has_dialog_element?(lv, "#indexer-form-hosts-unknown")
      assert has_dialog_element?(lv, "#indexer-form-hosts li", "new.invalid")

      submit(lv)
      assert stored_row(ctx.row.id).definition == "newer.yml"
    end

    # A blank name casts to nil: the list and the save read it without raising, and the save
    # refuses it as required.
    test "a blank name refuses the save and keeps the dialog", %{conn: conn} = ctx do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{ctx.row.id}-switch") |> render_click()

      change(lv, %{"indexer[name]" => ""})
      change(lv, %{"indexer[name]" => "", "secrets[username]" => "me"})
      assert has_dialog_element?(lv, "#indexer-form-name")

      submit(lv, %{"indexer[name]" => ""})
      assert has_dialog_element?(lv, "#indexer-form-name")
      assert dialog(lv) =~ "Enter a name."
      assert stored_row(ctx.row.id).definition == "tracker.yml"
      assert stored_row(ctx.row.id).name == ctx.row.name
    end

    test "a replacing copy Cinder cannot run opens no form and says so", %{conn: conn} = ctx do
      # `Cinder.DefinitionFixtures.check/1` keeps `[:html_search]` unsupported for an id in -ns.
      newer = definition("newer-ns", %{"replaces" => ["tracker"]})
      assert {:ok, {:loaded, _}} = apply_files([{"v11", "newer.yml", newer}])

      assert %{result: {:not_supported, _}} =
               Enum.find(Definitions.picker(), &(&1.name == "newer.yml"))

      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{ctx.row.id}-switch") |> render_click()

      assert has_element?(lv, "#indexers-notice", "The replacing definition can't be used.")
      refute has_element?(lv, "#indexer-dialog")
      assert stored_row(ctx.row.id).definition == "tracker.yml"
    end
  end

  # The state reads "Replaced by" and Switch shows only once another file replaces the row's.
  test "a row offers Switch once its definition is replaced, and not before", %{conn: conn} do
    ConfigCase.put_env(:indexer_adapters, %{cardigann: Cinder.Acquisition.Indexer.Cardigann})
    mirror!(@base)
    row = cardigann!(@base)
    assert IndexerStatus.record(row, :success, @now) == :written

    {:ok, lv, _html} = live(conn, ~p"/settings")
    assert has_element?(lv, "#indexer-#{row.id}-edit")
    refute has_element?(lv, "#indexer-#{row.id}-switch")

    newer = definition("newer", %{"replaces" => ["tracker"]})
    assert {:ok, {:loaded, _}} = apply_files([{"v11", "newer.yml", newer}])

    {:ok, lv, _html} = live(conn, ~p"/settings")
    assert has_element?(lv, "#indexer-#{row.id}-detail", "Replaced by newer.yml")

    assert has_element?(
             lv,
             "#indexer-#{row.id}-switch[aria-label='Switch to newer.yml for #{row.name}']",
             "Switch to newer.yml"
           )
  end

  # A running copy that no longer loads reads red, which outranks the held and replaced codes:
  # Accept update and Switch still show, since each is the way to a copy that runs.
  describe "a row whose running copy no longer loads" do
    test "still offers Accept update for a held copy", %{conn: conn} do
      mirror!(@base)
      row = cardigann!(@base, %{"password" => @password})
      mirror!(definition("tracker", %{"description" => "https://new.invalid/"}))
      :ok = Definitions.store_results([{blob_sha(@base), {:error, :not_utf8}}])
      assert pin(row).hold == :hosts

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexer-#{row.id}-test[disabled]")
      lv |> element("#indexer-#{row.id}-accept") |> render_click()
      assert has_dialog_element?(lv, "#indexer-accept-confirm")
    end

    test "still offers Switch once its definition is replaced", %{conn: conn} do
      mirror!(@base)
      row = cardigann!(@base)
      newer = definition("newer", %{"replaces" => ["tracker"]})
      assert {:ok, {:loaded, _}} = apply_files([{"v11", "newer.yml", newer}])
      :ok = Definitions.store_results([{blob_sha(@base), {:error, :not_utf8}}])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexer-#{row.id}-test[disabled]")
      lv |> element("#indexer-#{row.id}-switch") |> render_click()
      assert has_dialog_element?(lv, "#indexer-form-kind", "newer.yml")
    end
  end

  describe "the Test button" do
    test "is disabled for an indexer whose running copy no longer loads", %{conn: conn} do
      mirror!(@base)
      row = cardigann!(@base)
      :ok = Definitions.store_results([{blob_sha(@base), {:error, :not_utf8}}])

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexer-#{row.id}-test[disabled]")
    end

    test "is disabled for an indexer whose running copy reads not supported", %{conn: conn} do
      # `Cinder.DefinitionFixtures.check/1` keeps `[:html_search]` unsupported for an id in -ns.
      unsupported = definition("tracker-ns")
      mirror!(unsupported)
      row = cardigann!(unsupported)

      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert has_element?(lv, "#indexer-#{row.id}-test[disabled]")
    end

    test "is enabled for an indexer whose copy runs", %{conn: conn} do
      mirror!(@base)
      row = cardigann!(@base)
      {:ok, lv, _html} = live(conn, ~p"/settings")
      refute has_element?(lv, "#indexer-#{row.id}-test[disabled]")
    end
  end
end
