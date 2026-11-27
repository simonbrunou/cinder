defmodule CinderWeb.SettingsFlareSolverrTest do
  # FlareSolverr in the indexers component of /settings (#1682): the URL line under the table and
  # its dialog, and the Cardigann form's toggle and URL field. The dialogs are a `<.portal>` to
  # `body`: a test renders the portal and sends events with `with_target(view, "#indexers")`, as
  # `CinderWeb.SettingsCardigannTest` does. Definitions come from `Cinder.DefinitionFixtures`.
  #
  # Not async: the Test runner, Native's clock and the FlareSolverr URL setting are app-wide.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.DefinitionFixtures
  import Cinder.TestRunnerHelpers

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.TestRunner
  alias Cinder.ConfigCase
  alias Cinder.Indexers
  alias Cinder.Indexers.FlareSolverrUrl
  alias Plug.Conn.Query

  @now ~U[2026-11-27 12:00:00Z]
  @url "http://flaresolverr.lan:8191"

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

  defp line(lv), do: lv |> element("#indexers-flaresolverr-line") |> render()

  defp open_url_dialog(lv), do: lv |> element("#indexers-flaresolverr") |> render_click()

  defp save_url(lv, url),
    do: lv |> target() |> render_submit("flaresolverr_save", %{"flaresolverr" => %{"url" => url}})

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

  defp submit(lv, typed), do: lv |> target() |> render_submit("save", form_params(lv, typed))
  defp change(lv, typed), do: lv |> target() |> render_change("change", form_params(lv, typed))

  defp add_tracker(lv) do
    lv |> element("#indexers-add") |> render_click()
    lv |> target() |> render_click("pick_definition", %{"name" => "tracker.yml"})
  end

  # A Cardigann indexer with its toggle on; the mirror must hold `definition/0`.
  defp toggled_tracker!(enabled?),
    do: cardigann!(definition(), %{}, %{flaresolverr: true, enabled: enabled?})

  describe "the URL line and its dialog" do
    test "reads not set, then the URL once the dialog saves it, trimmed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      assert line(lv) =~ "FlareSolverr: not set"
      assert lv |> element("#indexers-flaresolverr") |> render() =~ "Set"

      open_url_dialog(lv)
      assert has_dialog_element?(lv, "#indexer-dialog-title", "FlareSolverr URL")

      assert has_dialog_element?(
               lv,
               "#flaresolverr-help",
               "FlareSolverr's browser runs each site's JavaScript and can reach your local network. Run it where it cannot."
             )

      # The input is named apart from the setting's key, which /settings renders no input for.
      assert has_dialog_element?(lv, "input#flaresolverr-url[name='flaresolverr[url]']")

      save_url(lv, "  #{@url} ")
      assert FlareSolverrUrl.get() == @url
      refute has_element?(lv, "#indexer-dialog")
      assert line(lv) =~ "FlareSolverr: #{@url}"
      assert lv |> element("#indexers-flaresolverr") |> render() =~ "Edit"
    end

    test "a URL with user info is refused, and nothing is saved", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_url_dialog(lv)
      save_url(lv, "http://user:pw@fs.lan:8191")
      assert_push_event(lv, "focus-invalid", %{id: "flaresolverr-url"})

      assert has_dialog_element?(
               lv,
               "#flaresolverr-url-error",
               "Enter an http or https URL with no user name, query or fragment."
             )

      assert FlareSolverrUrl.get() == nil
    end

    test "clearing it shows the count of enabled indexers that use it first", %{conn: conn} do
      :ok = FlareSolverrUrl.put(@url)
      mirror!(definition())
      toggled_tracker!(true)

      # A Torznab row with the toggle on reads "Not supported: FlareSolverr": not counted.
      {:ok, _torznab} =
        Indexers.create(
          nil,
          %{
            name: "Tagged",
            type: :torznab,
            base_url: "https://torznab.example",
            api_path: "/api",
            flaresolverr: true
          },
          %{"api_key" => "torznab-key-0123456789"}
        )

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_url_dialog(lv)
      assert has_dialog_element?(lv, "input#flaresolverr-url[value='#{@url}']")

      save_url(lv, "")

      assert has_dialog_element?(
               lv,
               "#flaresolverr-in-use",
               "1 enabled indexer uses FlareSolverr."
             )

      # The count moves focus to the button that now reads Clear it.
      assert_push_event(lv, "focus-invalid", %{id: "flaresolverr-save"})
      assert has_dialog_element?(lv, "#flaresolverr-save", "Clear it")

      assert FlareSolverrUrl.get() == @url

      save_url(lv, "")
      assert FlareSolverrUrl.get() == nil
      assert line(lv) =~ "FlareSolverr: not set"
    end

    test "clearing it with no enabled indexer using it saves at once", %{conn: conn} do
      :ok = FlareSolverrUrl.put(@url)
      mirror!(definition())
      toggled_tracker!(false)
      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_url_dialog(lv)
      save_url(lv, "")
      assert FlareSolverrUrl.get() == nil
      refute has_element?(lv, "#indexer-dialog")
    end
  end

  describe "the Cardigann form" do
    setup do
      mirror!(definition())
      :ok
    end

    test "shows the toggle off, and the URL field only while it is on and no URL is saved",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      add_tracker(lv)

      assert has_dialog_element?(lv, "input#indexer-form-flaresolverr[type='checkbox']")
      assert has_dialog_element?(lv, "label", "Use FlareSolverr")

      assert has_dialog_element?(
               lv,
               "#indexer-form-flaresolverr-help",
               "Cinder calls FlareSolverr only when the site answers with a Cloudflare or DDoS-Guard challenge."
             )

      refute has_dialog_element?(lv, "#indexer-form-flaresolverr[checked]")
      refute has_dialog_element?(lv, "#indexer-form-flaresolverr-url")

      change(lv, %{"indexer[flaresolverr]" => "true"})

      assert has_dialog_element?(
               lv,
               "input#indexer-form-flaresolverr-url[name='flaresolverr[url]']"
             )

      :ok = FlareSolverrUrl.put(@url)
      change(lv, %{"indexer[flaresolverr]" => "true"})
      refute has_dialog_element?(lv, "#indexer-form-flaresolverr-url")
    end

    test "the toggle with a blank URL is refused, and nothing is saved", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      add_tracker(lv)
      change(lv, %{"indexer[flaresolverr]" => "true"})
      submit(lv, %{"indexer[flaresolverr]" => "true", "flaresolverr[url]" => " "})

      assert has_dialog_element?(
               lv,
               "#indexer-form-flaresolverr-url-error",
               "Enter FlareSolverr's URL, or turn FlareSolverr off."
             )

      assert Indexers.list() == []
      assert FlareSolverrUrl.get() == nil
    end

    test "a URL that is not one is refused with the setting's words", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      add_tracker(lv)
      change(lv, %{"indexer[flaresolverr]" => "true"})
      submit(lv, %{"indexer[flaresolverr]" => "true", "flaresolverr[url]" => "fs.lan:8191"})

      assert has_dialog_element?(
               lv,
               "#indexer-form-flaresolverr-url-error",
               "Enter an http or https URL with no user name, query or fragment."
             )

      assert Indexers.list() == []
    end

    test "the URL saves first, then the indexer with its toggle on", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      add_tracker(lv)
      change(lv, %{"indexer[flaresolverr]" => "true"})
      submit(lv, %{"indexer[flaresolverr]" => "true", "flaresolverr[url]" => @url})

      assert FlareSolverrUrl.get() == @url
      assert [%{flaresolverr: true}] = Indexers.list()
      assert line(lv) =~ "FlareSolverr: #{@url}"
    end

    test "the URL stays saved when the indexer's save is refused", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings")
      add_tracker(lv)
      change(lv, %{"indexer[flaresolverr]" => "true"})

      submit(lv, %{
        "indexer[flaresolverr]" => "true",
        "indexer[name]" => "",
        "flaresolverr[url]" => @url
      })

      assert Indexers.list() == []
      assert FlareSolverrUrl.get() == @url
      assert has_dialog_element?(lv, "#indexer-form")
      assert line(lv) =~ "FlareSolverr: #{@url}"
    end

    test "an edit that turns the toggle off saves it off", %{conn: conn} do
      :ok = FlareSolverrUrl.put(@url)
      row = toggled_tracker!(true)
      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexer-#{row.id}-edit") |> render_click()
      assert has_dialog_element?(lv, "#indexer-form-flaresolverr[checked]")

      submit(lv, %{"indexer[flaresolverr]" => "false"})
      assert [%{flaresolverr: false}] = Indexers.list()
    end
  end

  test "the Newznab and Torznab forms have no FlareSolverr toggle", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings")

    for type <- ["newznab", "torznab"] do
      lv |> element("#indexers-add") |> render_click()
      lv |> target() |> render_click("pick", %{"type" => type})
      assert has_dialog_element?(lv, "#indexer-form")
      refute dialog(lv) =~ "FlareSolverr"
      lv |> target() |> render_click("close", %{})
    end
  end
end
