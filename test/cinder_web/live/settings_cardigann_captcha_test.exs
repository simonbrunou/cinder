defmodule CinderWeb.SettingsCardigannCaptchaTest do
  # The image captcha in the Cardigann dialogs of /settings (#1681): Show captcha, the answer
  # saved with the form, the add flow, and what the page refuses. The load and the Test run
  # through `IndexerAdapterMock` for the Cardigann type, so these tests see what the page hands
  # Native: the real load and login run in `Cinder.Acquisition.Indexer.CardigannCaptchaTest`.
  # The dialogs are a `<.portal>` to `body`, as `CinderWeb.SettingsCardigannTest` reads them.
  #
  # Not async: the Test runner, Native's clock, the adapter map and the Logger level are app-wide.
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.DefinitionFixtures
  import Cinder.TestRunnerHelpers
  import ExUnit.CaptureLog

  alias Cinder.Acquisition.Indexer.Cardigann.Jar
  alias Cinder.Acquisition.IndexerAdapterMock
  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerCaptchas, TestRunner}
  alias Cinder.ConfigCase
  alias Cinder.Indexers
  alias Cinder.Repo
  alias Plug.Conn.Query

  @now ~U[2026-11-26 12:00:00Z]
  @answer "XyZ12-answer"
  @png <<0x89, "PNG\r\n", 0x1A, "\n", "png-body">>

  setup :register_and_log_in_admin
  setup :reset_cinder_env
  setup {Mox, :set_mox_global}

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    block_tests()

    ConfigCase.put_env(:indexer_adapters, %{
      newznab: IndexerAdapterMock,
      cardigann: IndexerAdapterMock
    })

    stop_tests_on_exit()
    :ok = TestRunner.subscribe()
    copy = captcha_definition()
    mirror!(copy)
    %{copy: copy}
  end

  defp captcha_definition(extra \\ %{}) do
    definition(
      "tracker",
      Map.merge(
        %{
          "links" => [link(), "https://second.invalid/"],
          "login" => %{
            "method" => "form",
            "path" => "login.php",
            "inputs" => %{
              "username" => "{{ .Config.username }}",
              "password" => "{{ .Config.password }}"
            },
            "captcha" => %{
              "type" => "image",
              "selector" => "img#captcha",
              "input" => "imagestring"
            },
            "error" => [%{"selector" => "div.error"}],
            "test" => %{"path" => "my.php"}
          }
        },
        extra
      )
    )
  end

  # A load that answers as the real one does for `copy`'s indexer, with its binding, and tells
  # the test it ran.
  defp stub_load(copy, answer \\ :png) do
    test_pid = self()

    Mox.stub(IndexerAdapterMock, :load_captcha, fn indexer, context ->
      send(test_pid, {:load, indexer.id, context.priority})

      case answer do
        :png ->
          {:ok,
           %{
             binding: %{address: link(), blob_sha: blob_sha(copy)},
             jar: Jar.new(),
             landing: link() <> "login.php",
             form: %{"form_row" => %{}, "inputs" => [], "html" => %{}},
             image: @png,
             mime: "image/png"
           }}

        :block ->
          send(test_pid, {:blocked, self()})

          receive do
            {:go, answer} -> answer
          end

        error ->
          error
      end
    end)
  end

  # The Test reports the captcha it carries.
  defp stub_answered_test do
    test_pid = self()

    Mox.stub(IndexerAdapterMock, :test, fn indexer, context, record ->
      captcha = Map.get(context, :captcha)

      send(
        test_pid,
        {:tested, indexer.id, captcha && captcha.token, captcha && captcha.answer.()}
      )

      {:ran, record.(:test_success)}
    end)
  end

  defp row!(copy) do
    cardigann!(copy, %{"username" => "frieren", "password" => "pw-Secret-91"}, %{
      name: "Captcha site"
    })
  end

  defp dialog(lv), do: lv |> element("#indexer-dialog") |> render()

  defp dialog_doc(lv) do
    lv
    |> dialog()
    |> String.replace(~r/\A\s*<template[^>]*>/, "")
    |> String.replace(~r/<\/template>\s*\z/, "")
    |> LazyHTML.from_fragment()
  end

  defp nodes(lv, selector), do: lv |> dialog_doc() |> LazyHTML.query(selector) |> Enum.to_list()

  defp has?(lv, selector, text \\ nil),
    do: Enum.any?(nodes(lv, selector), &(text == nil or LazyHTML.text(&1) =~ text))

  defp attribute(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  defp target(lv), do: with_target(lv, "#indexers")

  defp open_edit(lv, row), do: lv |> element("#indexer-#{row.id}-edit") |> render_click()

  defp load(lv) do
    lv |> target() |> render_click("load_captcha", %{})
    render_async(lv)
  end

  defp form_params(lv, typed) do
    fields =
      for node <- nodes(lv, "#indexer-form input[name], #indexer-form select[name]"),
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

  defp answer_field(lv) do
    [input] = nodes(lv, "input[name='captcha[answer]']")
    attribute(input, "name")
  end

  defp session_stored?(row), do: Repo.get(IndexerCaptchas, row.id) != nil

  # The answer input's id, new on each load, and its `phx-update`: an input with the same id
  # that patches leave alone keeps what the admin typed.
  defp answer_input(lv) do
    [input] = nodes(lv, "input[name='captcha[answer]']")
    {attribute(input, "id"), attribute(input, "phx-update")}
  end

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

  describe "an edit of a site whose login shows an image captcha" do
    test "Show captcha shows the image, and a save with the answer starts the Test that carries it",
         %{conn: conn, copy: copy} do
      row = row!(copy)
      stub_load(copy)
      stub_answered_test()

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, row)
      assert has?(lv, "#indexer-form-captcha-load", "Show captcha")
      refute has?(lv, "#indexer-form-captcha-image")

      load(lv)
      assert_received {:load, id, :interactive}
      assert id == row.id
      assert session_stored?(row)

      [image] = nodes(lv, "#indexer-form-captcha-image")
      assert attribute(image, "src") == "data:image/png;base64," <> Base.encode64(@png)
      assert attribute(image, "alt") == "Captcha from Captcha site"
      assert has?(lv, "#indexer-form-captcha-load", "New captcha")
      assert has?(lv, "label", "Captcha answer")

      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      state = fn ->
        inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity)
      end

      field = answer_field(lv)

      changed =
        capture_log([level: :debug], fn ->
          lv |> target() |> render_change("change", form_params(lv, %{field => @answer}))
        end)

      refute state.() =~ @answer

      {saved_html, saved} =
        with_log([level: :debug], fn -> submit(lv, %{field => @answer}) end)

      assert_receive {:tested, ^id, token, @answer}
      assert is_binary(token)
      refute_received {:test_started, _pid, _id}

      for log <- [changed, saved] do
        assert log =~ ~s("captcha" => "[FILTERED]")
        refute log =~ @answer
      end

      refute state.() =~ @answer
      refute render(lv) =~ @answer
      refute render(lv) =~ "indexer-form-captcha-image"
      assert saved_html =~ "Captcha site saved: logging in with the captcha answer."
    end

    test "a save with no answer starts the Test a save starts, with no captcha",
         %{conn: conn, copy: copy} do
      row = row!(copy)
      stub_load(copy)
      stub_answered_test()

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, row)
      load(lv)
      submit(lv, %{"indexer[settings][sort]" => "size"})

      assert_receive {:tested, _id, nil, nil}
    end

    test "a save whose session expired is refused, and starts no Test", %{conn: conn, copy: copy} do
      row = row!(copy)
      stub_load(copy)
      stub_answered_test()

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, row)
      load(lv)
      field = answer_field(lv)

      ConfigCase.put_env(Native, clock: fn -> DateTime.add(@now, 300, :second) end)
      submit(lv, %{field => @answer, "indexer[priority]" => "7"})

      assert has?(
               lv,
               "#indexer-form-captcha-message[role=alert]",
               "This captcha expired: show a new one."
             )

      refute has?(lv, "#indexer-form-captcha-image")
      refute_received {:tested, _id, _token, _answer}

      assert Indexers.fetch_with_secrets(row.id) |> elem(1) |> Map.fetch!(:priority) ==
               row.priority
    end

    test "a save that also moves the base URL is refused", %{conn: conn, copy: copy} do
      row = row!(copy)
      stub_load(copy)
      stub_answered_test()

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, row)
      load(lv)
      field = answer_field(lv)
      kept = answer_input(lv)
      assert {_id, "ignore"} = kept
      submit(lv, %{field => @answer, "indexer[base_url]" => "https://second.invalid/"})

      assert has?(
               lv,
               "#indexer-form-captcha-message[role=alert]",
               "Save the new base URL first, then show a new captcha."
             )

      # The browser keeps what the admin typed: same input, which patches leave alone.
      assert answer_input(lv) == kept

      refute_received {:tested, _id, _token, _answer}
      assert Repo.get!(Cinder.Indexers.ConfiguredIndexer, row.id).base_url == link()
    end

    test "a save while a Test runs keeps the dialog open, and the next save starts the answered Test",
         %{conn: conn, copy: copy} do
      row = row!(copy)
      stub_load(copy)

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, row)
      load(lv)
      field = answer_field(lv)

      :ok = TestRunner.start(row.id)
      assert_receive {:test_started, task, id}
      assert id == row.id

      kept = answer_input(lv)
      assert {_id, "ignore"} = kept
      submit(lv, %{field => @answer, "indexer[priority]" => "7"})

      assert has?(
               lv,
               "#indexer-form-captcha-message[role=alert]",
               "A Test of Captcha site is running: save again once it ends."
             )

      assert has?(lv, "#indexer-form-captcha-image")
      assert answer_input(lv) == kept

      answer(task, :test_success)
      assert_receive {TestRunner, :finished, ^id, {:ok, _}}
      stub_answered_test()

      submit(lv, %{field => @answer})
      assert_receive {:tested, ^id, _token, @answer}
    end

    test "a load that fails says why", %{conn: conn, copy: copy} do
      row = row!(copy)

      for {error, words} <- [
            {{:error, :captcha_not_found}, "The site sent no captcha image."},
            {{:error, {:captcha_image, :type}}, "it is no PNG, JPEG, GIF or WebP image"},
            {{:error, {:http_status, 404}}, "The site answered HTTP 404 for the captcha."},
            {{:error, :timeout}, "The captcha could not be loaded: Timed out."}
          ] do
        stub_load(copy, error)
        {:ok, lv, _html} = live(conn, ~p"/settings")
        open_edit(lv, row)
        load(lv)

        assert has?(lv, "#indexer-form-captcha-message[role=alert]", words)
        refute has?(lv, "#indexer-form-captcha-image")
        assert has?(lv, "#indexer-form-captcha-load", "Show captcha")
        # The load disabled the focused button: focus goes back to it.
        assert_push_event(lv, "focus-invalid", %{id: "indexer-form-captcha-load"})
      end
    end

    test "a load killed past the heap cap says so, and the page lives on", %{
      conn: conn,
      copy: copy
    } do
      row = row!(copy)
      words = Native.max_heap_size().size

      Mox.stub(IndexerAdapterMock, :load_captcha, fn _indexer, _context ->
        # A list of n integers takes 2n words of heap.
        grown = Enum.to_list(1..words)
        if grown != [], do: {:error, :captcha_not_found}
      end)

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, row)

      capture_log(fn ->
        lv |> target() |> render_click("load_captcha", %{})
        render_async(lv, 10_000)
      end)

      assert Process.alive?(lv.pid)

      assert has?(
               lv,
               "#indexer-form-captcha-message[role=alert]",
               "The captcha could not be loaded. Try again."
             )
    end

    test "a load that ends after its dialog closed shows nothing", %{conn: conn, copy: copy} do
      row = row!(copy)
      stub_load(copy, :block)

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, row)
      lv |> target() |> render_click("load_captcha", %{})
      assert_receive {:blocked, task}
      assert has?(lv, "#indexer-form-captcha-load[disabled]")

      lv |> target() |> render_click("close", %{})
      send(task, {:go, {:error, :captcha_not_found}})
      render_async(lv)

      open_edit(lv, row)
      refute has?(lv, "#indexer-form-captcha-message")
      assert has?(lv, "#indexer-form-captcha-load:not([disabled])", "Show captcha")
    end

    test "a load a newer one replaced shows nothing", %{conn: conn, copy: copy} do
      row = row!(copy)
      stub_load(copy, :block)

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, row)
      lv |> target() |> render_click("load_captcha", %{})
      assert_receive {:blocked, first}

      lv |> target() |> render_click("close", %{})
      open_edit(lv, row)
      lv |> target() |> render_click("load_captcha", %{})
      assert_receive {:blocked, second}

      # The first load answers while the second one runs: the page waits for the second.
      ref = Process.monitor(first)
      send(first, {:go, {:error, :captcha_not_found}})
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}
      refute has?(lv, "#indexer-form-captcha-message")
      assert has?(lv, "#indexer-form-captcha-load[disabled]")

      send(second, {:go, {:error, {:http_status, 503}}})
      render_async(lv)
      assert has?(lv, "#indexer-form-captcha-message", "HTTP 503")
    end

    test "an edit of a site with no captcha shows no captcha block", %{conn: conn} do
      plain = definition("tracker")
      mirror!(plain)
      row = cardigann!(plain, %{"username" => "frieren", "password" => "pw"})

      {:ok, lv, _html} = live(conn, ~p"/settings")
      open_edit(lv, row)
      refute has?(lv, "#indexer-form-captcha")
      assert lv |> target() |> render_click("load_captcha", %{})
      refute_received {:load, _id, _priority}
    end
  end

  describe "an add of a site whose login shows an image captcha" do
    test "says the captcha comes after the save, then opens the new row's edit and loads it, whose answer a disabled row's save carries to a Test",
         %{conn: conn, copy: copy} do
      stub_load(copy)
      stub_answered_test()

      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexers-add") |> render_click()
      lv |> target() |> render_click("pick_definition", %{"name" => "tracker.yml"})

      assert has?(
               lv,
               "#indexer-form-captcha-after-save",
               "Save this indexer first, then solve its captcha here."
             )

      refute has?(lv, "#indexer-form-captcha-load")

      submit(lv, %{"indexer[name]" => "Captcha site", "indexer[enabled]" => "false"})
      render_async(lv)

      [row] = Indexers.list()
      assert_received {:load, id, :interactive}
      assert id == row.id
      assert has?(lv, "#indexer-dialog-edit")
      assert has?(lv, "#indexer-form-captcha-image")

      refute row.enabled
      submit(lv, %{answer_field(lv) => @answer})
      assert_receive {:tested, ^id, _token, @answer}
    end

    test "an enabled add starts its Test-on-save, which reads the captcha, and still opens the edit with the captcha loaded",
         %{conn: conn, copy: copy} do
      stub_load(copy)

      {:ok, lv, _html} = live(conn, ~p"/settings")
      lv |> element("#indexers-add") |> render_click()
      lv |> target() |> render_click("pick_definition", %{"name" => "tracker.yml"})

      submit(lv, %{"indexer[name]" => "Captcha site", "indexer[enabled]" => "true"})
      render_async(lv)

      [row] = Indexers.list()
      assert row.enabled
      id = row.id
      assert_receive {:test_started, test_pid, ^id}
      assert_received {:load, ^id, :interactive}
      assert has?(lv, "#indexer-dialog-edit")
      assert has?(lv, "#indexer-form-captcha-image")

      answer(test_pid, {:rejected_credentials, :captcha_required})
      assert_receive {TestRunner, :finished, ^id, _result}
      # The page gets the same broadcast: its read of the rows follows it.
      eventually(fn -> render(lv) =~ "Login needs a captcha: solve it in Settings" end)
    end
  end
end
