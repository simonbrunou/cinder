defmodule Cinder.Acquisition.Indexer.Cardigann.JsonRows do
  @moduledoc ~S"""
  The rows of one Cardigann JSON search page (#1678), read as Prowlarr's `CardigannParser`
  reads a `response.type: json` page (`b0b5774`), as per-row field values in the shape
  `Cinder.Indexers.ParserWorker.run/3` gives for an HTML page: a field's text,
  `{:case, key}`, or nil. `Cinder.Acquisition.Indexer.Cardigann.Rows` then applies the same
  field and row rules to both. Paths and selector chains are
  `Cinder.Acquisition.Indexer.Cardigann.JsonPath`'s, a value's text
  `Cinder.Acquisition.Indexer.Cardigann.JsonText`'s. It runs in the search process.

  In order:

  1. `response.noResultsMessage`: a message that is not blank and that the body holds, or a
     blank message with a blank body, gives no rows;
  2. the body decodes with `Jason.decode/2`, objects in order; a body it refuses is
     `{:error, :invalid_json}`. A key an object holds twice keeps its last value, as Newtonsoft
     does. Jason is stricter than Newtonsoft, which also reads single quotes, unquoted names,
     trailing commas and comments: such a body is `:invalid_json` here. So is a body that nests
     more than 64 objects and arrays (`JsonPath.decode/1`), as `JToken.Parse` throws on it;
  3. `rows.count`: its `selector` read from the root as a field's is, trimmed, then its filters
     run in the definition's charset. When the text reads as a whole number below 1, as .NET's
     `int.TryParse` reads it, there are no rows. A count that does not read changes nothing, as
     does a count written with `text`, and a count's `case` is not read: no v11 definition
     writes either;
  4. the rows selector, rendered with the search variables: a template that does not render is
     `{:error, :definition_error}`, a rendering that is not a chain `JsonPath` reads
     `{:error, :definition_error}`, and a path that selects no array of objects no rows when
     `rows.missingAttributeEqualsNoResults` is true, else `{:error, :no_results_list}`;
  5. each row: `rows.attribute` replaces it with the value at that path, and a row without one
     is skipped (Prowlarr skips it only with `missingAttributeEqualsNoResults` and otherwise
     fails the page on a null reference); `rows.multiple` makes a row of each object value of
     an object, or each object item of an array; otherwise a row that is not an object is
     skipped. At most `Cinder.Acquisition.Indexer.Newznab.Items.max_rows/0` rows are read;
  6. each field with a `selector`: its leading dots trimmed, rendered with the search
     variables, and read through `JsonPath.field/2` from the row, or from the row before
     `rows.attribute` and `rows.multiple` narrowed it when the selector starts with `..`. An
     array reads its items' texts joined with `,`, any other value its `Value<string>()`, and
     a value that is missing, `null`, or that `Value<string>()` refuses is nil. A field with
     `case` and a value or a `null` gives `{:case, key}` for the first key equal to that text,
     or `*`; when none matches it keeps the text, as `HandleJsonSelector` does. A missing or
     refused value skips the `case` and stays nil, as `HandleJsonSelector` returns or throws
     before it.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.{Charset, Filters, JsonPath, JsonText, Template}
  alias Cinder.Acquisition.Indexer.Newznab.Items

  @type values :: [%{String.t() => String.t() | {:case, String.t()} | nil}]

  @doc """
  The field values of each row of `text`, a page already decoded in the definition's charset,
  for `definition` under `variables` at `now`, with the search path's `response`; see the
  moduledoc.
  """
  @spec values(String.t(), map(), Template.variables(), DateTime.t(), map()) ::
          {:ok, values()} | {:error, :invalid_json | :no_results_list | :definition_error}
  def values(text, definition, variables, now, response) do
    if no_results?(text, response),
      do: {:ok, []},
      else: decoded(text, definition, variables, now, Charset.of_definition(definition))
  end

  defp no_results?(_text, %{no_results_message: nil}), do: false

  defp no_results?(text, %{no_results_message: message}) do
    if String.trim(message) == "",
      do: String.trim(text) == "",
      else: String.contains?(text, message)
  end

  defp no_results?(_text, _response), do: false

  defp decoded(text, definition, variables, now, encoding) do
    case JsonPath.decode(text) do
      {:ok, root} -> read(root, definition, variables, now, encoding)
      :error -> {:error, :invalid_json}
    end
  end

  defp read(root, definition, variables, now, encoding) do
    rows = definition.search.rows

    if count_below_one?(root, rows.count, variables, now, encoding) do
      {:ok, []}
    else
      with {:ok, chain} <- rows_chain(rows.selector, variables, now),
           do: row_items(root, chain, definition, variables, now)
    end
  end

  defp row_items(root, chain, definition, variables, now) do
    case JsonPath.rows(root, chain) do
      {:ok, items} ->
        {:ok, field_values(items, definition, variables, now)}

      :error ->
        if definition.search.rows.missing_attribute_equals_no_results,
          do: {:ok, []},
          else: {:error, :no_results_list}
    end
  end

  defp count_below_one?(_root, nil, _variables, _now, _encoding), do: false

  defp count_below_one?(root, count, variables, now, encoding) do
    with {:ok, value} when is_binary(value) <-
           selected(count.selector, root, root, variables, now),
         {:ok, text} <-
           Filters.apply(String.trim(value), count.filters || [], variables, now,
             encoding: encoding
           ),
         {number, ""} when number in -2_147_483_648..2_147_483_647 <-
           Integer.parse(String.trim(text)) do
      number < 1
    else
      _no_count -> false
    end
  end

  defp rows_chain(selector, variables, now) do
    with {:ok, rendered} <- Template.render(selector || "", variables, now),
         {:ok, chain} <- JsonPath.chain(rendered) do
      {:ok, chain}
    else
      _invalid -> {:error, :definition_error}
    end
  end

  defp field_values(items, definition, variables, now) do
    rows = definition.search.rows
    fields = for {name, field} <- definition.search.fields, field.text == nil, do: {name, field}

    items
    |> Stream.flat_map(fn row -> for narrowed <- narrowed(row, rows), do: {row, narrowed} end)
    |> Stream.take(Items.max_rows())
    |> Enum.map(fn {row, narrowed} ->
      Map.new(fields, fn {name, field} ->
        {name, field_value(field, row, narrowed, variables, now)}
      end)
    end)
  end

  # The rows one rows-selector item gives after `rows.attribute` and `rows.multiple`.
  defp narrowed(row, rows) do
    case attribute(row, rows.attribute) do
      {:ok, value} when rows.multiple -> multiple(value)
      {:ok, %Jason.OrderedObject{} = value} -> [value]
      _none -> []
    end
  end

  defp attribute(row, nil), do: {:ok, row}

  defp attribute(row, path) do
    case JsonPath.parse(path) do
      {:ok, steps} -> JsonPath.select(row, steps)
      :error -> :none
    end
  end

  defp multiple(%Jason.OrderedObject{values: pairs}),
    do: for({_key, %Jason.OrderedObject{} = value} <- pairs, do: value)

  defp multiple(list) when is_list(list),
    do: for(%Jason.OrderedObject{} = value <- list, do: value)

  defp multiple(_value), do: []

  defp field_value(field, row, narrowed, variables, now) do
    case selected(field.selector, row, narrowed, variables, now) do
      {:ok, value} -> cased(field.case, value)
      :missing -> nil
    end
  end

  defp cased([_ | _] = cases, value), do: case_key(cases, value) || value
  defp cased(_cases, value), do: value

  # `{:ok, text}`, text nil for a JSON null, or `:missing` for no selection or a value
  # `Value<string>()` refuses: `HandleJsonSelector` returns or throws before its `case` then.
  defp selected(nil, _row, _narrowed, _variables, _now), do: {:ok, nil}

  defp selected(selector, row, narrowed, variables, now) do
    parent = if String.starts_with?(selector, ".."), do: row, else: narrowed

    with {:ok, rendered} <- Template.render(String.trim_leading(selector, "."), variables, now),
         {:ok, chain} <- JsonPath.chain(rendered),
         {:ok, steps} <- JsonPath.field(parent, chain),
         {:ok, value} <- JsonPath.select(parent, steps) do
      text(value)
    else
      _missing -> :missing
    end
  end

  defp text(list) when is_list(list), do: {:ok, Enum.map_join(list, ",", &JsonText.text/1)}

  defp text(value) do
    case JsonText.string_value(value) do
      :error -> :missing
      text_or_nil -> {:ok, text_or_nil}
    end
  end

  defp case_key(cases, value) do
    Enum.find_value(cases, fn {key, _value} ->
      if key == "*" or (value != nil and value == key), do: {:case, key}
    end)
  end
end
