defmodule Cinder.Acquisition.Indexer.Cardigann.XmlSelector do
  @moduledoc ~S"""
  The gate a Cardigann selector on an XML search answer passes before Floki's selector engine
  reads it (#1678). Pure.

  Floki 0.38.5 reads a selector leniently: it drops tokens it does not know, and answers nested
  `:has()`, `:not(:has())` and `:empty` wrongly without raising (#1612). So `compile/2` hands it
  only a selector this strict grammar reads, which Floki answers as AngleSharp does:

  - a comma-separated list of selectors, each a chain of compound selectors joined by white
    space, `>`, `+` or `~`;
  - a compound selector: a type name or `*`, then any number of `#id`, `.class` and attribute
    selectors (`[name]`, or `[name<op>value]` with `=`, `~=`, `|=`, `^=`, `$=` or `*=` and a
    value that is a name or a quoted string), or those alone;
  - a name: ASCII letters, digits, `_` and `-`, starting with a letter, `_` or one `-` and a
    letter or `_`.

  `:contains(<text>)` goes first through `Cinder.Indexers.Selector.compile/2`, which turns it
  into a marker attribute and its text into a needle, as the HTML search reads it. Then:

  - any other pseudo-class is `{:error, {:xml_selector, name}}`, its name as written when it is
    1 to 32 ASCII letters or hyphens, so the load check reports "not supported: XML selector
    :has" for `:has`;
  - anything else the grammar does not read, and anything `Selector.compile/2` refuses (an
    escape, a comment, a quote that never closes, a template), is
    `{:error, {:xml_selector, :invalid}}`.
  """

  alias Cinder.Indexers.Selector

  @name ~r/\A-?[A-Za-z_][A-Za-z0-9_-]*/
  @pseudo ~r/\A([A-Za-z-]{1,32})(?![A-Za-z0-9_-])/
  @value ~r/\A(?:-?[A-Za-z_][A-Za-z0-9_-]*|"[^"]*"|'[^']*')/
  @operators ["~=", "|=", "^=", "$=", "*=", "="]

  @type code :: {:xml_selector, String.t() | :invalid}

  @doc """
  The selector Floki runs for `selector` and the needles of its markers, named with `token`, or
  the refusal; see the moduledoc.
  """
  @spec compile(String.t(), String.t()) ::
          {:ok, %{whole: String.t(), needles: [String.t()]}} | {:error, code()}
  def compile(selector, token) when is_binary(selector) and is_binary(token) do
    with {:ok, %{whole: whole, needles: needles}} <- gate(selector, token),
         :ok <- list(skip(whole)) do
      {:ok, %{whole: whole, needles: needles}}
    end
  end

  defp gate(selector, token) do
    case Selector.compile(selector, token) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, _refusal} -> {:error, {:xml_selector, :invalid}}
    end
  end

  defp list(text) do
    with {:ok, rest} <- complex(text) do
      case skip(rest) do
        "" -> :ok
        "," <> more -> list(skip(more))
        _other -> invalid()
      end
    end
  end

  defp complex(text) do
    with {:ok, rest} <- compound(text), do: after_compound(rest)
  end

  defp after_compound(text) do
    case skip(text) do
      <<combinator, more::binary>> when combinator in [?>, ?+, ?~] -> complex(skip(more))
      "" -> {:ok, text}
      "," <> _more -> {:ok, text}
      trimmed when trimmed != text -> complex(trimmed)
      _no_space -> {:ok, text}
    end
  end

  defp compound("*" <> rest), do: simples(rest, true)

  defp compound(text) do
    case take(@name, text) do
      {:ok, rest} -> simples(rest, true)
      :error -> simples(text, false)
    end
  end

  defp simples(<<prefix, rest::binary>>, _any?) when prefix in [?#, ?.] do
    with {:ok, rest} <- need(@name, rest), do: simples(rest, true)
  end

  defp simples("[" <> rest, _any?) do
    with {:ok, rest} <- attribute(skip(rest)), do: simples(rest, true)
  end

  defp simples(":" <> rest, _any?) do
    case Regex.run(@pseudo, rest, capture: :all_but_first) do
      [name] -> {:error, {:xml_selector, name}}
      nil -> invalid()
    end
  end

  defp simples(rest, true), do: {:ok, rest}
  defp simples(_rest, false), do: invalid()

  defp attribute(text) do
    with {:ok, rest} <- need(@name, text) do
      case skip(rest) do
        "]" <> rest -> {:ok, rest}
        rest -> operator(rest)
      end
    end
  end

  defp operator(text) do
    with op when is_binary(op) <- Enum.find(@operators, &String.starts_with?(text, &1)),
         rest = binary_part(text, byte_size(op), byte_size(text) - byte_size(op)),
         {:ok, rest} <- take(@value, skip(rest)),
         "]" <> rest <- skip(rest) do
      {:ok, rest}
    else
      _other -> invalid()
    end
  end

  defp take(pattern, text) do
    case Regex.run(pattern, text) do
      [match] -> {:ok, binary_part(text, byte_size(match), byte_size(text) - byte_size(match))}
      nil -> :error
    end
  end

  defp need(pattern, text) do
    case take(pattern, text) do
      {:ok, rest} -> {:ok, rest}
      :error -> invalid()
    end
  end

  # CSS white space.
  defp skip(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r, ?\f], do: skip(rest)
  defp skip(text), do: text

  defp invalid, do: {:error, {:xml_selector, :invalid}}
end
