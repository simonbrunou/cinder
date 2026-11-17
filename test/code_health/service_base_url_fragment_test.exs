defmodule Cinder.CodeHealth.ServiceBaseUrlFragmentTest do
  # Req joins a request's path onto `base_url` as text, so a configured service URL with a `#`
  # part takes the path into the fragment (#1323). #1339 cut it in 12 clients, and #1406 had to
  # repeat the cut in the two sign-in clients that #1339 left out (#1414). This fence fails a
  # service URL that reaches a request without `HTTPPolicy.without_fragment/1`.
  #
  # The walk reads each file under `lib/` as Elixir AST. It checks the value of each of these
  # sinks:
  #
  # - a `base_url` pair, as `base_url: value` in a keyword list, a map or a call's arguments, or
  #   as the tuple `{:base_url, value}`;
  # - the argument after a `:base_url` argument of any call, such as
  #   `Keyword.put(opts, :base_url, value)`, its piped form, or the default of
  #   `Keyword.get(config, :base_url, default)`;
  # - the leftmost part of a `url` pair's value that `<>` or string interpolation builds, such as
  #   `url: base_url() <> path` or `url: "#{base}/path"`.
  #
  # A checked value passes when it is a string literal, `nil`, a module attribute, a
  # `HTTPPolicy.without_fragment/1` call (`Cinder.HTTPPolicy` spelled out too, or piped into), or a
  # call to a function of the same file whose every clause returns such a value. A `:base_url`
  # argument in last place is a read, such as `Keyword.get(config, :base_url)`,
  # `config[:base_url]` or `cfg(:base_url)`, and one in a tuple literal names a key, such as a
  # setting's `{Prowlarr, :base_url}` target. One before another argument must belong to `put`,
  # `put_new` or `get`; any other call, such as `Keyword.update/4`, fails whole, so a new way to set
  # a base URL needs a rule here first.
  #
  # Forms the walk does not follow include, and passes unchecked: a URL joined onto a path before
  # it reaches a sink, through a variable or a function's argument (LibreTranslate's
  # `translate_all/3` gets its `url` so); a URL that `URI.merge/2`, `URI.append_path/2` or
  # `Path.join/2` builds; a `url` value that is a plain variable or call, which Req sends whole
  # and without its fragment; a `:base_url` inside a list argument, such as
  # `Keyword.take(config, [:base_url])` piped into `Req.new/1`. Two safe forms fail, since the walk
  # cannot read them:
  # `HTTPPolicy.without_fragment/1` under another alias, and a function of another module that
  # returns the URL.
  use ExUnit.Case, async: true

  @http_policy [[:HTTPPolicy], [:Cinder, :HTTPPolicy], [:"Elixir", :Cinder, :HTTPPolicy]]
  # The calls whose argument after `:base_url` is the value they set or default to.
  @value_calls [:put, :put_new, :get]

  test "every service base URL in lib/ reaches a request through HTTPPolicy.without_fragment/1" do
    scans =
      for path <- Path.wildcard("lib/**/*.ex"),
          do: {path, path |> File.read!() |> scan()}

    # A walk that matched no sink would pass the check below on nothing.
    assert Enum.sum_by(scans, fn {_path, scan} -> scan.sinks end) >= 20

    failures =
      for {path, scan} <- scans, {line, form} <- scan.failures, do: "#{path}:#{line}: #{form}"

    assert failures == [],
           "These service URLs can reach a request with their `#` part, which takes the " <>
             "request's path into the fragment:\n" <>
             Enum.join(failures, "\n") <>
             "\nPass the configured URL through HTTPPolicy.without_fragment/1 where the " <>
             "request reads it, as Cinder.Library.MediaServer.Jellyfin's req/1 does (#1414)."
  end

  test "the walk checks each sink form and passes each allowed value" do
    source = ~S'''
    defmodule M do
      alias Cinder.HTTPPolicy

      @default "http://default"

      def a(c), do: Req.new(base_url: HTTPPolicy.without_fragment(c[:url]))
      def b(c), do: [base_url: c |> Keyword.get(:url) |> HTTPPolicy.without_fragment()]
      def c(c), do: [base_url: Cinder.HTTPPolicy.without_fragment(c)]
      def d, do: [base_url: @default, other: "x"]
      def e, do: [base_url: "http://literal", url: nil]
      def f(c), do: Keyword.get(c, :base_url, @default)
      def g(c), do: [base_url: helper(c)]
      def h(c), do: [url: helper(c) <> "/path"]
      def i, do: %{url: @default <> "/a" <> "/b", other: [url: (@default <> "/a") <> "/b"]}
      def j(c), do: [url: "#{helper(c)}/path"]
      def k(c), do: {Prowlarr, :base_url} && {"url", :base_url, "URL"} && c[:base_url] && cfg(:base_url)
      def l(c), do: [url: c, base_url: nil]
      def m, do: [url: "/path"]

      defp helper(c) when is_list(c), do: HTTPPolicy.without_fragment(c[:base_url])
      defp helper(_c), do: @default
      def n(c), do: [base_url: block(c)]

      defp block(c) do
        url = c[:base_url]
        HTTPPolicy.without_fragment(url)
      end
    end
    '''

    assert scan(source) == %{sinks: 13, failures: []}
  end

  test "the walk fails each sink form whose value skips without_fragment/1" do
    source = ~S'''
    defmodule M do
      def a(c), do: Req.new(base_url: c[:url])
      def b(url), do: [base_url: url]
      def c(c), do: [{:base_url, Keyword.get(c, :url)}]
      def d(o, u), do: Keyword.put(o, :base_url, u)
      def e(o, u), do: o |> Keyword.put_new(:base_url, u)
      def f(c, d), do: Keyword.get(c, :base_url, d)
      def g(c), do: [url: base() <> "/x"]
      def h(c), do: [url: c[:base_url] <> "/x"]
      def i(c), do: %{url: "#{c}/path"}
      def j(c), do: Req.merge(Req.new(), url: mixed(c) <> "/x")

      def k(c),
        do: [
          base_url:
            Other.without_fragment(
              c
            )
        ]

      defp base, do: Application.get_env(:cinder, :url)
      defp mixed(:a), do: "http://a"
      defp mixed(c), do: c
      def l(c), do: [base_url: loop(c)]
      defp loop(c), do: loop(c)
      def m(c), do: [base_url: imported(c)]
      def n(c), do: [base_url: guarded(c)]
      defp guarded(c) when is_binary(c), do: c
      defp guarded(_c), do: "http://x"
    end
    '''

    assert scan(source) == %{
             sinks: 14,
             failures: [
               {2, "base_url: c[:url]"},
               {3, "base_url: url"},
               {4, "base_url: Keyword.get(c, :url)"},
               {5, "base_url: u"},
               {6, "base_url: u"},
               {7, "base_url: d"},
               {8, "url: base() <> \"/x\""},
               {9, "url: c[:base_url] <> \"/x\""},
               {10, "url: \"\#{c}/path\""},
               {11, "url: mixed(c) <> \"/x\""},
               {16, "base_url: Other.without_fragment(c)"},
               {24, "base_url: loop(c)"},
               {26, "base_url: imported(c)"},
               {27, "base_url: guarded(c)"}
             ]
           }
  end

  test "the walk skips a sink in a comment or a string, and fails a call it cannot read" do
    source = ~S'''
    defmodule M do
      # [base_url: url]
      @doc """
      Req.new(base_url: url)
      """
      def a(url), do: "base_url: #{url}" && :ok
      def b(o, f), do: Keyword.update(o, :base_url, "x", f)
      def c(o), do: Keyword.take(o, [:base_url]) && o == :base_url
    end
    '''

    assert scan(source) == %{
             sinks: 1,
             failures: [{7, "Keyword.update(o, :base_url, \"x\", f)"}]
           }
  end

  # Each form the header says the walk does not follow: `a` to `e` and `h` keep the fragment and
  # pass, and `f` and `g` cut it or may, and fail.
  test "the walk passes the forms it does not follow and fails an alias or module it cannot read" do
    source = ~S'''
    defmodule M do
      alias Cinder.HTTPPolicy, as: Policy

      def a(c), do: send_to(c[:url] <> "/translate")
      defp send_to(url), do: Req.new(url: url)
      def b(c), do: Req.new(url: URI.merge(c[:url], "/x"))
      def c(c), do: Req.new(url: URI.append_path(URI.parse(c[:url]), "/x"))
      def d(c), do: Req.new(url: Path.join(c[:url], "x"))
      def e(c), do: Req.new(url: c[:url])
      def f(c), do: Req.new(base_url: Policy.without_fragment(c[:url]))
      def g, do: Req.new(base_url: Other.url())
      def h(c), do: c |> Keyword.take([:base_url]) |> Req.new()
    end
    '''

    assert %{failures: failures} = scan(source)
    assert Enum.map(failures, &elem(&1, 0)) == [10, 11]
  end

  # The done-when of #1414: each sign-in client, its cut removed, fails the walk.
  test "the walk fails each sign-in client with its without_fragment/1 call removed" do
    for {path, cut, uncut} <- [
          {"lib/cinder/accounts/jellyfin_auth/http.ex",
           "base_url: HTTPPolicy.without_fragment(url)", "base_url: url"},
          {"lib/cinder/accounts/plex_auth/http.ex", "base_url: HTTPPolicy.without_fragment(url)",
           "base_url: url"}
        ] do
      source = File.read!(path)
      assert scan(source).failures == [], path

      mutant = String.replace(source, cut, uncut)
      assert mutant != source, path
      assert Enum.map(scan(mutant).failures, &elem(&1, 1)) == ["base_url: url"], path
    end
  end

  # The number of sinks in the parsed source and `{line, form}` for each one the rules do not pass.
  # A string's contents and a comment are not code.
  defp scan(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    functions = functions(ast)

    {_ast, acc} = Macro.prewalk(ast, %{sinks: 0, failures: []}, &visit(&1, &2, functions))
    %{acc | failures: acc.failures |> Enum.reverse() |> Enum.uniq()}
  end

  # A pair `{:base_url, value}`: a keyword entry, a map entry or a tuple literal.
  defp visit({:base_url, value} = node, acc, functions),
    do: {node, check(acc, value, "base_url: #{Macro.to_string(value)}", line(value), functions)}

  defp visit({:url, value} = node, acc, functions) do
    case leftmost(value) do
      {:ok, left} ->
        form = "url: #{Macro.to_string(value)}"
        {node, check(acc, left, form, line(value), functions)}

      :error ->
        {node, acc}
    end
  end

  # A call with a `:base_url` argument. In last place it is a read, and a tuple literal names a key,
  # such as a setting slot `{"url", :base_url, "URL"}`. Before another argument, the call must be
  # one of @value_calls, and that argument is the sink; any other call fails whole.
  defp visit({call, meta, args} = node, acc, functions) when is_list(args) do
    case Enum.find_index(args, &(&1 == :base_url)) do
      nil ->
        {node, acc}

      index when index == length(args) - 1 or call == :{} ->
        {node, acc}

      index ->
        line = Keyword.get(meta, :line)

        if call_name(call) in @value_calls do
          value = Enum.at(args, index + 1)
          {node, check(acc, value, "base_url: #{Macro.to_string(value)}", line, functions)}
        else
          acc = %{acc | sinks: acc.sinks + 1}
          {node, %{acc | failures: [{line, Macro.to_string(node)} | acc.failures]}}
        end
    end
  end

  defp visit(node, acc, _functions), do: {node, acc}

  defp call_name({:., _, [_module, name]}), do: name
  defp call_name(name), do: name

  defp check(acc, value, form, line, functions) do
    acc = %{acc | sinks: acc.sinks + 1}

    if allowed?(value, functions, MapSet.new()),
      do: acc,
      else: %{acc | failures: [{line, form} | acc.failures]}
  end

  defp allowed?(value, _functions, _seen) when is_binary(value) or is_nil(value), do: true
  defp allowed?({:@, _, [{name, _, nil}]}, _functions, _seen) when is_atom(name), do: true

  defp allowed?({{:., _, [{:__aliases__, _, module}, :without_fragment]}, _, [_url]}, _, _)
       when module in @http_policy,
       do: true

  defp allowed?(
         {:|>, _, [_url, {{:., _, [{:__aliases__, _, module}, :without_fragment]}, _, []}]},
         _,
         _
       )
       when module in @http_policy,
       do: true

  defp allowed?({name, _, args}, functions, seen) when is_atom(name) and is_list(args) do
    key = {name, length(args)}

    case Map.fetch(functions, key) do
      {:ok, bodies} ->
        not MapSet.member?(seen, key) and
          Enum.all?(bodies, &allowed?(&1, functions, MapSet.put(seen, key)))

      :error ->
        false
    end
  end

  defp allowed?(_value, _functions, _seen), do: false

  # The leftmost operand of a `<>` chain or the first part of an interpolated string, which holds
  # the URL a path is joined onto. Any other value is sent whole.
  defp leftmost({:<>, _, [left, _right]}), do: {:ok, leftmost_part(left)}

  defp leftmost({:<<>>, _, [first | _rest]}) when not is_binary(first),
    do: {:ok, interpolated(first)}

  defp leftmost(_value), do: :error

  defp leftmost_part({:<>, _, [left, _right]}), do: leftmost_part(left)
  defp leftmost_part(value), do: value

  defp interpolated({:"::", _, [{{:., _, [Kernel, :to_string]}, _, [value]}, _type]}), do: value
  defp interpolated(value), do: value

  # `{name, arity} => [last expression of each clause]` for each `def` and `defp` of the source.
  defp functions(ast) do
    {_ast, functions} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, [do: body]]} = node, functions when kind in [:def, :defp] ->
          case signature(head) do
            {:ok, key} -> {node, Map.update(functions, key, [last(body)], &(&1 ++ [last(body)]))}
            :error -> {node, functions}
          end

        node, functions ->
          {node, functions}
      end)

    functions
  end

  defp signature({:when, _, [head, _guard]}), do: signature(head)

  defp signature({name, _, params}) when is_atom(name),
    do: {:ok, {name, length(List.wrap(params))}}

  defp signature(_head), do: :error

  defp last({:__block__, _, [_ | _] = expressions}), do: List.last(expressions)
  defp last(expression), do: expression

  defp line({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line)
  defp line(_value), do: nil
end
