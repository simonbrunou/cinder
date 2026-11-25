defmodule Cinder.Indexers.Selector do
  @moduledoc ~S"""
  The structural gate a Cardigann CSS selector passes in the calling VM before
  `Cinder.Indexers.ParserWorker` hands it to lexbor in its own OS process (#1665, threat model
  "CSS selectors and `lazy_html`" on #1615). Pure: no process, no `LazyHTML`.

  `compile/2` refuses:

  - `:structure`, before anything else: a selector over `max_bytes/0` bytes, one that is not
    UTF-8 or holds a NUL byte;
  - `:template`: the selector holds `{{`, a Cardigann template, which this engine cannot expand
    yet (#1670);
  - `:structure`: parentheses outside quoted strings nested deeper than `max_depth/0`;
  - then, on one read from the left, whichever of these comes first: `:escape`, a backslash
    outside a quoted string; `:comment`, `/*` outside a quoted string; `:structure`, a quote or
    a parenthesis that never closes, a
    line break inside a quoted string, a `)` with no `(`, an empty item in a `:has()`, `:is()`
    or `:where()` argument, a relative item (one that starts with `>`, `+` or `~`) in `:is()` or
    `:where()`, or a `:contains()` argument that is neither one quoted string nor unquoted text
    without quotes.

  The gate is an early check only. lazy_html ends the VM with a segmentation fault on a parse
  error inside `:has()`, `:is()` or `:where()`, and raises on a parse error elsewhere (#1615 on
  0.1.15; `mix.lock` holds 0.1.13, which `parser_worker_test.exs` crashes the same way). So a
  selector that passes comes back split into parts that hold none of those three pseudo-classes:
  the skeleton, where each outermost one becomes a placeholder attribute, and each item of each
  argument, split on its top-level commas and checked the same way. A relative item in `:has()`
  runs as `* <item>`. The worker runs every part alone, then the whole, so lexbor meets a parse
  error in a part that cannot crash it. Through `ParserWorker.check_selectors/2`, the 2,793
  distinct selector strings of Prowlarr/Indexers v11 crashed no worker. The 2,272 that lazy_html
  0.1.15 queries as they stand all pass. Of the 39 that end its VM, 38 pass and 1 is `:escape`.
  Of the 482 it raises on, 463 pass, 17 are refused by lexbor and 2 are `:escape`. Most of those
  that now pass hold a `:contains()`, which the worker no longer hands lexbor.

  Every `:contains(text)` (any letter case) becomes the attribute `[cinder-<token>-c<n>]`, the
  same `n` for the same text, and its text joins `needles` at index `n`. The worker gives that
  attribute to every element whose text content holds the needle, as AngleSharp's `:contains`
  matches (`TextContainsMatcher`: the element's whole descendant text, compared ordinal and
  case-sensitive), so lexbor never parses `:contains`. The `token` is the worker's own random
  token, so a page cannot carry the attribute beforehand.
  """

  @type compiled :: %{parts: [String.t()], whole: String.t(), needles: [String.t()]}
  @type refusal :: :template | :escape | :comment | :structure

  @functional ["has(", "is(", "where("]

  # 6 times the longest of the 8,499 selectors in Prowlarr/Indexers v11 (669 bytes), and more than
  # twice the deepest nesting there (3).
  @max_bytes 4096
  @max_depth 8

  @doc """
  Checks `selector` and rewrites its `:contains()` for the worker whose marker token is `token`
  (lowercase letters, digits and hyphens). See the moduledoc for each refusal and for the parts.
  """
  @spec compile(String.t(), String.t()) :: {:ok, compiled()} | {:error, refusal()}
  def compile(selector, token) when is_binary(selector) and is_binary(token) do
    cond do
      byte_size(selector) > @max_bytes -> {:error, :structure}
      not String.valid?(selector) or String.contains?(selector, <<0>>) -> {:error, :structure}
      String.contains?(selector, "{{") -> {:error, :template}
      true -> do_compile(selector, token)
    end
  end

  @doc "The longest selector `compile/2` reads, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The deepest parenthesis nesting `compile/2` reads."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  defp do_compile(selector, token) do
    check_depth(selector, 0)
    {segments, needles} = parse(selector, %{token: token, needles: []})
    whole = render(segments, token, :whole)

    {:ok,
     %{
       parts: parts(segments, token),
       whole: whole,
       needles: Enum.reverse(needles.needles)
     }}
  catch
    :throw, {__MODULE__, reason} -> {:error, reason}
  end

  # One pass over the text before the parse, whose nested arguments read their text again at
  # each level: the depth cap keeps that at most `@max_depth` reads of `@max_bytes` bytes. A
  # quote, an escape or a comment the parse refuses is skipped here.
  defp check_depth("", _depth), do: :ok
  defp check_depth(<<"(", _rest::binary>>, @max_depth), do: refuse(:structure)
  defp check_depth(<<"(", rest::binary>>, depth), do: check_depth(rest, depth + 1)
  defp check_depth(<<")", rest::binary>>, depth), do: check_depth(rest, max(depth - 1, 0))

  defp check_depth(<<quote, rest::binary>>, depth) when quote in [?", ?'] do
    case :binary.match(rest, <<quote>>) do
      {at, 1} -> check_depth(binary_part(rest, at + 1, byte_size(rest) - at - 1), depth)
      :nomatch -> :ok
    end
  end

  defp check_depth(<<_byte, rest::binary>>, depth), do: check_depth(rest, depth)

  ## Parsing into segments

  # A segment is `{:text, binary}`, `{:contains, n}`, `{:paren, segments}` for any other
  # parenthesis, or `{:fun, name, [item]}` for `:has(`, `:is(` or `:where(`, where each item is
  # `{segments, relative?}` and a relative item's segments start with `{:text, "* "}`.
  defp parse(text, state), do: parse(text, [], state)

  defp parse("", acc, state), do: {Enum.reverse(acc), state}

  defp parse(<<"\\", _rest::binary>>, _acc, _state), do: refuse(:escape)
  defp parse(<<"/*", _rest::binary>>, _acc, _state), do: refuse(:comment)

  defp parse(<<quote, rest::binary>>, acc, state) when quote in [?", ?'] do
    {string, rest} = take_string(rest, quote, <<quote>>)
    parse(rest, push_text(acc, string), state)
  end

  defp parse(<<":", rest::binary>>, acc, state) do
    case functional(rest) do
      {:contains, after_open} ->
        {argument, rest} = take_argument(after_open)
        {n, state} = needle_index(needle(argument), state)
        parse(rest, [{:contains, n} | acc], state)

      {name, after_open} when name in @functional ->
        {argument, rest} = take_argument(after_open)
        {items, state} = parse_items(name, argument, state)
        parse(rest, [{:fun, name, items} | acc], state)

      :none ->
        parse(rest, push_text(acc, ":"), state)
    end
  end

  defp parse(<<"(", rest::binary>>, acc, state) do
    {argument, rest} = take_argument(rest)
    {inner, state} = parse(argument, state)
    parse(rest, [{:paren, inner} | acc], state)
  end

  defp parse(<<")", _rest::binary>>, _acc, _state), do: refuse(:structure)

  defp parse(<<char::utf8, rest::binary>>, acc, state),
    do: parse(rest, push_text(acc, <<char::utf8>>), state)

  defp push_text([{:text, text} | acc], more), do: [{:text, text <> more} | acc]
  defp push_text(acc, more), do: [{:text, more} | acc]

  defp functional(rest) do
    lower = rest |> binary_part(0, min(9, byte_size(rest))) |> String.downcase()

    cond do
      String.starts_with?(lower, "contains(") ->
        {:contains, binary_part(rest, 9, byte_size(rest) - 9)}

      name = Enum.find(@functional, &String.starts_with?(lower, &1)) ->
        {name, binary_part(rest, byte_size(name), byte_size(rest) - byte_size(name))}

      true ->
        :none
    end
  end

  # A quoted string, its closing quote included. A backslash inside it escapes the next character.
  defp take_string("", _quote, _acc), do: refuse(:structure)
  defp take_string(<<quote, rest::binary>>, quote, acc), do: {<<acc::binary, quote>>, rest}

  # CSS ends a string at an unescaped line break where this reader would go on, so the gate
  # would split a selector otherwise than lexbor reads it.
  defp take_string(<<char, _rest::binary>>, _quote, _acc) when char in [?\n, ?\r, ?\f],
    do: refuse(:structure)

  defp take_string(<<"\\", char::utf8, rest::binary>>, quote, acc),
    do: take_string(rest, quote, <<acc::binary, "\\", char::utf8>>)

  defp take_string(<<char::utf8, rest::binary>>, quote, acc),
    do: take_string(rest, quote, <<acc::binary, char::utf8>>)

  defp take_string(<<_byte, _rest::binary>>, _quote, _acc), do: refuse(:structure)

  # The text up to the `)` that closes an opening already consumed, and the text after it.
  defp take_argument(text), do: take_argument(text, 1, "")

  defp take_argument("", _depth, _acc), do: refuse(:structure)
  defp take_argument(<<"\\", _rest::binary>>, _depth, _acc), do: refuse(:escape)
  defp take_argument(<<"/*", _rest::binary>>, _depth, _acc), do: refuse(:comment)

  defp take_argument(<<quote, rest::binary>>, depth, acc) when quote in [?", ?'] do
    {string, rest} = take_string(rest, quote, <<quote>>)
    take_argument(rest, depth, acc <> string)
  end

  defp take_argument(<<")", rest::binary>>, 1, acc), do: {acc, rest}

  defp take_argument(<<")", rest::binary>>, depth, acc),
    do: take_argument(rest, depth - 1, acc <> ")")

  defp take_argument(<<"(", rest::binary>>, depth, acc),
    do: take_argument(rest, depth + 1, acc <> "(")

  defp take_argument(<<char::utf8, rest::binary>>, depth, acc),
    do: take_argument(rest, depth, <<acc::binary, char::utf8>>)

  defp take_argument(<<_byte, _rest::binary>>, _depth, _acc), do: refuse(:structure)

  defp parse_items(name, argument, state) do
    argument
    |> split_commas()
    |> Enum.map_reduce(state, fn raw, state ->
      item = String.trim(raw)
      relative? = String.starts_with?(item, [">", "+", "~"])

      cond do
        item == "" -> refuse(:structure)
        relative? and name != "has(" -> refuse(:structure)
        true -> :ok
      end

      {segments, state} = parse(item, state)
      {{if(relative?, do: [{:text, "* "} | segments], else: segments), relative?}, state}
    end)
  end

  # Splits on the commas outside quotes and parentheses. The argument already passed
  # `take_argument/1`, so its quotes and parentheses close.
  defp split_commas(text), do: split_commas(text, 0, "", [])

  defp split_commas("", _depth, current, out), do: Enum.reverse([current | out])

  defp split_commas(<<quote, rest::binary>>, depth, current, out) when quote in [?", ?'] do
    {string, rest} = take_string(rest, quote, <<quote>>)
    split_commas(rest, depth, current <> string, out)
  end

  defp split_commas(<<",", rest::binary>>, 0, current, out),
    do: split_commas(rest, 0, "", [current | out])

  defp split_commas(<<"(", rest::binary>>, depth, current, out),
    do: split_commas(rest, depth + 1, current <> "(", out)

  defp split_commas(<<")", rest::binary>>, depth, current, out),
    do: split_commas(rest, depth - 1, current <> ")", out)

  defp split_commas(<<char::utf8, rest::binary>>, depth, current, out),
    do: split_commas(rest, depth, <<current::binary, char::utf8>>, out)

  ## :contains

  defp needle(argument) do
    case String.trim(argument) do
      <<quote, rest::binary>> when quote in [?", ?'] -> quoted_needle(rest, quote)
      text -> if String.contains?(text, ["\"", "'"]), do: refuse(:structure), else: text
    end
  end

  # The argument after its opening quote: one string, and nothing after it.
  defp quoted_needle(rest, quote) do
    case take_string(rest, quote, <<quote>>) do
      {string, ""} -> unescape(binary_part(string, 1, byte_size(string) - 2))
      {_string, _more} -> refuse(:structure)
    end
  end

  # CSS string escapes: `\` and 1 to 6 hex digits (one whitespace after them dropped) is that
  # code point; `\` and any other character is that character.
  defp unescape(text), do: unescape(text, "")

  defp unescape("", acc), do: acc

  defp unescape(<<"\\", rest::binary>>, acc) do
    case Regex.run(~r/\A([0-9a-fA-F]{1,6})[ \t\n]?/, rest) do
      [whole, hex] ->
        point = String.to_integer(hex, 16)
        char = if point in 1..0x10FFFF and point not in 0xD800..0xDFFF, do: point, else: 0xFFFD

        unescape(
          binary_part(rest, byte_size(whole), byte_size(rest) - byte_size(whole)),
          <<acc::binary, char::utf8>>
        )

      nil ->
        <<char::utf8, rest::binary>> = rest
        unescape(rest, <<acc::binary, char::utf8>>)
    end
  end

  defp unescape(<<char::utf8, rest::binary>>, acc),
    do: unescape(rest, <<acc::binary, char::utf8>>)

  defp needle_index(text, state) do
    case Enum.find_index(Enum.reverse(state.needles), &(&1 == text)) do
      nil -> {length(state.needles), %{state | needles: [text | state.needles]}}
      n -> {n, state}
    end
  end

  ## Rendering

  # `:whole` renders every segment as the worker runs the selector; `:skeleton` renders each
  # `:has()`, `:is()` and `:where()` as the placeholder attribute.
  defp render(segments, token, mode),
    do: segments |> Enum.map(&render_one(&1, token, mode)) |> IO.iodata_to_binary()

  defp render_one({:text, text}, _token, _mode), do: text
  defp render_one({:contains, n}, token, _mode), do: ["[", marker(token, n), "]"]
  defp render_one({:paren, inner}, token, mode), do: ["(", render(inner, token, mode), ")"]
  defp render_one({:fun, _name, _items}, token, :skeleton), do: ["[cinder-", token, "-f]"]

  defp render_one({:fun, name, items}, token, :whole) do
    rendered =
      Enum.map(items, fn {segments, relative?} ->
        render(own(segments, relative?), token, :whole)
      end)

    [":", name, Enum.intersperse(rendered, ", "), ")"]
  end

  # An item's segments as the argument holds it, without the `* ` its part runs with.
  defp own([{:text, "* "} | segments], true), do: segments
  defp own(segments, false), do: segments

  @doc "The marker attribute name for needle `n` of the worker whose token is `token`."
  @spec marker(String.t(), non_neg_integer()) :: String.t()
  def marker(token, n), do: "cinder-#{token}-c#{n}"

  # For a selector that holds a `:has()`, `:is()` or `:where()`: its skeleton, then the parts of
  # each item of each argument. An item without one is a part as it stands.
  defp parts(segments, token) do
    if Enum.any?(segments, &functional?/1) do
      [
        render(segments, token, :skeleton)
        | Enum.flat_map(nested_items(segments), &item_parts(&1, token))
      ]
    else
      []
    end
  end

  defp item_parts({segments, _relative?}, token) do
    if Enum.any?(segments, &functional?/1),
      do: parts(segments, token),
      else: [render(segments, token, :whole)]
  end

  defp nested_items(segments) do
    Enum.flat_map(segments, fn
      {:fun, _name, items} -> items
      {:paren, inner} -> nested_items(inner)
      _segment -> []
    end)
  end

  defp functional?({:fun, _name, _items}), do: true
  defp functional?({:paren, inner}), do: Enum.any?(inner, &functional?/1)
  defp functional?(_segment), do: false

  defp refuse(reason), do: throw({__MODULE__, reason})
end
