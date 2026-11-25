defmodule Cinder.Acquisition.Indexer.Cardigann.Filters do
  @moduledoc ~S"""
  The Cardigann field filters that Nyaa.si and Torrent9 use, and the `andmatch` row filter
  (#1670, part of #1610), as Prowlarr's `CardigannBase.ApplyFilters` and
  `IndexerBase.FilterReleasesByQuery` read them.

  A filter is the loader's record, `%{name: name, args: args}`, where `args` is `nil`, a string
  or a list of strings. A list runs in order, each step on the previous output:

  - `re_replace [pattern, replacement]`: the replacement evaluated as a template, then every
    match replaced, .NET replacement syntax included;
  - `regexp pattern`: the first match's group 1, empty text when nothing matches;
  - `replace [from, to]`: every literal occurrence, `to` evaluated as a template;
  - `split [sep, index]`: split on the first character of `sep`, a negative index counting from
    the end; an index outside the parts is `{:error, :split_index}`;
  - `append text`: the text evaluated as a template, appended;
  - `trim`: surrounding whitespace, or with an argument every copy of its first character at
    both ends;
  - `dateparse layout`: the text read by `Cinder.Acquisition.Indexer.Cardigann.DotnetDate` and
    written as its canonical text, or left unchanged when it does not parse, as Prowlarr's
    filter leaves it. A layout token outside the supported set is an error tag.

  Every pattern runs through `Cinder.Acquisition.Indexer.Cardigann.BoundedRegex`. Any other
  filter name is `{:error, {:not_supported, {:filter, name}}}`, and `supported/0` lists the
  names this slice runs, for a load check. A filter this slice runs, with arguments of the
  wrong shape, is `{:error, {:filter_args, name}}`, and anything that is not a filter record,
  a name that is not a string included, is `{:error, :filter_invalid}`.

  One chain has one byte budget, `Cinder.Acquisition.Indexer.Cardigann.Template.output_cap/0`:
  each step's output and each template a step evaluates count against it, and passing it ends
  the chain with `{:error, :filter_output_cap}`. A `re_replace` or a `replace` that would build
  past the budget stops before it builds; the other steps build their output and the chain then
  checks it. Every function is pure, and no error holds a value, a pattern or a replacement.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.BoundedRegex
  alias Cinder.Acquisition.Indexer.Cardigann.DotnetDate
  alias Cinder.Acquisition.Indexer.Cardigann.Template

  @supported ~w(append dateparse re_replace regexp replace split trim)
  @common_words ~w(and the an of)
  # .NET's `\w`: letters, non-spacing marks, decimal digits and connector punctuation. PCRE's
  # `\w` under `:ucp` also takes every other number, such as `³`.
  @non_word "[^\\p{L}\\p{Mn}\\p{Nd}\\p{Pc}]+"

  @type filter :: %{name: String.t(), args: nil | String.t() | [String.t()]}

  @doc "The filter names `apply/4` runs."
  @spec supported() :: [String.t()]
  def supported, do: @supported

  @doc "Runs `filters` in order on `input`, under one byte budget."
  @spec apply(String.t(), [filter()], Template.variables(), DateTime.t()) ::
          {:ok, String.t()} | {:error, term()}
  def apply(input, filters, variables, %DateTime{} = now)
      when is_binary(input) and is_list(filters) and is_map(variables) do
    cap = Template.output_cap()
    env = %{vars: variables, now: now}

    Enum.reduce_while(filters, {:ok, input, 0}, fn filter, {:ok, data, spent} ->
      case step(filter, data, env, cap - spent) do
        {:ok, out, template_bytes} -> account(out, spent + template_bytes + byte_size(out), cap)
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, data, _spent} -> {:ok, data}
      {:error, _} = error -> error
    end
  end

  def apply(_input, _filters, _variables, _now), do: {:error, :filter_invalid}

  defp account(_out, spent, cap) when spent > cap, do: {:halt, {:error, :filter_output_cap}}
  defp account(out, spent, _cap), do: {:cont, {:ok, out, spent}}

  # Each step answers its output and the bytes of the templates it evaluated.
  defp step(%{name: "re_replace", args: [pattern, replacement]}, data, env, left)
       when is_binary(pattern) and is_binary(replacement) do
    with {:ok, rendered} <- template(replacement, env, left),
         left = left - byte_size(rendered),
         {:ok, out} <- BoundedRegex.replace(pattern, data, rendered, max(left, 0)) do
      {:ok, out, byte_size(rendered)}
    end
  end

  defp step(%{name: "regexp", args: pattern}, data, _env, _left) when is_binary(pattern) do
    with {:ok, out} <- BoundedRegex.first_group(pattern, data), do: {:ok, out, 0}
  end

  defp step(%{name: "replace", args: [from, to]}, data, env, left)
       when is_binary(from) and from != "" and is_binary(to) do
    with {:ok, rendered} <- template(to, env, left) do
      count = length(:binary.matches(data, from))
      size = byte_size(data) + count * (byte_size(rendered) - byte_size(from))

      if size + byte_size(rendered) > left,
        do: {:error, :filter_output_cap},
        else: {:ok, String.replace(data, from, rendered), byte_size(rendered)}
    end
  end

  defp step(%{name: "split", args: [<<sep::utf8, _::binary>>, index]}, data, _env, _left)
       when is_binary(index) do
    parts = String.split(data, <<sep::utf8>>)

    case Integer.parse(index) do
      {n, ""} -> pick(parts, if(n < 0, do: n + length(parts), else: n))
      _not_an_integer -> {:error, {:filter_args, "split"}}
    end
  end

  defp step(%{name: "append", args: text}, data, env, left) when is_binary(text) do
    with {:ok, rendered} <- template(text, env, left),
         do: {:ok, data <> rendered, byte_size(rendered)}
  end

  defp step(%{name: "trim", args: nil}, data, _env, _left),
    do: {:ok, String.trim(data), 0}

  defp step(%{name: "trim", args: <<char::utf8, _::binary>>}, data, _env, _left),
    do: {:ok, String.trim(data, <<char::utf8>>), 0}

  defp step(%{name: "dateparse", args: layout}, data, env, _left) when is_binary(layout) do
    case DotnetDate.parse(data, layout, env.now) do
      {:ok, time} -> {:ok, DotnetDate.canonical(time), 0}
      {:error, :invalid_date} -> {:ok, data, 0}
      {:error, _} = error -> error
    end
  end

  defp step(%{name: name}, _data, _env, _left) when name in @supported,
    do: {:error, {:filter_args, name}}

  defp step(%{name: name}, _data, _env, _left) when is_binary(name),
    do: {:error, {:not_supported, {:filter, name}}}

  defp step(_not_a_filter, _data, _env, _left), do: {:error, :filter_invalid}

  defp template(text, env, left),
    do: Template.render(text, env.vars, env.now, max_bytes: max(left, 0))

  defp pick(parts, n) when n >= 0 and n < length(parts), do: {:ok, Enum.at(parts, n), 0}
  defp pick(_parts, _n), do: {:error, :split_index}

  @doc """
  The `andmatch` row filter: whether a row titled `title`, with `description` (or `nil`), answers
  `query`. The query splits on runs of non-word characters, and terms that are blank, one UTF-16
  unit long, or `and`, `the`, `an` or `of` in any case drop out. With two or more terms the row
  stays when at least two occur in the title or the description, ignoring case; with one term
  when it occurs; with none it goes. A query the split cannot read drops the row.
  """
  @spec andmatch?(String.t(), String.t() | nil, String.t() | nil) :: boolean()
  def andmatch?(query, title, description) when is_binary(query) do
    case BoundedRegex.split(@non_word, query) do
      {:ok, parts} -> keep?(Enum.filter(parts, &term?/1), title, description)
      {:error, _} -> false
    end
  end

  def andmatch?(_query, _title, _description), do: false

  defp term?(part) do
    String.trim(part) != "" and utf16_length(part) > 1 and
      String.downcase(part) not in @common_words
  end

  defp utf16_length(text),
    do: text |> String.to_charlist() |> Enum.sum_by(&if(&1 > 0xFFFF, do: 2, else: 1))

  defp keep?([], _title, _description), do: false

  defp keep?(terms, title, description) do
    haystacks = for text <- [title, description], is_binary(text), do: String.downcase(text)

    found =
      Enum.count(terms, fn term ->
        term = String.downcase(term)
        Enum.any?(haystacks, &String.contains?(&1, term))
      end)

    if length(terms) > 1, do: found >= 2, else: found >= 1
  end
end
