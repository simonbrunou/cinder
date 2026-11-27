defmodule Cinder.Acquisition.Indexer.Cardigann.XmlRows do
  @moduledoc ~S"""
  The rows of one Cardigann XML search page (#1678), read as Prowlarr's `CardigannParser` reads
  a `response.type: xml` page with AngleSharp's `XmlParser` (`b0b5774`), as per-row field values
  in the shape `Cinder.Indexers.ParserWorker.run/3` gives for an HTML page: a field's text,
  `{:case, key}`, or nil. `Cinder.Acquisition.Indexer.Cardigann.Rows` then applies the same field
  and row rules to both. It runs in the search process.

  In order:

  1. a body that holds `<!DOCTYPE` or `<!ENTITY` anywhere is `{:error, :xml_dtd}`, before Saxy
     reads a byte, as `Cinder.Acquisition.Indexer.Newznab.XML` refuses a document type
     declaration. Saxy then expands only character references and the five predefined entities
     (`&amp;` and its kin), and keeps any other reference as its text;
  2. the page is already text in the definition's charset, so an `encoding` the XML declaration
     names is read as UTF-8, as AngleSharp ignores it in a string; then `Saxy.SimpleForm` parses
     the body, and a body it refuses is `{:error, :invalid_xml}`;
  3. the rows selector and each field's selector and `case` keys are rendered with the search
     variables and pass `Cinder.Acquisition.Indexer.Cardigann.XmlSelector.compile/2`; a template
     that does not render, or a rendering the gate refuses, is `{:error, :definition_error}`;
  4. Floki's selector engine runs each once on the whole tree, where every element carries its
     pre-order number, an element's name is matched by its local part (`attr` for
     `torznab:attr`, as a CSS type selector reads an XML element), and every element whose text
     content holds a `:contains` needle carries its marker. Element names keep their case
     (`pubDate`);
  5. the rows are the rows selector's matches in document order, at most
     `Cinder.Acquisition.Indexer.Newznab.Items.max_rows/0`. A field selector reads the row itself
     when it matches, else the row's first matching descendant: its `attribute`, nil when the
     element has none, or else its text content, every descendant text node joined. A field with
     `case` gives `{:case, key}` for the first key that matches the field's element or one of its
     descendants, and nil when none does, as an HTML field does.

  Every marker and number attribute name holds a random token, so a page cannot write one.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.{Template, XmlSelector}
  alias Cinder.Acquisition.Indexer.Newznab.Items

  @type values :: [%{String.t() => String.t() | {:case, String.t()} | nil}]

  @declarations ["<!DOCTYPE", "<!ENTITY"]
  @prolog ~r/\A(\x{FEFF}?\s*<\?xml\s[^>]*?\bencoding\s*=\s*)(["'])[^"']*\2/u

  @doc """
  The field values of each row of `text`, a page already decoded in the definition's charset,
  for `definition` under `variables` at `now`; see the moduledoc.
  """
  @spec values(String.t(), map(), Template.variables(), DateTime.t()) ::
          {:ok, values()} | {:error, :xml_dtd | :invalid_xml | :definition_error}
  def values(text, definition, variables, now) do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    with :ok <- no_declaration(text),
         {:ok, root} <- parse(text),
         {:ok, plan} <- plan(definition, variables, now, token) do
      {tree, ends} = annotate(root, plan.marks, token)
      {:ok, rows(tree, ends, plan, token)}
    end
  end

  defp no_declaration(text) do
    if String.contains?(text, @declarations), do: {:error, :xml_dtd}, else: :ok
  end

  # Saxy answers a malformed document with an error; the rescue keeps any raise on input it did
  # not expect from crashing the search.
  defp parse(text) do
    text = Regex.replace(@prolog, text, "\\1\\2UTF-8\\2", global: false)

    case Saxy.SimpleForm.parse_string(text, expand_entity: :keep) do
      {:ok, {_name, _attributes, _children} = root} -> {:ok, root}
      _error -> {:error, :invalid_xml}
    end
  rescue
    _exception -> {:error, :invalid_xml}
  end

  # --- the selectors ---

  defp plan(definition, variables, now, token) do
    fields = for {name, field} <- definition.search.fields, field.text == nil, do: {name, field}

    with {:ok, rows} <- selector(definition.search.rows.selector, variables, now, "#{token}-r"),
         {:ok, planned} <- plan_fields(fields, variables, now, token) do
      selectors = [rows | Enum.flat_map(planned, &[&1.selector | &1.cases])]

      marks =
        for s <- selectors,
            s != nil,
            {needle, n} <- Enum.with_index(s.needles),
            do: {marker(s.token, n), needle}

      {:ok, %{rows: rows, fields: planned, marks: marks}}
    end
  end

  defp plan_fields(fields, variables, now, token) do
    fields
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{name, field}, i}, {:ok, acc} ->
      case plan_field(field, variables, now, "#{token}-f#{i}") do
        {:ok, planned} -> {:cont, {:ok, [Map.put(planned, :name, name) | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, planned} -> {:ok, Enum.reverse(planned)}
      error -> error
    end
  end

  defp plan_field(%{selector: nil}, _variables, _now, _token),
    do: {:ok, %{selector: nil, attribute: nil, cases: [], keys: []}}

  defp plan_field(field, variables, now, token) do
    keys = Enum.map(field.case || [], &elem(&1, 0))

    with {:ok, selector} <- selector(field.selector, variables, now, token),
         {:ok, cases} <- case_selectors(keys, token) do
      {:ok, %{selector: selector, attribute: field.attribute, cases: cases, keys: keys}}
    end
  end

  defp case_selectors(keys, token) do
    keys
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {key, j}, {:ok, acc} ->
      case compiled(key, "#{token}-k#{j}") do
        {:ok, selector} -> {:cont, {:ok, [selector | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, selectors} -> {:ok, Enum.reverse(selectors)}
      error -> error
    end
  end

  defp selector(template, variables, now, token) do
    case Template.render(template || "", variables, now) do
      {:ok, rendered} -> compiled(rendered, token)
      {:error, _reason} -> {:error, :definition_error}
    end
  end

  defp compiled(selector, token) do
    case XmlSelector.compile(selector, token) do
      {:ok, %{whole: whole, needles: needles}} ->
        {:ok, %{whole: whole, needles: needles, token: token}}

      {:error, _code} ->
        {:error, :definition_error}
    end
  end

  defp marker(token, n), do: "cinder-#{token}-c#{n}"
  defp id_attribute(token), do: "cinder-#{token}-id"

  # --- the tree ---

  # Each element gets its pre-order number and the markers its text content earns, and its name
  # becomes its local part. Answers the tree and each number's last descendant number.
  #
  # An element's text content is a run of the page's text nodes in document order, so one pass
  # records each element's run as a range of that whole text, and an element earns a needle's
  # marker when an occurrence of the needle lies inside its range. This pass copies no text per
  # level. Floki's selector runs after it still cost more on a deep page (#1870).
  defp annotate(root, marks, token) do
    {tree, state} =
      number(root, id_attribute(token), %{id: 0, offset: 0, texts: [], ends: %{}, ranges: %{}})

    if marks == [] do
      {tree, state.ends}
    else
      text = IO.iodata_to_binary(state.texts)

      found =
        for {marker, needle} <- marks, do: {marker, byte_size(needle), occurrences(text, needle)}

      {mark(tree, id_attribute(token), found, state.ranges), state.ends}
    end
  end

  defp number({name, attributes, children}, id_attribute, state) do
    id = state.id
    start = state.offset

    {kids, state} =
      Enum.map_reduce(children, %{state | id: id + 1}, fn
        child, state when is_binary(child) ->
          {child, %{state | offset: state.offset + byte_size(child), texts: [state.texts, child]}}

        child, state ->
          number(child, id_attribute, state)
      end)

    state = %{
      state
      | ends: Map.put(state.ends, id, state.id - 1),
        ranges: Map.put(state.ranges, id, {start, state.offset})
    }

    {{local(name), [{id_attribute, Integer.to_string(id)} | attributes], kids}, state}
  end

  # Where each occurrence of `needle` starts, overlapping ones included, as a sorted tuple. An
  # empty needle needs none: it occurs in every element, as AngleSharp's `:contains("")` matches
  # every one.
  defp occurrences(_text, ""), do: {}
  defp occurrences(text, needle), do: text |> occurrences(needle, 0, []) |> List.to_tuple()

  defp occurrences(text, needle, from, acc) do
    case :binary.match(text, needle, scope: {from, byte_size(text) - from}) do
      {at, _size} -> occurrences(text, needle, at + 1, [at | acc])
      :nomatch -> Enum.reverse(acc)
    end
  end

  defp mark(
         {name, [{id_attribute, id_text} | _] = attributes, children},
         id_attribute,
         found,
         ranges
       ) do
    {start, stop} = Map.fetch!(ranges, String.to_integer(id_text))

    earned =
      for {marker, size, starts} <- found, holds?(starts, size, start, stop), do: {marker, ""}

    kids = Enum.map(children, &mark(&1, id_attribute, found, ranges))
    {name, attributes ++ earned, kids}
  end

  defp mark(text, _id_attribute, _found, _ranges) when is_binary(text), do: text

  defp holds?(_starts, 0, _start, _stop), do: true

  defp holds?(starts, size, start, stop) do
    at = first_at_least(starts, start, 0, tuple_size(starts))
    at != nil and at + size <= stop
  end

  # The smallest value of the sorted tuple `values` that is at least `floor`, or nil.
  defp first_at_least(values, floor, low, high) when low < high do
    mid = div(low + high, 2)

    if elem(values, mid) >= floor,
      do: first_at_least(values, floor, low, mid),
      else: first_at_least(values, floor, mid + 1, high)
  end

  defp first_at_least(values, _floor, low, _high) when low < tuple_size(values),
    do: elem(values, low)

  defp first_at_least(_values, _floor, _low, _high), do: nil

  defp local(name) do
    case String.split(name, ":") do
      [_one] -> name
      parts -> List.last(parts)
    end
  end

  # --- the rows ---

  defp rows(tree, ends, plan, token) do
    id_attribute = id_attribute(token)
    matched = matches(tree, plan.rows, id_attribute)
    fields = Enum.map(plan.fields, &with_matches(&1, tree, id_attribute))

    matched.ids
    |> Tuple.to_list()
    |> Enum.take(Items.max_rows())
    |> Enum.map(fn row ->
      Map.new(fields, fn field -> {field.name, value(field, row, ends, matched.nodes)} end)
    end)
  end

  defp with_matches(%{selector: nil} = field, _tree, _id_attribute),
    do: Map.put(field, :found, nil)

  defp with_matches(field, tree, id_attribute) do
    field
    |> Map.put(:found, matches(tree, field.selector, id_attribute))
    |> Map.put(:case_found, Enum.map(field.cases, &matches(tree, &1, id_attribute)))
  end

  # One selector's matches: their numbers in document order and each number's element.
  defp matches(tree, %{whole: whole}, id_attribute) do
    nodes =
      tree
      |> Floki.find(whole)
      |> Map.new(fn {_name, attributes, _children} = node ->
        {String.to_integer(:proplists.get_value(id_attribute, attributes)), node}
      end)

    %{ids: nodes |> Map.keys() |> Enum.sort() |> List.to_tuple(), nodes: nodes}
  end

  defp value(%{found: nil}, _row, _ends, _row_nodes), do: nil

  defp value(field, row, ends, _row_nodes) do
    case within(field.found, row, Map.fetch!(ends, row)) do
      nil -> nil
      id when field.keys != [] -> case_key(field, id, Map.fetch!(ends, id))
      id -> read(Map.fetch!(field.found.nodes, id), field.attribute)
    end
  end

  # The element itself when it matched, else its first matching descendant.
  defp within(found, id, last) do
    if Map.has_key?(found.nodes, id), do: id, else: first_after(found.ids, id, last)
  end

  # The smallest number in the sorted tuple `ids` above `id` and at most `last`, or nil.
  defp first_after(ids, id, last), do: search(ids, id, last, 0, tuple_size(ids))

  defp search(ids, id, last, low, high) when low < high do
    mid = div(low + high, 2)

    if elem(ids, mid) > id,
      do: search(ids, id, last, low, mid),
      else: search(ids, id, last, mid + 1, high)
  end

  defp search(ids, _id, last, low, _high) do
    if low < tuple_size(ids) and elem(ids, low) <= last, do: elem(ids, low)
  end

  defp case_key(field, id, last) do
    field.keys
    |> Enum.zip(field.case_found)
    |> Enum.find_value(fn {key, found} -> if within(found, id, last), do: {:case, key} end)
  end

  defp read({_name, attributes, _children}, attribute) when is_binary(attribute),
    do: :proplists.get_value(attribute, attributes, nil)

  defp read(node, nil), do: node |> text() |> IO.iodata_to_binary()

  defp text({_name, _attributes, children}), do: Enum.map(children, &text/1)
  defp text(text) when is_binary(text), do: text
end
