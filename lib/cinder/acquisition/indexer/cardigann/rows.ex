defmodule Cinder.Acquisition.Indexer.Cardigann.Rows do
  @moduledoc """
  The rows of one Cardigann search page (#1671; #1618 points 6, 7 and 15), read as Prowlarr's
  `CardigannParser` reads an HTML page (`b0b5774`), with the exceptions the issue sets.

  ## Extraction

  The page is read as UTF-8, each byte sequence that is not UTF-8 as U+FFFD
  (`String.replace_invalid/1`), so one such byte costs no row. Every selector runs in a
  `Cinder.Indexers.ParserWorker`: the rows selector and each field's selector, rendered first
  with the search variables, go in as one plan, and per-row values come out. A field written as
  `text` has no selector in the plan. The worker gets the smaller of 30 s and the time left
  before the search deadline.

  ## Fields

  Each row starts with `.Result.<name>` nil for every field, then runs the fields in file order,
  each one reading the earlier ones:

  1. the value: a `text` field's template rendered; else the worker's value, trimmed, or for a
     `case` field the first matching key's value rendered as a template;
  2. an `optional` field with a blank value takes its `default` rendered; a blank default leaves
     `.Result.<name>` nil and skips the filters;
  3. the field's filters (`Cinder.Acquisition.Indexer.Cardigann.Filters`). The issue orders the
     default before the filters; Prowlarr filters the selector's value and leaves the default
     unfiltered.

  A field with no value (a selector that matched nothing, a `case` that matched no key) or whose
  template or filter fails leaves `.Result.<name>` nil and the row goes on, as Prowlarr's parser
  does. A regex limit or the filter-chain cap in a field drops the row and marks the page
  partial with that kind. `.Result.<name>` holds the field's text after its filters.

  ## Row filter and row

  With the `andmatch` row filter listed and the call's query text not blank, a row stays only
  when `Filters.andmatch?/3` keeps it for its title and description. Then:

  - `title`: the shared title rule (`Cinder.Acquisition.Indexer.Newznab.Items.row_title/1`);
  - `download_url`: the `download` value (a `magnet:` value as it is, any other resolved against
    the page's URL and kept when it is an http(s) URL), else the `magnet` value when it starts
    with `magnet:`, else, unless the definition's `type` is `private`, a magnet built from
    `infohash`: `magnet:?xt=urn:btih:<hash>&dn=<title>`, with no tracker. A row with no link
    or no title is dropped, and so is one whose link holds a secret off the credential hosts
    (`Cinder.Acquisition.Indexer.Cardigann.Fetch.secret_link?/2`), counted as missing its link;
  - `size`: `Cinder.Acquisition.Indexer.Cardigann.Size.bytes/1`;
  - `category_ids`: the value split on `,`, each part trimmed and mapped through
    `categorymappings` (the site id in any case) to every standard category it names, each once;
    nil when none maps;
  - `published_at`: `Cinder.Acquisition.Indexer.Cardigann.DotnetDate.from_unknown/2`;
  - `protocol` `:torrent`, `download_url_origin` and `tvdb_id` nil.

  Seeders, leechers, grabs and volume factors are read only as `.Result` values. The page's
  rows then pass `Cinder.Acquisition.Indexer.Newznab.Items.kept/1`.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.{DotnetDate, Fetch, Filters, Query, Size, Template}
  alias Cinder.Acquisition.Indexer.Newznab.Items
  alias Cinder.Indexers.ParserWorker

  @worker_ms 30_000

  @type page :: %{
          rows: [map()],
          count: non_neg_integer(),
          partial: atom() | nil,
          missing: [:title | :download_url]
        }

  @doc """
  Reads `html`, the page `uri` answered to the Fetch `request` (its secrets, credential hosts and
  clock), for `definition` under the search `variables`, with the call's query text `query_text`
  (nil for none) and `deadline_at` in `System.monotonic_time(:millisecond)`. Answers
  `{:ok, page}`: `rows`, `count` (how many rows the rows selector matched, before the row filter
  and the row rules, which Prowlarr's page loop counts), `partial` (nil, `:regex_limit` or `:filter_output_cap`) and `missing`, the required
  field each row dropped for lack of one lacked first (`:title`, then `:download_url`), in page
  order, for the canary. Or `{:error, reason}`:
  `:parser_failed` for a worker that crashed, ran out of memory or time, or refused a selector;
  `:deadline` for a worker the search deadline cut; `:definition_error` for a selector template
  that does not render.

  The worker gets 30 s or what is left before `deadline_at`, whichever is less, and
  `[:cinder, :cardigann, :parse]` reports that budget as `deadline_ms` before it starts.
  """
  @spec read(
          binary(),
          map(),
          Template.variables(),
          URI.t(),
          String.t() | nil,
          integer(),
          Fetch.request()
        ) ::
          {:ok, page()} | {:error, atom()}
  def read(html, definition, variables, uri, query_text, deadline_at, request) do
    with {:ok, plan} <- plan(definition, variables, request.now),
         {:ok, values} <- run(String.replace_invalid(html), plan, deadline_at) do
      read_rows(values, definition, variables, uri, query_text, request)
    end
  end

  # --- the worker ---

  defp plan(definition, variables, now) do
    rows = definition.search.rows

    with {:ok, rows_selector} <- render(rows.selector, variables, now),
         {:ok, fields} <- plan_fields(definition.search.fields, variables, now) do
      {:ok, %{rows: rows_selector, fields: fields}}
    end
  end

  defp plan_fields(fields, variables, now) do
    fields
    |> Enum.reject(fn {_name, field} -> field.text != nil or field.selector == nil end)
    |> Enum.reduce_while({:ok, []}, fn {name, field}, {:ok, acc} ->
      case render(field.selector, variables, now) do
        {:ok, selector} ->
          entry = %{
            name: name,
            selector: selector,
            attribute: field.attribute,
            remove: List.wrap(field.remove),
            case: Enum.map(field.case || [], &elem(&1, 0))
          }

          {:cont, {:ok, [entry | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp render(nil, _variables, _now), do: {:error, :definition_error}

  defp render(template, variables, now) do
    case Template.render(template, variables, now) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} -> {:error, :definition_error}
    end
  end

  defp run(html, plan, deadline_at) do
    left_ms = deadline_at - System.monotonic_time(:millisecond)

    if left_ms <= 0 do
      {:error, :deadline}
    else
      worker_ms = min(@worker_ms, left_ms)
      :telemetry.execute([:cinder, :cardigann, :parse], %{deadline_ms: worker_ms}, %{})

      case ParserWorker.run(html, plan, deadline_ms: worker_ms) do
        {:ok, rows} -> {:ok, rows}
        {:error, :timeout} when left_ms <= @worker_ms -> {:error, :deadline}
        {:error, _failure} -> {:error, :parser_failed}
      end
    end
  end

  # --- the fields ---

  defp read_rows(values, definition, variables, uri, query_text, request) do
    now = request.now
    fields = definition.search.fields

    seeded =
      Map.merge(variables, Map.new(fields, fn {name, _field} -> {".Result." <> name, nil} end))

    andmatch? = andmatch?(definition, query_text)
    mappings = Query.mappings(definition)
    private? = definition.type == "private"

    one_row = fn results ->
      keep?(results, andmatch?, query_text) && row(results, uri, mappings, private?, request)
    end

    {rows, missing, partial} =
      Enum.reduce(values, {[], [], nil}, fn row_values, {rows, missing, partial} ->
        case fields(fields, Map.new(row_values), seeded, now) do
          {:ok, results} -> {rows, missing, partial} |> add_row(one_row.(results))
          {:dropped, kind} -> {rows, missing, partial || kind}
        end
      end)

    {:ok,
     %{
       rows: rows |> Enum.reverse() |> Items.kept(),
       count: length(values),
       partial: partial,
       missing: Enum.reverse(missing)
     }}
  end

  # A row andmatch drops, one missing a required field, or a release row.
  defp add_row(acc, false), do: acc

  defp add_row({rows, missing, partial}, {:missing, field}),
    do: {rows, [field | missing], partial}

  defp add_row({rows, missing, partial}, row), do: {[row | rows], missing, partial}

  defp fields(fields, worker_values, variables, now) do
    Enum.reduce_while(fields, {:ok, variables}, fn {name, field}, {:ok, vars} ->
      case field_value(field, Map.get(worker_values, name), vars, now) do
        {:ok, value} -> {:cont, {:ok, Map.put(vars, ".Result." <> name, value)}}
        {:dropped, kind} -> {:halt, {:dropped, kind}}
      end
    end)
  end

  # `{:ok, value}`, value nil for a field that failed or stayed blank, or `{:dropped, kind}`.
  defp field_value(field, worker_value, vars, now) do
    with {:ok, raw} <- found(field, raw(field, worker_value, vars, now)),
         {:ok, value} <- defaulted(field, raw, vars, now) do
      filtered(field, value, vars, now)
    else
      :none -> {:ok, nil}
      {:dropped, kind} -> {:dropped, kind}
    end
  end

  defp raw(%{text: text}, _worker_value, vars, now) when is_binary(text),
    do: template(text, vars, now)

  defp raw(%{case: [_ | _] = cases}, {:case, selector}, vars, now) do
    case List.keyfind(cases, selector, 0) do
      {^selector, value} -> template(value || "", vars, now)
      nil -> :missing
    end
  end

  defp raw(_field, value, _vars, _now) when is_binary(value), do: {:ok, String.trim(value)}
  defp raw(_field, _value, _vars, _now), do: :missing

  # A selector that matched nothing, or a `case` with no key that matched: an optional field
  # goes on blank to its default, any other fails, as Prowlarr's `HandleSelector` throws.
  defp found(%{optional: true}, :missing), do: {:ok, ""}
  defp found(_field, :missing), do: :none
  defp found(_field, raw), do: raw

  # A template's text, `:none` when it fails, or `{:dropped, kind}` for a limit.
  defp template(text, vars, now) do
    case Template.render(text, vars, now) do
      {:ok, value} -> {:ok, value}
      {:error, kind} when kind in [:regex_limit, :filter_output_cap] -> {:dropped, kind}
      {:error, _reason} -> :none
    end
  end

  defp defaulted(%{optional: true} = field, raw, vars, now) do
    cond do
      not blank?(raw) ->
        {:ok, raw}

      field.default == nil ->
        :none

      true ->
        field.default |> template(vars, now) |> rendered_default()
    end
  end

  defp defaulted(_field, raw, _vars, _now), do: {:ok, raw}

  defp rendered_default({:ok, default}), do: if(blank?(default), do: :none, else: {:ok, default})
  defp rendered_default(other), do: other

  defp filtered(field, value, vars, now) do
    case Filters.apply(value, field.filters || [], vars, now) do
      {:ok, filtered} -> {:ok, filtered}
      {:error, kind} when kind in [:regex_limit, :filter_output_cap] -> {:dropped, kind}
      {:error, _reason} -> {:ok, nil}
    end
  end

  defp blank?(value), do: value == nil or String.trim(value) == ""

  # --- the row ---

  defp andmatch?(definition, query_text) do
    filters = definition.search.rows.filters || []

    Enum.any?(filters, &(&1.name == "andmatch")) and is_binary(query_text) and
      String.trim(query_text) != ""
  end

  defp keep?(_results, false, _query_text), do: true

  defp keep?(results, true, query_text),
    do: Filters.andmatch?(query_text, results[".Result.title"], results[".Result.description"])

  defp row(results, uri, mappings, private?, request) do
    title = Items.row_title(results[".Result.title"])
    link = link(results, uri, title, private?)

    cond do
      title == nil -> {:missing, :title}
      link == nil or Fetch.secret_link?(link, request) -> {:missing, :download_url}
      true -> release(title, link, results, mappings, request.now)
    end
  end

  defp release(title, link, results, mappings, now) do
    %{
      title: title,
      download_url: link,
      download_url_origin: nil,
      protocol: :torrent,
      size: size(results[".Result.size"]),
      category_ids: category_ids(results[".Result.category"], mappings),
      published_at: published_at(results[".Result.date"], now),
      tvdb_id: nil
    }
  end

  defp link(results, uri, title, private?) do
    download_link(results[".Result.download"], uri) || magnet(results[".Result.magnet"]) ||
      infohash_magnet(results[".Result.infohash"], title, private?)
  end

  defp download_link(value, uri) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      String.starts_with?(value, "magnet:") -> value
      true -> resolved(uri, value)
    end
  end

  defp download_link(_value, _uri), do: nil

  defp resolved(uri, value) do
    with {:ok, _ref} <- URI.new(value),
         %URI{scheme: scheme, host: host} = merged
         when scheme in ["http", "https"] and is_binary(host) and host != "" <-
           URI.merge(uri, value) do
      URI.to_string(merged)
    else
      _invalid -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp magnet(value) when is_binary(value) do
    value = String.trim(value)
    if String.starts_with?(value, "magnet:"), do: value
  end

  defp magnet(_value), do: nil

  defp infohash_magnet(_hash, _title, true = _private?), do: nil
  defp infohash_magnet(_hash, nil, _private?), do: nil

  defp infohash_magnet(hash, title, false) when is_binary(hash) do
    case String.trim(hash) do
      "" -> nil
      hash -> "magnet:?xt=urn:btih:" <> hash <> "&dn=" <> URI.encode_www_form(title)
    end
  end

  defp infohash_magnet(_hash, _title, _private?), do: nil

  defp size(value) when is_binary(value), do: Size.bytes(value)
  defp size(_value), do: nil

  defp category_ids(value, mappings) when is_binary(value) do
    parts = value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    ids =
      for part <- parts,
          {site_id, standard} <- mappings,
          String.downcase(site_id) == String.downcase(part),
          uniq: true,
          do: standard

    if ids == [], do: nil, else: ids
  end

  defp category_ids(_value, _mappings), do: nil

  defp published_at(value, now) when is_binary(value) do
    case DotnetDate.from_unknown(value, now) do
      {:ok, time} -> time
      :error -> nil
    end
  end

  defp published_at(_value, _now), do: nil
end
