defmodule Cinder.Acquisition.Indexer.Cardigann.Template do
  @moduledoc ~S"""
  Evaluates the subset of Go templates that Cardigann definitions write, as Prowlarr's
  `CardigannBase.ApplyGoTemplateText` reads it (#1670, part of #1610).

  A template reads a variables map whose keys are the names as the template writes them, with
  the leading dot (`".Keywords"`, `".Config.sort"`, `".Result.title_default"`). A value is a
  binary, `nil` or a list of binaries. The evaluator itself sets `".True"` to `"True"`,
  `".False"` to `nil` and `".Today.Year"` to `now`'s year, over any value the map holds.

  Constructs:

  - `{{ re_replace .Var "pattern" "replacement" }}`: the value (`""` for `nil`) with every match
    replaced through `Cinder.Acquisition.Indexer.Cardigann.BoundedRegex`, .NET replacement
    syntax included;
  - `{{ join .Var "sep" }}`: a list joined;
  - `and`, `or`, `eq` and `ne`, each with two or more arguments written `.var`, `(.var)`,
    `"literal"` or a parenthesized call, inner calls first. `and` gives the first variable whose
    value is blank (`nil`, a list or only whitespace, as Prowlarr's `as string` reads it), else
    the last one; `or` the first non-blank one, else the last one; both ignore literals. `eq`
    gives `.True` when its first two arguments hold the same value, two `nil`s included, else
    `.False`; `ne` the reverse. `eq` and `ne` read a list as `nil`, so two different lists are
    equal. A call gives a variable, which `if` tests or `{{ }}` prints;
  - `{{ if .Var }}A{{ else }}B{{ end }}`: A for a non-blank binary or a non-empty list, else B.
    The `else` is required, as Prowlarr's pattern requires it, and a condition that is not a
    variable is an error tag;
  - `{{ range .Var }}...{{.}}...{{ end }}` over a list, with the optional
    `{{ range $i, $e := .Var }}` form, where `{{$i}}` gives the element's index;
  - `{{ .Var }}`: the value, `""` for `nil`. A list is `{:error, {:template, :not_text}}`.

  Prowlarr runs one regex pass per construct over the growing string, so a value one pass
  inserts can be read as template text by a later pass. This evaluator parses the template once
  and never reads a substituted value as template text: a keyword holding
  `{{ .Config.apikey }}` comes out as those characters (the issue's choice, since queries and
  definitions are untrusted). It also evaluates only the branch an `if` keeps, where Prowlarr
  runs `re_replace`, `join` and the logic functions in both.

  The `:modifier` option applies to each substituted value (a `re_replace` or `join` result, a
  `range` element, a variable or a call's variable) and never to the template's own text, as
  Prowlarr's does: #1671 passes URL encoding through it. A `{{$i}}` index is digits and passes
  through unchanged.

  One evaluation's output may not pass `output_cap/0` bytes, or `:max_bytes` when lower; past
  it the result is `{:error, :filter_output_cap}`. The output counts after the modifier, and a
  `join` or `re_replace` result also counts before it, so one whose unmodified text passes the
  budget fails even when the modifier would shrink it. Each error is a closed tag: template
  errors name a construct, cap and regex errors name none, and no error holds a value, a
  pattern or a variable's name.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.BoundedRegex

  # Measured on #1670: the largest field value on one hand-fetched Nyaa.si search page is a
  # 515-byte magnet link (64 bytes on a Torrent9 one). 64 KiB is about 127 times that.
  @output_cap 65_536
  @logic %{"and" => :and, "or" => :or, "eq" => :eq, "ne" => :ne}

  @type value :: String.t() | nil | [String.t()]
  @type variables :: %{optional(String.t()) => value()}
  @type error ::
          :filter_output_cap
          | {:template, atom()}
          | {:unknown_variable, atom()}
          | BoundedRegex.error()

  @doc "The byte cap on one template's output and on one filter chain's outputs."
  @spec output_cap() :: pos_integer()
  def output_cap, do: @output_cap

  @doc """
  Evaluates `template` against `variables`. Options: `:modifier`, a function applied to each
  substituted value, and `:max_bytes`, a byte budget below `output_cap/0`.
  """
  @spec render(String.t(), variables(), DateTime.t(), keyword()) ::
          {:ok, String.t()} | {:error, error()}
  def render(template, variables, now, opts \\ [])

  def render(template, variables, %DateTime{} = now, opts)
      when is_binary(template) and is_map(variables) and is_list(opts) do
    env = %{
      vars:
        Map.merge(variables, %{
          ".True" => "True",
          ".False" => nil,
          ".Today.Year" => Integer.to_string(now.year)
        }),
      modifier: Keyword.get(opts, :modifier, & &1),
      max: min(Keyword.get(opts, :max_bytes, @output_cap), @output_cap),
      dot: nil
    }

    with {:ok, tokens} <- tokenize(template, []),
         {:ok, nodes} <- parse(tokens),
         {:ok, {acc, _size}} <- eval(nodes, env, {[], 0}) do
      {:ok, IO.iodata_to_binary(acc)}
    end
  end

  def render(_template, _variables, _now, _opts), do: {:error, {:template, :invalid_input}}

  ## Tokens: text and the content of each `{{ }}`.

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(text, acc) do
    case :binary.split(text, "{{") do
      [rest] ->
        tokenize("", [{:text, rest} | acc])

      [before, after_open] ->
        with {:ok, content, rest} <- action(after_open, "") do
          tokenize(rest, [{:action, String.trim(content)}, {:text, before} | acc])
        end
    end
  end

  # An action ends at the first `}}` outside a quoted string.
  defp action("}}" <> rest, acc), do: {:ok, acc, rest}

  defp action(<<?", rest::binary>>, acc) do
    case :binary.split(rest, "\"") do
      [quoted, after_quote] -> action(after_quote, acc <> "\"" <> quoted <> "\"")
      [_unclosed] -> {:error, {:template, :unclosed_action}}
    end
  end

  defp action(<<c, rest::binary>>, acc), do: action(rest, acc <> <<c>>)
  defp action("", _acc), do: {:error, {:template, :unclosed_action}}

  ## Parse: a tree of nodes.

  defp parse(tokens) do
    case nodes(tokens, []) do
      {:ok, nodes, []} -> {:ok, nodes}
      {:ok, _nodes, [{:action, "else"} | _]} -> {:error, {:template, :unexpected_else}}
      {:ok, _nodes, [{:action, "end"} | _]} -> {:error, {:template, :unexpected_end}}
      {:error, _} = error -> error
    end
  end

  # Reads nodes until the input ends or an `else` or `end` closes the enclosing block.
  defp nodes([], acc), do: {:ok, Enum.reverse(acc), []}

  defp nodes([{:action, stop} | _] = rest, acc) when stop in ["else", "end"],
    do: {:ok, Enum.reverse(acc), rest}

  defp nodes([{:text, text} | rest], acc), do: nodes(rest, [{:text, text} | acc])

  defp nodes([{:action, content} | rest], acc) do
    with {:ok, node} <- classify(content),
         {:ok, node, rest} <- block(node, rest) do
      nodes(rest, [node | acc])
    end
  end

  defp block({:if, condition}, tokens) do
    with {:ok, then_nodes, [{:action, "else"} | rest]} <- nodes(tokens, []),
         {:ok, else_nodes, [{:action, "end"} | rest]} <- nodes(rest, []) do
      {:ok, {:if, condition, then_nodes, else_nodes}, rest}
    else
      {:ok, _nodes, [{:action, "end"} | _]} -> {:error, {:template, :if_without_else}}
      {:ok, _nodes, [{:action, "else"} | _]} -> {:error, {:template, :unexpected_else}}
      {:ok, _nodes, []} -> {:error, {:template, :unclosed_block}}
      {:error, _} = error -> error
    end
  end

  defp block({:range, var, index}, tokens) do
    case nodes(tokens, []) do
      {:ok, body, [{:action, "end"} | rest]} -> {:ok, {:range, var, index, body}, rest}
      {:ok, _body, [{:action, "else"} | _]} -> {:error, {:template, :unexpected_else}}
      {:ok, _body, []} -> {:error, {:template, :unclosed_block}}
      {:error, _} = error -> error
    end
  end

  defp block(node, tokens), do: {:ok, node, tokens}

  defp classify("."), do: {:ok, :dot}
  defp classify("if"), do: {:error, {:template, :if_condition}}

  defp classify("if" <> <<c, rest::binary>>) when c in ~c" \t\n" do
    case expression(rest) do
      {:ok, {:lit, _}} -> {:error, {:template, :if_condition}}
      {:ok, condition} -> {:ok, {:if, condition}}
      {:error, {:template, :unsupported_action}} -> {:error, {:template, :if_condition}}
      {:error, _} = error -> error
    end
  end

  defp classify("range" <> <<c, rest::binary>>) when c in ~c" \t\n" do
    case words(rest) do
      [{:word, "." <> _ = var}] ->
        {:ok, {:range, var, nil}}

      [{:word, "$" <> index}, {:word, "$" <> _}, {:word, ":="}, {:word, "." <> _ = var}] ->
        range_index(index, var)

      _other ->
        {:error, {:template, :unsupported_action}}
    end
  end

  defp classify("re_replace" <> <<c, rest::binary>>) when c in ~c" \t\n" do
    case words(rest) do
      [{:word, "." <> _ = var}, {:lit, pattern}, {:lit, replacement}] ->
        {:ok, {:re_replace, var, pattern, replacement}}

      _other ->
        {:error, {:template, :unsupported_action}}
    end
  end

  defp classify("join" <> <<c, rest::binary>>) when c in ~c" \t\n" do
    case words(rest) do
      [{:word, "." <> _ = var}, {:lit, separator}] -> {:ok, {:join, var, separator}}
      _other -> {:error, {:template, :unsupported_action}}
    end
  end

  defp classify("$" <> _ = ref), do: {:ok, {:index, ref}}

  defp classify(content) do
    case expression(content) do
      {:ok, {:lit, _}} -> {:error, {:template, :unsupported_action}}
      other -> other
    end
  end

  defp range_index(index, var) do
    if String.ends_with?(index, ","),
      do: {:ok, {:range, var, "$" <> String.trim_trailing(index, ",")}},
      else: {:error, {:template, :unsupported_action}}
  end

  # The words of an action: `(`, `)`, quoted literals and runs of other non-space characters.
  defp words(text), do: words(text, [])
  defp words("", acc), do: Enum.reverse(acc)
  defp words(<<c, rest::binary>>, acc) when c in ~c" \t\n\r", do: words(rest, acc)
  defp words("(" <> rest, acc), do: words(rest, [:open | acc])
  defp words(")" <> rest, acc), do: words(rest, [:close | acc])

  defp words(<<?", rest::binary>>, acc) do
    [literal, rest] = :binary.split(rest, "\"")
    words(rest, [{:lit, literal} | acc])
  end

  defp words(text, acc) do
    {word, rest} = take_word(text, "")
    words(rest, [{:word, word} | acc])
  end

  defp take_word(<<c, _::binary>> = rest, acc) when c in ~c" \t\n\r()\"", do: {acc, rest}
  defp take_word(<<c, rest::binary>>, acc), do: take_word(rest, acc <> <<c>>)
  defp take_word("", acc), do: {acc, ""}

  # An expression: a variable, a literal or a call, in any parentheses.
  defp expression(text) do
    case operand(words(text)) do
      {:ok, node, []} -> {:ok, node}
      {:ok, _node, _left} -> {:error, {:template, :unsupported_action}}
      {:error, _} = error -> error
    end
  end

  defp operand([{:word, name} | rest]) when is_map_key(@logic, name), do: call(name, rest, [])
  defp operand([{:word, "." <> _ = var} | rest]), do: {:ok, {:var, var}, rest}
  defp operand([{:lit, literal} | rest]), do: {:ok, {:lit, literal}, rest}

  defp operand([:open | rest]) do
    case operand(rest) do
      {:ok, node, [:close | rest]} -> {:ok, node, rest}
      {:ok, _node, _unclosed} -> {:error, {:template, :unsupported_action}}
      {:error, _} = error -> error
    end
  end

  defp operand(_words), do: {:error, {:template, :unsupported_action}}

  # A call's arguments run to the end of the action or of its parentheses.
  defp call(name, [], args), do: call_node(name, args, [])
  defp call(name, [:close | _] = rest, args), do: call_node(name, args, rest)

  defp call(_name, [{:word, inner} | _], _args) when is_map_key(@logic, inner),
    do: {:error, {:template, :logic_arguments}}

  defp call(name, words, args) do
    with {:ok, arg, rest} <- operand(words), do: call(name, rest, [arg | args])
  end

  defp call_node(name, args, rest) when length(args) >= 2,
    do: {:ok, {:call, name, Enum.reverse(args)}, rest}

  defp call_node(_name, _args, _rest), do: {:error, {:template, :logic_arguments}}

  ## Evaluation.

  defp eval(nodes, env, out), do: each(nodes, out, &node(&1, env, &2))

  # Runs `fun` on each item with the output so far, stopping at the first error.
  defp each(items, out, fun) do
    Enum.reduce_while(items, {:ok, out}, fn item, {:ok, out} -> halt_on_error(fun.(item, out)) end)
  end

  defp halt_on_error({:ok, _out} = ok), do: {:cont, ok}
  defp halt_on_error({:error, _} = error), do: {:halt, error}

  defp node({:text, text}, env, out), do: emit(text, out, env)

  defp node({:var, var}, env, out) do
    with {:ok, value} <- fetch(env, var, :variable),
         {:ok, text} <- text(value),
         do: emit_value(text, env, out)
  end

  defp node({:call, _name, _args} = call, env, out) do
    with {:ok, var} <- reduce_call(call, env), do: node({:var, var}, env, out)
  end

  defp node({:if, condition, then_nodes, else_nodes}, env, out) do
    with {:ok, var} <- condition_var(condition, env),
         {:ok, value} <- fetch(env, var, :if) do
      eval(if(true?(value), do: then_nodes, else: else_nodes), env, out)
    end
  end

  defp node({:re_replace, var, pattern, replacement}, env, out) do
    with {:ok, value} <- fetch(env, var, :re_replace),
         {:ok, subject} <- text(value),
         {:ok, replaced} <-
           BoundedRegex.replace(pattern, subject, replacement, env.max - elem(out, 1)),
         do: emit_value(replaced, env, out)
  end

  defp node({:join, var, separator}, env, out) do
    with {:ok, value} <- fetch(env, var, :join),
         {:ok, list} <- list(value),
         :ok <- fits(list, separator, env, out),
         do: emit_value(Enum.join(list, separator), env, out)
  end

  defp node({:range, var, index, body}, env, out) do
    with {:ok, value} <- fetch(env, var, :range), {:ok, list} <- list(value) do
      list
      |> Enum.with_index()
      |> each(out, fn {element, position}, out ->
        dot = %{element: env.modifier.(element), index: index, position: position}
        eval(body, %{env | dot: dot}, out)
      end)
    end
  end

  defp node(:dot, %{dot: %{element: element}} = env, out), do: emit(element, out, env)

  defp node({:index, ref}, %{dot: %{index: ref, position: n}} = env, out),
    do: emit(Integer.to_string(n), out, env)

  defp node(_outside_range, _env, _out), do: {:error, {:template, :unsupported_action}}

  defp condition_var({:var, var}, _env), do: {:ok, var}
  defp condition_var({:call, _, _} = call, env), do: reduce_call(call, env)
  defp condition_var(_literal, _env), do: {:error, {:template, :if_condition}}

  # A call reduces to the name of a variable, as Prowlarr writes the name back into the text.
  defp reduce_call({:call, name, args}, env) do
    with {:ok, args} <- reduce_args(args, env), do: apply_logic(name, args, env)
  end

  defp reduce_args(args, env) do
    Enum.reduce_while(args, {:ok, []}, fn
      {:call, _, _} = call, {:ok, acc} ->
        case reduce_call(call, env) do
          {:ok, var} -> {:cont, {:ok, [{:var, var} | acc]}}
          {:error, _} = error -> {:halt, error}
        end

      arg, {:ok, acc} ->
        {:cont, {:ok, [arg | acc]}}
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  defp apply_logic(name, args, env) when name in ["and", "or"] do
    case for({:var, var} <- args, do: var) do
      [] -> {:error, {:template, :logic_arguments}}
      vars -> pick(vars, name == "and", env, @logic[name])
    end
  end

  defp apply_logic(name, [first, second | _], env) do
    construct = @logic[name]

    with {:ok, a} <- compared(first, env, construct),
         {:ok, b} <- compared(second, env, construct) do
      {:ok, if(a == b == (name == "eq"), do: ".True", else: ".False")}
    end
  end

  # `and` stops at the first blank variable, `or` at the first non-blank one; each looks up only
  # the variables it reaches, as Prowlarr's loop does.
  defp pick([var | rest], stop_on_blank?, env, construct) do
    with {:ok, value} <- fetch(env, var, construct) do
      if rest == [] or blank?(value) == stop_on_blank?,
        do: {:ok, var},
        else: pick(rest, stop_on_blank?, env, construct)
    end
  end

  defp compared({:lit, literal}, _env, _construct), do: {:ok, literal}

  defp compared({:var, var}, env, construct) do
    with {:ok, value} <- fetch(env, var, construct), do: {:ok, if(is_binary(value), do: value)}
  end

  defp fetch(%{vars: vars}, var, construct) do
    case Map.fetch(vars, var) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unknown_variable, construct}}
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_nil_or_list), do: true

  defp true?(value) when is_list(value), do: value != []
  defp true?(value), do: not blank?(value)

  defp text(nil), do: {:ok, ""}
  defp text(value) when is_binary(value), do: {:ok, value}
  defp text(_list), do: {:error, {:template, :not_text}}

  defp list(value) when is_list(value), do: {:ok, value}
  defp list(_value), do: {:error, {:template, :not_a_list}}

  # A join's length before it is built, so a long list never builds past the cap.
  defp fits(list, separator, env, {_acc, size}) do
    length = Enum.sum_by(list, &byte_size/1) + max(length(list) - 1, 0) * byte_size(separator)
    if size + length > env.max, do: {:error, :filter_output_cap}, else: :ok
  end

  defp emit_value(value, env, out), do: emit(env.modifier.(value), out, env)

  defp emit(text, {acc, size}, env) do
    size = size + byte_size(text)

    if size > env.max,
      do: {:error, :filter_output_cap},
      else: {:ok, {[acc | text], size}}
  end
end
