defmodule Cinder.CodeHealth.LiveViewRawHtmlTest do
  # deps/phoenix/usage-rules/liveview.md tells a LiveView test to check an element with
  # `element/2` and `has_element?/2,3`, never the raw HTML. An `assert` that a whole LiveView's
  # HTML matches a text passes on that text anywhere in the view (a flash, another season's panel,
  # a hidden element), so it stays green when the element under test is gone. #1248's Standards
  # review flagged one such assert. The fence counts each `assert left =~ right` whose `left` is a
  # whole LiveView's HTML: a call to `render/1`, `render_async/1,2` or an event render
  # (`render_click`, `render_submit`, `render_change`, `render_keydown`, `render_keyup`,
  # `render_blur`, `render_focus`, `render_hook`, `render_patch`, `render_upload`), direct or at
  # the end of a pipe; or a variable that an `=` in the same test, setup or function bound to
  # such a call, or to the HTML in `{:ok, view, html}` from `live`, `live_isolated` or
  # `follow_redirect`, direct or piped. Each later `=` that binds the variable decides again
  # whether it counts. A `render` or `render_async` whose argument is an `element/2,3` call,
  # direct or piped, returns only that element's HTML and does not count. An event render returns
  # the whole view even when given an element, so it counts. A `refute`, a function-component
  # render and a controller response do not count (docs/agents/testing.md). The files in
  # `@allowed` held such asserts before this fence: each keeps at most that many, and every other
  # file under test/ holds none.
  # Forms the walk does not follow include: a variable that a helper or the test context gives
  # (`{:ok, lv, html} = live_series(conn, series)`, `{lv, html} = open_season_panel(...)`,
  # `%{html: html}`), that a task returns (`html = DiskTask.await(task)` for a task that renders),
  # that copies another variable, or that another function makes from the HTML
  # (`[_, row | _] = String.split(html, "<li")`); HTML bound in a `case`, `with` or `fn` clause
  # head or a `for` generator; `live_redirect/2`; a call written with its module
  # (`Phoenix.LiveViewTest.render(lv)`); a helper that asserts on its parameter; an assert
  # through another operator or function (`==`, `String.contains?/2`, `Regex.scan/2`) or inside
  # a larger expression (`render(lv) =~ "x" and ok`). The walk reads a test's `=` bindings in
  # source order and ignores the scopes inside it: an `=` in a `fn`, `case`, `if` or `for` body
  # still applies after that body ends, and a name that a clause head or a `for` generator binds
  # keeps its earlier state. So it can miss an assert there, or count one that reads other HTML.
  # It also counts a `render` given a `form/2,3` call or a variable that holds an element.
  use ExUnit.Case, async: true

  @allowed %{
    "test/cinder_web/live/activity_beacon_live_test.exs" => 6,
    "test/cinder_web/live/activity_live_test.exs" => 10,
    "test/cinder_web/live/app_shell_test.exs" => 19,
    "test/cinder_web/live/book_detail_live_audiobook_replace_test.exs" => 1,
    "test/cinder_web/live/book_detail_live_test.exs" => 10,
    "test/cinder_web/live/book_discovery_live_test.exs" => 14,
    "test/cinder_web/live/calendar_live_test.exs" => 12,
    "test/cinder_web/live/dashboard_live_test.exs" => 12,
    "test/cinder_web/live/discover_books_test.exs" => 4,
    "test/cinder_web/live/discover_live_test.exs" => 40,
    "test/cinder_web/live/download_folders_live_test.exs" => 5,
    "test/cinder_web/live/entity_discovery_live_test.exs" => 10,
    "test/cinder_web/live/issues_live_test.exs" => 7,
    "test/cinder_web/live/library_adoption_live_test.exs" => 17,
    "test/cinder_web/live/library_live_test.exs" => 26,
    "test/cinder_web/live/movie_detail_live_test.exs" => 19,
    "test/cinder_web/live/movie_discovery_live_test.exs" => 13,
    "test/cinder_web/live/my_requests_live_test.exs" => 14,
    "test/cinder_web/live/profiles_live_test.exs" => 2,
    "test/cinder_web/live/requests_live_test.exs" => 23,
    "test/cinder_web/live/series_detail_live_test.exs" => 36,
    "test/cinder_web/live/series_discovery_live_test.exs" => 19,
    "test/cinder_web/live/settings_live_test.exs" => 32,
    "test/cinder_web/live/setup_live_test.exs" => 7,
    "test/cinder_web/live/subtitle_sync_live_test.exs" => 10,
    "test/cinder_web/live/user_live/login_test.exs" => 10,
    "test/cinder_web/live/user_live/registration_test.exs" => 17,
    "test/cinder_web/live/user_live/settings_test.exs" => 32,
    "test/cinder_web/live/users_live_test.exs" => 14,
    "test/cinder_web/locale_test.exs" => 2
  }

  @renders [
    :render,
    :render_async,
    :render_click,
    :render_submit,
    :render_change,
    :render_keydown,
    :render_keyup,
    :render_blur,
    :render_focus,
    :render_hook,
    :render_patch,
    :render_upload
  ]
  @element_renders [:render, :render_async]
  @mounts [:live, :live_isolated, :follow_redirect]
  @scopes [:test, :setup, :setup_all, :describe, :def, :defp, :defmacro, :defmacrop]

  setup_all do
    lines =
      for path <- Path.wildcard("test/**/*.{ex,exs}"),
          into: %{},
          do: {path, path |> File.read!() |> assert_lines()}

    %{lines: lines}
  end

  test "no test file asserts on a whole LiveView's HTML more often than its ceiling",
       %{lines: lines} do
    over = over_ceiling(lines, @allowed)

    assert over == [],
           "These files assert on a whole LiveView's HTML more often than allowed:\n" <>
             Enum.join(over, "\n") <>
             "\nCheck the element instead: has_element?(view, selector, text) or " <>
             "view |> element(selector, text) |> has_element?() " <>
             "(deps/phoenix/usage-rules/liveview.md, docs/agents/testing.md)."
  end

  test "each @allowed ceiling is its file's count today", %{lines: lines} do
    stale = stale_ceilings(lines, @allowed)

    assert stale == [],
           "Set each ceiling in @allowed to its file's count, and drop an entry at 0:\n" <>
             Enum.join(stale, "\n")
  end

  test "the ceiling check reports a file above its ceiling and a file outside the map" do
    lines = %{"a" => [3, 9, 12], "b" => [4, 5], "c" => [7], "d" => [], "e" => [1]}
    allowed = %{"a" => 2, "b" => 2, "e" => 3}

    assert over_ceiling(lines, allowed) == [
             "a: lines 3, 9, 12, at most 2",
             "c: lines 7, at most 0"
           ]
  end

  test "the stale check reports a ceiling that differs from its file's count" do
    lines = %{"a" => [3], "b" => [4, 5], "c" => []}
    allowed = %{"a" => 2, "b" => 2, "c" => 0, "gone" => 1}

    assert stale_ceilings(lines, allowed) == [
             "a: 1, ceiling 2",
             "c: 0, ceiling 0",
             "gone: 0, ceiling 1"
           ]
  end

  test "the walk counts each whole-view render, direct or at the end of a pipe" do
    source = ~S'''
    defmodule M do
      test "calls", %{lv: lv, upload: upload} do
        assert render(lv) =~ "x"
        assert render_async(lv) =~ "x"
        assert render_async(lv, 500) =~ "x"
        assert render_click(lv, "go") =~ "x"
        assert render_submit(element(lv, "form"), %{}) =~ "x"
        assert render_change(lv, "validate", %{}) =~ "x"
        assert render_keydown(lv, "key") =~ "x"
        assert render_keyup(lv, "key") =~ "x"
        assert render_blur(lv, "blur") =~ "x"
        assert render_focus(lv, "focus") =~ "x"
        assert render_hook(lv, "hook", %{}) =~ "x"
        assert render_patch(lv, "/next") =~ "x"
        assert render_upload(upload, "a.png") =~ "x"
        assert lv |> render() =~ "x"
        assert lv |> element("#b") |> render_click() =~ "x"
        assert lv |> form("#f", %{}) |> render_submit() =~ ~r/x/, "message"
      end
    end
    '''

    assert assert_lines(source) == Enum.to_list(3..18)
  end

  test "the walk counts a variable bound to a whole view's HTML" do
    source = ~S'''
    defmodule M do
      test "variables", %{conn: conn} do
        {:ok, lv, html} = live(conn, "/")
        assert html =~ "x"
        assert {:ok, _lv, mounted} = conn |> live("/")
        assert mounted =~ "x"
        {:ok, _lv, isolated} = live_isolated(conn, M, session: %{})
        assert isolated =~ "x"
        {:ok, _lv, piped} = conn |> live_isolated(M)
        assert piped =~ "x"
        {:ok, _lv, redirected} = follow_redirect(render_click(lv, "go"), conn)
        assert redirected =~ "x"
        {:ok, _lv, followed} = lv |> element("a") |> render_click() |> follow_redirect(conn)
        assert followed =~ "x"
        rendered = render(lv)
        assert rendered =~ "x"
        clicked = lv |> element("#b") |> render_click()
        assert clicked =~ "x"
      end
    end
    '''

    assert assert_lines(source) == [4, 6, 8, 10, 12, 14, 16, 18]
  end

  test "the walk skips an element's own HTML, a refute and HTML that is not a view's" do
    source = ~S'''
    defmodule M do
      test "allowed", %{conn: conn, lv: lv} do
        assert render(element(lv, "#x")) =~ "y"
        assert lv |> element("#x") |> render_async() =~ "y"
        assert render(lv |> element("#x")) =~ "y"
        assert render_async(element(lv, "#x"), 500) =~ "y"
        tile = lv |> element("#x") |> render()
        assert tile =~ "y"
        refute render(lv) =~ "y"
        {:ok, _lv, html} = live(conn, "/")
        refute html =~ "y"
        assert render_component(&f/1, %{}) =~ "y"
        assert html_response(conn, 200) =~ "y"
        assert rendered_to_string(f(%{})) =~ "y"
        assert conn.resp_body =~ "y"
        assert has_element?(lv, "#x", "y")
      end
    end
    '''

    assert assert_lines(source) == []
  end

  test "the walk counts an assert split across lines and skips one in a comment or a string" do
    source = ~S'''
    defmodule M do
      test "layout", %{lv: lv} do
        assert lv
               |> element("#b")
               |> render_click() =~
                 "x"

        assert render(
                 lv
               ) =~ "x"

        # assert render(lv) =~ "x"
        message = "assert render(lv) =~ \"x\""
        assert message =~ "render"
      end

      @doc """
      assert render(lv) =~ "x"
      """
      def doc, do: :ok
    end
    '''

    assert assert_lines(source) == [3, 8]
  end

  test "a variable counts from its binding until another binding, within its test" do
    source = ~S'''
    defmodule M do
      test "rebinding", %{conn: conn} do
        {:ok, lv, html} = live(conn, "/")
        html = render(element(lv, "#x"))
        assert html =~ "a"
        html = render(lv)
        assert html =~ "b"
        [html] = ["<p>"]
        assert html =~ "c"
        {:ok, _lv, html} = live(conn, "/")
        assert html =~ "d"
        {:ok, ^lv, html} = {:ok, lv, "<p>"}
        assert html =~ "e"
        html = render(lv)
        ^html = render(lv)
        assert html =~ "f"
      end

      test "names", %{lv: lv, test: test} do
        html = render(lv)
        setup = test
        describe(setup)
        assert html =~ "g"
      end

      test "a later test" do
        assert html =~ "h"
      end

      def helper(lv) do
        html = render(lv)
        html
      end

      def other, do: assert(html =~ "i")
    end
    '''

    assert assert_lines(source) == [7, 11, 16, 23]
  end

  test "each test, setup, describe and function starts with no counted variable" do
    source = ~S'''
    defmodule M do
      test "first", %{lv: lv} do
        html = render(lv)
      end

      setup %{lv: lv} do
        assert html =~ "a"
        html = render(lv)
      end

      setup_all do
        assert html =~ "b"
        html = render(lv)
      end

      describe "group" do
        assert html =~ "c"
        html = render(lv)
      end

      def a(lv) do
        assert html =~ "d"
        html = render(lv)
      end

      defp b(lv) do
        assert html =~ "e"
        html = render(lv)
      end

      defmacro c(lv) do
        assert html =~ "f"
        html = render(lv)
      end

      defmacrop d(lv) do
        assert html =~ "g"
        html = render(lv)
        assert html =~ "h"
      end
    end
    '''

    assert assert_lines(source) == [39]
  end

  test "the walk misses the forms its header names and over-counts the ones it names" do
    source = ~S'''
    defmodule M do
      test "missed", %{conn: conn, series: series, lv: lv} do
        {:ok, _lv, from_helper} = live_series(conn, series)
        assert from_helper =~ "x"
        {_lv, pair} = open_season_panel(conn, series)
        assert pair =~ "x"
        panel = render_panel(lv)
        assert panel =~ "x"
        {:ok, _lv, mounted} = live(conn, "/")
        copy = mounted
        assert copy =~ "x"
        assert [_, row | _] = String.split(mounted, "<li")
        assert row =~ "x"

        case live(conn, "/") do
          {:ok, _lv, cased} -> assert cased =~ "x"
        end

        with {:ok, _lv, withed} <- live(conn, "/"), do: assert(withed =~ "x")
        {:ok, _lv, navigated} = live_redirect(lv, to: "/x")
        assert navigated =~ "x"
        assert Phoenix.LiveViewTest.render(lv) =~ "x"
        assert render(lv) == "x"
        assert String.contains?(render(lv), "x")
        assert render(lv) =~ "x" and true
        assert [_] = Regex.scan(~r/x/, render(lv))
        task = Task.async(fn -> lv |> form("#f") |> render_submit() end)
        submitted = Task.await(task)
        assert submitted =~ "x"
        Enum.each([render(lv)], fn page -> assert page =~ "x" end)
        for page <- [render(lv)], do: assert(page =~ "x")
        page = render(lv)
        if page, do: page = "<p>"
        assert page =~ "x"
      end

      test "context", %{html: html} do
        assert html =~ "x"
      end

      defp assert_shows(html, text), do: assert(html =~ text)

      test "over-counted", %{lv: lv} do
        html = render(lv)
        for html <- ["<p>"], do: assert(html =~ "x")
        Enum.each([lv], fn html -> assert html =~ "x" end)
        text = "<p>"
        Enum.each([lv], fn view -> text = render(view) end)
        assert text =~ "x"
        assert render(form(lv, "#f")) =~ "x"
        el = element(lv, "#x")
        assert render(el) =~ "x"
      end
    end
    '''

    assert assert_lines(source) == [45, 46, 49, 50, 52]
  end

  # `path: lines ..., at most N` for each file with more counted asserts than its ceiling.
  defp over_ceiling(lines, allowed) do
    for {path, path_lines} <- Enum.sort(lines),
        length(path_lines) > Map.get(allowed, path, 0),
        do: "#{path}: lines #{Enum.join(path_lines, ", ")}, at most #{Map.get(allowed, path, 0)}"
  end

  # `path: count, ceiling N` for each ceiling that is not its file's count, or that is 0. A file
  # that no longer exists counts 0.
  defp stale_ceilings(lines, allowed) do
    for {path, ceiling} <- Enum.sort(allowed),
        count = lines |> Map.get(path, []) |> length(),
        count != ceiling or ceiling == 0,
        do: "#{path}: #{count}, ceiling #{ceiling}"
  end

  # The lines of the asserts on a whole LiveView's HTML in the parsed source. A string's contents
  # and a comment are not code.
  defp assert_lines(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, {_bound, lines}} =
      Macro.prewalk(ast, {MapSet.new(), []}, fn
        {scope, _meta, [_ | _] = args} = node, {bound, lines} when scope in @scopes ->
          if Keyword.keyword?(List.last(args)) and Keyword.has_key?(List.last(args), :do),
            do: {node, {MapSet.new(), lines}},
            else: {node, {bound, lines}}

        {:=, _meta, [pattern, value]} = node, {bound, lines} ->
          {node, {bind(pattern, value, bound), lines}}

        {:assert, meta, [{:=~, _, [left, _right]} | _]} = node, {bound, lines} ->
          if whole_view?(left) or bound?(left, bound),
            do: {node, {bound, [Keyword.get(meta, :line) | lines]}},
            else: {node, {bound, lines}}

        node, acc ->
          {node, acc}
      end)

    Enum.sort(lines)
  end

  # The variables an `=` binds stop counting, then the one that holds a whole view's HTML starts.
  defp bind(pattern, value, bound) do
    bound = MapSet.difference(bound, pattern_vars(pattern))

    case html_var(pattern, value) do
      nil -> bound
      name -> MapSet.put(bound, name)
    end
  end

  defp html_var({:{}, _, [:ok, _view, {name, _, context}]}, value)
       when is_atom(name) and is_atom(context) do
    if mount?(value), do: name
  end

  defp html_var({name, _, context}, value) when is_atom(name) and is_atom(context) do
    if whole_view?(value), do: name
  end

  defp html_var(_pattern, _value), do: nil

  # A pinned variable keeps its value, so the walk skips what `^` holds.
  defp pattern_vars(pattern) do
    {_ast, vars} =
      Macro.prewalk(pattern, MapSet.new(), fn
        {:^, _, _}, vars ->
          {:pinned, vars}

        {name, _, context} = node, vars when is_atom(name) and is_atom(context) ->
          {node, MapSet.put(vars, name)}

        node, vars ->
          {node, vars}
      end)

    vars
  end

  defp bound?({name, _, context}, bound) when is_atom(name) and is_atom(context),
    do: MapSet.member?(bound, name)

  defp bound?(_left, _bound), do: false

  defp whole_view?({:|>, _, [subject, {name, _, args}]}) when name in @renders and is_list(args),
    do: not (name in @element_renders and element?(subject))

  defp whole_view?({name, _, [subject | _]}) when name in @renders,
    do: not (name in @element_renders and element?(subject))

  defp whole_view?(_expression), do: false

  defp element?({:element, _, args}) when is_list(args), do: true
  defp element?({:|>, _, [_subject, {:element, _, args}]}) when is_list(args), do: true
  defp element?(_expression), do: false

  defp mount?({:|>, _, [_subject, {name, _, args}]}) when name in @mounts and is_list(args),
    do: true

  defp mount?({name, _, args}) when name in @mounts and is_list(args), do: true
  defp mount?(_expression), do: false
end
