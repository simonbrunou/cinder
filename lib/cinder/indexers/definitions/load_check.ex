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
    those of `dateheaders`; `count` is read on a JSON page only), each `search.fields` entry's
    `selector`, `remove` and `case` keys, and each `search.error` entry's `selector` and `message` selector. A JSON or XML
    copy's selectors there are paths for another reader (#1678);
  - `login`: `form`, `test.selector`, `captcha.selector`, each `inputs` key when `selectors` is
    on (#1680), each `error` entry's `selector` and `message` selector, and every
    `selectorinputs` and `getselectorinputs` selector;
  - `download`: each `selectors` entry, `before.pathselector` and `infohash`'s `hash` and
    `title`, then the `remove` of each `selectors` entry and of `hash` and `title` (#1679).

  A rows or field selector that holds `{{` is a template the search renders with its variables
  first (#1671). A rows selector that reads `.Result` gets `{:selector, :result_template}` and is
  not checked further. A field selector that reads `.Result` renders per row in a later worker
  round (#1679, `Cinder.Acquisition.Indexer.Cardigann.Rows`): on a copy whose every search path
  answers HTML and whose chain `Rows.result_rounds/1` allows, it is rendered twice, every search
  variable and every `.Result.<field>` blank, then every one set; otherwise it gets
  `{:selector, :result_template}`. Any other rows or field template is rendered twice, every
  search variable blank and then every one set
  (`Cinder.Acquisition.Indexer.Cardigann.Variables`). Each rendering that is not blank is
  checked as a selector, and a template that does not render gets `{:selector, :template}`. A
  `download.selectors` entry or an `infohash` selector that holds `{{` is a template the grab
  renders with its own variables first (#1672, #1679): it is rendered twice, every grab variable
  blank and then every one set (`Variables.download/3`: the settings and the link's
  `.DownloadUri.*` names, each `.DownloadUri.Query.<key>` it names included), each rendering
  checked the same way. One that does not render, as one that reads `.Result` or `.Keywords`,
  gets `{:selector, :template}`. Any other selector that holds `{{` gets that code from the
  gate.

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

  Last come the checks of #1678, each code once, in this order:

  - `{:json, :path}` when a copy with a JSON search path holds a rows selector, a `rows.count`
    selector or a field selector (its leading dots trimmed) that
    `Cinder.Acquisition.Indexer.Cardigann.JsonPath.chain/1` does not read, or a `rows.attribute`
    that `JsonPath.parse/1` does not read; and, in any copy, a `jsonjoinarray` filter whose path
    `JsonPath.parse/1` does not read. A selector that holds `{{` is checked as it renders, as a
    rows or field selector above is, and one that does not render gets the code too;
  - `{:xml_selector, name}` or `{:xml_selector, :invalid}` for each rows selector, field
    selector, field `case` key and field `remove` (#1679) of a copy with an XML search path that
    `Cinder.Acquisition.Indexer.Cardigann.XmlSelector.compile/2` refuses, the first refusal of
    each selector, each code once in the order found; a template is checked as it renders, and
    one that does not render is `{:xml_selector, :invalid}`;
  - `{:certificates, :malformed}` for a `certificates` entry that is not 40 hex digits.

  The answer is `Loader.load/1`'s with those codes added. The selector check raised
  `Loader.fingerprint/0`'s revision to 2, the pattern check to 3, the layout check, with the
  features #1671 switched on, to 4, and the download selector templates, with the download block
  #1672 switched on, to 5, the JSON, XML and certificate checks, with what #1678 switched on,
  to 6, and the `.Result` field renderings and the download `remove` checks, with what #1679
  switched on, to 7, and the `login.inputs` keys, with the logins #1680 switched on, to 8, for
  #1667 to store the answer under.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.{
    BoundedRegex,
    DotnetDate,
    JsonPath,
    Rows,
    Template,
    Variables,
    XmlSelector
  }

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
  @json_code {:json, :path}
  @certificate_code {:certificates, :malformed}
  @thumbprint ~r/\A[0-9A-Fa-f]{40}\z/

  @doc """
  Every code `check/2` can add, in the order it adds them, with `{:xml_selector, :invalid}`
  standing for every `{:xml_selector, name}` too.
  """
  @spec codes() :: [tuple() | atom()]
  def codes,
    do:
      Keyword.values(@codes) ++
        @regex_codes ++ [@json_code, {:xml_selector, :invalid}, @certificate_code]

  @doc """
  Loads `bytes` and checks the copy's selectors and static patterns. `opts` goes to
  `ParserWorker.check_selectors/2`.
  """
  @spec check(binary(), keyword()) :: {:ok, map()} | {:error, Loader.reason()}
  def check(bytes, opts \\ []) when is_binary(bytes) do
    with {:ok, definition} <- Loader.load(bytes) do
      codes =
        static_codes(definition) ++
          selector_codes(definition, opts) ++
          regex_codes(definition) ++
          json_codes(definition) ++ xml_codes(definition) ++ certificate_codes(definition)

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

  ## JSON, XML and certificates (#1678)

  defp json_codes(definition) do
    search = definition.search

    selectors =
      if response?(search, "json") do
        rows = search.rows

        [{:chain, rows.selector || ""}, {:path, rows.attribute}] ++
          [{:chain, rows.count && trimmed(rows.count.selector)}] ++
          for({_name, field} <- search.fields, do: {:chain, trimmed(field.selector)})
      else
        []
      end

    joins =
      for %{name: "jsonjoinarray", args: [path | _]} <- filters(definition),
          is_binary(path),
          do: {:path, path}

    if Enum.all?(selectors ++ joins, &json_readable?(&1, definition)), do: [], else: [@json_code]
  end

  defp trimmed(nil), do: nil
  defp trimmed(selector), do: String.trim_leading(selector, ".")

  defp json_readable?({_kind, nil}, _definition), do: true

  defp json_readable?({kind, text}, definition) do
    texts = if String.contains?(text, "{{"), do: renderings(text, definition), else: [text]

    Enum.all?(texts, fn
      {:outcome, _template} -> false
      text when kind == :chain -> JsonPath.chain(text) != :error
      text -> JsonPath.parse(text) != :error
    end)
  end

  defp xml_codes(definition) do
    search = definition.search

    if response?(search, "xml") do
      fields = for {_name, field} <- search.fields, do: field

      [search.rows.selector || ""]
      |> Kernel.++(Enum.map(fields, & &1.selector))
      |> Kernel.++(for field <- fields, {key, _value} <- field.case || [], do: key)
      |> Kernel.++(Enum.map(fields, & &1.remove))
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&xml_refusals(&1, definition))
      |> Enum.uniq()
    else
      []
    end
  end

  defp xml_refusals(selector, definition) do
    texts =
      if String.contains?(selector, "{{"), do: renderings(selector, definition), else: [selector]

    for text <- texts, code = xml_refusal(text), code != nil, do: code
  end

  defp xml_refusal({:outcome, _template}), do: {:xml_selector, :invalid}

  defp xml_refusal(text) do
    case XmlSelector.compile(text, "check") do
      {:ok, _compiled} -> nil
      {:error, code} -> code
    end
  end

  defp certificate_codes(definition) do
    # The loader keeps a null entry of the list as nil.
    if Enum.all?(definition.certificates, &(is_binary(&1) and Regex.match?(@thumbprint, &1))),
      do: [],
      else: [@certificate_code]
  end

  defp response?(%{paths: paths}, type),
    do: Enum.any?(paths, &match?(%{response: %{type: ^type}}, &1))

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
  # both is `:template`. A download selector renders the same way under the grab's variables.
  # Only those selectors render, so a template anywhere else reaches the gate as it stands, which
  # refuses it as `:template`.
  defp expand({:template, selector}, definition) do
    if String.contains?(selector, ".Result") do
      [{:outcome, :result_template}]
    else
      renderings(selector, definition)
    end
  end

  # A field selector that reads `.Result` renders per row in a later worker round on an HTML
  # page (#1679): it is rendered with every search variable and every `.Result.<field>` blank,
  # then with every one set. On a copy with a JSON or XML path, which renders it once, or past
  # the rounds `Rows.result_rounds/1` allows, it stays `:result_template`.
  defp expand({:result_template, selector}, definition) do
    search = definition.search

    if html_only?(search) and Rows.result_rounds(search.fields) != :too_many do
      renderings(selector, [
        Map.merge(Variables.blank(definition), results(search.fields, nil)),
        Map.merge(Variables.filled(definition), results(search.fields, "x"))
      ])
    else
      [{:outcome, :result_template}]
    end
  end

  defp expand({:download_template, selector}, definition) do
    renderings(selector, [
      Variables.download(definition, selector, nil),
      Variables.download(definition, selector, "x")
    ])
  end

  defp expand(selector, _definition), do: [selector]

  defp results(fields, value),
    do: Map.new(fields, fn {name, _field} -> {".Result." <> name, value} end)

  defp renderings(selector, %{} = definition),
    do: renderings(selector, [Variables.blank(definition), Variables.filled(definition)])

  defp renderings(selector, variable_sets) do
    now = DateTime.utc_now()

    variable_sets
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
  # `{:template, selector}` and a download selector that holds one as
  # `{:download_template, selector}`; public for its test.
  @spec selectors(map()) ::
          [
            String.t()
            | {:template | :result_template | :download_template, String.t()}
          ]
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

  defp html_only?(%{paths: paths}),
    do:
      Enum.all?(paths, &(not match?(%{response: %{type: type}} when type in ["json", "xml"], &1)))

  defp search_selectors(search) do
    rendered_block(search.rows) ++
      block(search.rows && search.rows.dateheaders) ++
      Enum.flat_map(search.fields, fn {_name, field} -> field_block(field) end) ++
      Enum.flat_map(search.error, &error_selectors/1)
  end

  defp login_selectors(nil), do: []

  # With `login.selectors` on, each `login.inputs` key is a selector the form login reads its
  # input's name with (#1680).
  defp login_selectors(login) do
    input_keys = if login.selectors, do: for({key, _value} <- login.inputs, do: key), else: []

    [login.form, login.test && login.test.selector, login.captcha && login.captcha.selector] ++
      input_keys ++
      Enum.flat_map(login.error, &error_selectors/1) ++
      Enum.flat_map(login.selectorinputs ++ login.getselectorinputs, fn {_name, input} ->
        block(input)
      end)
  end

  defp download_selectors(nil), do: []

  # A `selectors` entry renders as a template with the grab's variables first (#1672). Each
  # block's `remove` is a plain selector, which the grab does not render (#1679).
  defp download_selectors(download) do
    infohash = download.infohash && [download.infohash.hash, download.infohash.title]
    blocks = download.selectors ++ Enum.reject(infohash || [], &is_nil/1)

    Enum.map(download.selectors, fn %{selector: selector} ->
      if is_binary(selector) and String.contains?(selector, "{{"),
        do: {:download_template, selector},
        else: selector
    end) ++
      [
        download.before && download.before.pathselector && download.before.pathselector.selector,
        download_template(download.infohash && download.infohash.hash),
        download_template(download.infohash && download.infohash.title)
      ] ++ Enum.map(blocks, & &1.remove)
  end

  # An `infohash` selector renders with the grab's variables too (#1679).
  defp download_template(%{selector: selector}) when is_binary(selector) do
    if String.contains?(selector, "{{"), do: {:download_template, selector}, else: selector
  end

  defp download_template(_block), do: nil

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

  defp field_block(%{selector: selector} = field) when is_binary(selector) do
    if Rows.result_selector?(field),
      do: [{:result_template, selector} | tl(block(field))],
      else: rendered_block(field)
  end

  defp field_block(field), do: rendered_block(field)
end
