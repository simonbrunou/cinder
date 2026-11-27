defmodule CinderWeb.SettingsCardigannTest do
  # Cardigann sites in the indexers component of /settings (#1676): the add list's sites, the
  # Cardigann form, Accept update, a replaced row and the Test button of a copy that does not
  # run. The dialogs are a `<.portal>` to `body`: a test renders the portal and sends events with
  # `with_target(view, "#indexers")`, as `CinderWeb.SettingsIndexerDialogsTest` does. Definitions
  # come from `Cinder.DefinitionFixtures`.
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

  # Switch to <name> left #1676 for #1907: a row whose definition another file replaces reads
  # its state and offers no way onto the replacing copy.
  test "a row whose definition is replaced reads so and offers no Switch", %{conn: conn} do
    ConfigCase.put_env(:indexer_adapters, %{cardigann: Cinder.Acquisition.Indexer.Cardigann})
    mirror!(@base)
    row = cardigann!(@base)
    assert IndexerStatus.record(row, :success, @now) == :written
    newer = definition("newer", %{"replaces" => ["tracker"]})
    assert {:ok, {:loaded, _}} = apply_files([{"v11", "newer.yml", newer}])

    {:ok, lv, html} = live(conn, ~p"/settings")
    assert has_element?(lv, "#indexer-#{row.id}-detail", "Replaced by newer.yml")
    assert has_element?(lv, "#indexer-#{row.id}-edit")
    refute has_element?(lv, "#indexer-#{row.id}-switch")
    refute html =~ "Switch to"
  end

  # A running copy that no longer loads reads red, which outranks the held code: Accept update
  # still shows, since it is the way to a copy that runs.
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
