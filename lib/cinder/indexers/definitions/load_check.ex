defmodule Cinder.Indexers.Definitions.LoadCheck do
  @moduledoc ~S"""
  Loads one Cardigann definition copy and checks its CSS selectors in a throwaway parser worker
  (#1665, part of #1610; #1615: "At load, each selector ... runs in a throwaway worker; a crash
  marks the definition 'not supported'").

  `check/2` runs `Cinder.Indexers.Definitions.Loader.load/1`. A copy that fails to load comes back
  as the loader answered. For a copy that loads, whatever its unsupported features, it collects
  every selector the engine would hand lexbor, each once, in this order:

  - when the copy has no search path, or one whose response is HTML (no `response`, or a type
    other than `json` and `xml`): `search.rows` (its `selector`, `remove` and `case` keys, and
    those of `dateheaders` and `count`), each `search.fields` entry's `selector`, `remove` and
    `case` keys, and each `search.error` entry's `selector` and `message` selector. A JSON or XML
    copy's selectors there are paths for another reader (#1678);
  - `login`: `form`, `test.selector`, `captcha.selector`, each `error` entry's `selector` and
    `message` selector, and every `selectorinputs` and `getselectorinputs` selector;
  - `download`: each `selectors` entry, `before.pathselector` and `infohash`'s `hash` and `title`.

  A rows or field selector that holds `{{` is a template the search renders with its variables
  first (#1671): one that reads `.Result` gets `{:selector, :result_template}` and is not
  checked further; any other is rendered twice, every search variable blank and then every one
  set (`Cinder.Acquisition.Indexer.Cardigann.Variables`), and each rendering that is not blank is
  checked as a selector. A template that does not render gets `{:selector, :template}`. Any
  other selector that holds `{{` gets that code from the gate.

  Each passes through `Cinder.Indexers.Selector.compile/2`, and those that pass run in one worker
  (`Cinder.Indexers.ParserWorker.check_selectors/2`). Each problem adds its code to the copy's
  `unsupported`, after the loader's codes, once, in this order: `{:selector, :comment}`,
  `{:selector, :escape}`, `{:selector, :structure}`, `{:selector, :template}` and
  `{:selector, :result_template}`, `{:selector, :refused}` when lexbor refused a part or a whole
  selector, then the worker's failure, `{:selector, :crash}`, `{:selector, :timeout}`,
  `{:selector, :memory}` or `{:selector, :output_too_large}`, which stands for every selector of
  the copy, since one worker ran them all. A failed worker's code is then the only selector code:
  the gate's codes of that copy are dropped with the worker's verdicts.

  Before the selector codes comes the static layout check (#1671): `:dateparse_layout`, once,
  for a `dateparse` or `timeparse` layout that
  `Cinder.Acquisition.Indexer.Cardigann.DotnetDate.check_layout/1` refuses. The filters read a
  layout as written, `{{` included. It reads every field filter list (`filters`,
  `keywordsfilters`, `preprocessingfilters`), not the row filters.

  It then checks each static pattern (#1677): the argument of each `regexp` filter and the first
  argument of each `re_replace` filter, in every field filter list, `keywordsfilters` and
  `preprocessingfilters`, through `Cinder.Acquisition.Indexer.Cardigann.BoundedRegex.check/1`,
  which translates the .NET-only syntax first. A .NET balancing group or class subtraction, which
  PCRE lacks, or a `(?` outside `check/1`'s allowlist of groups, such as `(?x)`, adds
  `{:regex, :dotnet_only}`, and any other pattern the engine refuses `{:regex, :invalid}`, each
  once, after the selector codes. A `re_replace` written inside a template is not checked here:
  it runs, and fails its field, when the template is evaluated.

  The answer is `Loader.load/1`'s with those codes added. The selector check raised
  `Loader.fingerprint/0`'s revision to 2, the pattern check to 3 and the layout check, with the
  features #1671 switched on, to 4, for #1667 to store the answer under.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.{BoundedRegex, DotnetDate, Template, Variables}
  alias Cinder.Indexers.Definitions.Loader
  alias Cinder.Indexers.ParserWorker

  @codes [
    comment: {:selector, :comment},
    escape: {:selector, :escape},
    structure: {:selector, :structure},
    template: {:selector, :template},
    result_template: {:selector, :result_template},
    refused: {:selector, :refused},
    crash: {:selector, :crash},
    timeout: {:selector, :timeout},
    memory: {:selector, :memory},
    output_too_large: {:selector, :output_too_large}
  ]

  @regex_codes [{:regex, :dotnet_only}, {:regex, :invalid}]

  @doc "Every code `check/2` can add, in the order it adds them."
  @spec codes() :: [{:selector, atom()} | {:regex, atom()}]
  def codes, do: Keyword.values(@codes) ++ @regex_codes

  @doc """
  Loads `bytes` and checks the copy's selectors and static patterns. `opts` goes to
  `ParserWorker.check_selectors/2`.
  """
  @spec check(binary(), keyword()) :: {:ok, map()} | {:error, Loader.reason()}
  def check(bytes, opts \\ []) when is_binary(bytes) do
    with {:ok, definition} <- Loader.load(bytes) do
      codes =
        static_codes(definition) ++ selector_codes(definition, opts) ++ regex_codes(definition)

      {:ok, %{definition | unsupported: definition.unsupported ++ codes}}
    end
  end

  defp regex_codes(definition) do
    found =
      definition
      |> patterns()
      |> MapSet.new(fn pattern ->
        case BoundedRegex.check(pattern) do
          :ok -> :ok
          {:error, {:not_supported, :dotnet_only}} -> {:regex, :dotnet_only}
          {:error, _refused} -> {:regex, :invalid}
        end
      end)

    for code <- @regex_codes, code in found, do: code
  end

  @doc false
  # The static patterns `check/2` reads, in walk order; public for its test.
  @spec patterns(map()) :: [String.t()]
  def patterns(definition), do: definition |> walk([]) |> Enum.uniq()

  # `search.rows.filters` holds row filters, which take no pattern.
  defp walk(map, path) when is_map(map) do
    Enum.flat_map(map, fn
      {:filters, _filters} when path == [:rows, :search] ->
        []

      {key, filters} when key in [:filters, :keywordsfilters, :preprocessingfilters] ->
        Enum.flat_map(List.wrap(filters), &pattern/1)

      {key, value} ->
        walk(value, [key | path])
    end)
  end

  defp walk(list, path) when is_list(list), do: Enum.flat_map(list, &walk(&1, path))
  defp walk({key, value}, path) when is_binary(key), do: walk(value, path)
  defp walk(_value, _path), do: []

  defp pattern(%{name: "regexp", args: pattern}) when is_binary(pattern), do: [pattern]

  defp pattern(%{name: "re_replace", args: [pattern, _replacement]}) when is_binary(pattern),
    do: [pattern]

  defp pattern(_filter), do: []

  # `ParserWorker.check_selectors/2` starts no worker when the gate refuses every selector, or
  # when there is none. A rows or field selector that holds a template is checked as it renders
  # (`expand/2`); the outcomes it gives without a worker join the worker's.
  defp selector_codes(definition, opts) do
    {expanded, outcomes} =
      definition |> selectors() |> Enum.flat_map(&expand(&1, definition)) |> split_outcomes()

    case ParserWorker.check_selectors(Enum.uniq(expanded), opts) do
      {:ok, results} -> codes_of(MapSet.new(outcomes ++ Enum.map(results, &elem(&1, 1))))
      {:error, failure} -> [Keyword.fetch!(@codes, failure)]
    end
  end

  defp split_outcomes(items) do
    {selectors, outcomes} = Enum.split_with(items, &is_binary/1)
    {selectors, Enum.map(outcomes, fn {:outcome, outcome} -> outcome end)}
  end

  defp codes_of(found), do: for({outcome, code} <- @codes, outcome in found, do: code)

  # A selector that holds `{{` is a template the engine renders with the search variables before
  # it runs. One that reads `.Result` is `:result_template`, since its value differs per row. Any
  # other is rendered with every search variable blank, then with every one set, and each
  # rendering that is not blank is checked as a selector; a template that does not render under
  # both is `:template`. Only the rows selector and field selectors render at search time, so a
  # template anywhere else reaches the gate as it stands, which refuses it as `:template`.
  defp expand({:template, selector}, definition) do
    if String.contains?(selector, ".Result") do
      [{:outcome, :result_template}]
    else
      renderings(selector, definition)
    end
  end

  defp expand(selector, _definition), do: [selector]

  defp renderings(selector, definition) do
    now = DateTime.utc_now()

    [Variables.blank(definition), Variables.filled(definition)]
    |> Enum.map(&Template.render(selector, &1, now))
    |> Enum.reduce_while([], fn
      {:ok, rendered}, acc ->
        {:cont, if(String.trim(rendered) == "", do: acc, else: [rendered | acc])}

      {:error, _reason}, _acc ->
        {:halt, [{:outcome, :template}]}
    end)
    |> Enum.reverse()
  end

  ## Static codes

  # A `dateparse` or `timeparse` layout `DotnetDate.check_layout/1` refuses
  # (`:dateparse_layout`). The filters read a layout as written, so one that holds `{{` is
  # checked as it stands. `Loader` already names each filter outside the engine's list, and
  # `regex_codes/1` checks the patterns.
  defp static_codes(definition) do
    refused? =
      definition
      |> filters()
      |> Enum.any?(fn
        %{name: name, args: layout}
        when name in ["dateparse", "timeparse"] and is_binary(layout) ->
          DotnetDate.check_layout(layout) != :ok

        _filter ->
          false
      end)

    if refused?, do: [:dateparse_layout], else: []
  end

  # Every field filter list of the copy: `filters`, `keywordsfilters` and
  # `preprocessingfilters`, wherever they sit, but not `search.rows.filters`, which holds row
  # filters.
  defp filters(map) when is_map(map) do
    Enum.flat_map(map, fn
      {:rows, rows} when is_map(rows) ->
        filters(Map.delete(rows, :filters))

      {key, list}
      when key in [:filters, :keywordsfilters, :preprocessingfilters] and is_list(list) ->
        list

      {_key, value} ->
        filters(value)
    end)
  end

  defp filters(list) when is_list(list), do: Enum.flat_map(list, &filters/1)
  defp filters({key, value}) when is_binary(key), do: filters(value)
  defp filters(_value), do: []

  @doc false
  # The selectors `check/2` runs, in its order, a rows or field selector that holds `{{` as
  # `{:template, selector}`; public for its test.
  @spec selectors(map()) :: [String.t() | {:template, String.t()}]
  def selectors(definition) do
    search = if html_search?(definition.search), do: search_selectors(definition.search), else: []

    (search ++ login_selectors(definition.login) ++ download_selectors(definition.download))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp html_search?(%{paths: []}), do: true

  defp html_search?(%{paths: paths}) do
    Enum.any?(paths, fn
      %{response: nil} -> true
      %{response: %{type: type}} -> type not in ["json", "xml"]
    end)
  end

  defp search_selectors(search) do
    rendered_block(search.rows) ++
      block(search.rows && search.rows.dateheaders) ++
      block(search.rows && search.rows.count) ++
      Enum.flat_map(search.fields, fn {_name, field} -> rendered_block(field) end) ++
      Enum.flat_map(search.error, &error_selectors/1)
  end

  defp login_selectors(nil), do: []

  defp login_selectors(login) do
    [login.form, login.test && login.test.selector, login.captcha && login.captcha.selector] ++
      Enum.flat_map(login.error, &error_selectors/1) ++
      Enum.flat_map(login.selectorinputs ++ login.getselectorinputs, fn {_name, input} ->
        block(input)
      end)
  end

  defp download_selectors(nil), do: []

  defp download_selectors(download) do
    Enum.map(download.selectors, & &1.selector) ++
      [
        download.before && download.before.pathselector && download.before.pathselector.selector,
        download.infohash && download.infohash.hash && download.infohash.hash.selector,
        download.infohash && download.infohash.title && download.infohash.title.selector
      ]
  end

  defp error_selectors(error), do: [error.selector | block(error.message)]

  # A selector block's own selector, its `remove`, and each `case` key.
  defp block(nil), do: []
  defp block(block), do: [block.selector, block.remove | Enum.map(block.case, &elem(&1, 0))]

  # The rows block and each field: their own selector renders as a template at search time.
  defp rendered_block(nil), do: []

  defp rendered_block(%{selector: selector} = block) when is_binary(selector) do
    if String.contains?(selector, "{{"),
      do: [{:template, selector} | tl(block(block))],
      else: block(block)
  end

  defp rendered_block(block), do: block(block)
end
