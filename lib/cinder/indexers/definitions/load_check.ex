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

  Each passes through `Cinder.Indexers.Selector.compile/2`, and those that pass run in one worker
  (`Cinder.Indexers.ParserWorker.check_selectors/2`). Each problem adds its code to the copy's
  `unsupported`, after the loader's codes, once, in this order: `{:selector, :comment}`,
  `{:selector, :escape}`, `{:selector, :structure}` and `{:selector, :template}` from the gate
  (a template holds `{{`, which the load check cannot expand before #1670), `{:selector,
  :refused}` when lexbor refused a part or a whole selector, then the worker's failure,
  `{:selector, :crash}`, `{:selector, :timeout}`, `{:selector, :memory}` or
  `{:selector, :output_too_large}`, which stands for every selector of the copy, since one worker
  ran them all. A failed worker's code is then the only selector code: the gate's codes of that
  copy are dropped with the worker's verdicts.

  It then checks each static pattern (#1677): the argument of each `regexp` filter and the first
  argument of each `re_replace` filter, in every field filter list, `keywordsfilters` and
  `preprocessingfilters`, through `Cinder.Acquisition.Indexer.Cardigann.BoundedRegex.check/1`,
  which translates the .NET-only syntax first. A .NET balancing group or class subtraction, which
  PCRE lacks, or a `(?` outside `check/1`'s allowlist of groups, such as `(?x)`, adds
  `{:regex, :dotnet_only}`, and any other pattern the engine refuses `{:regex, :invalid}`, each
  once, after the selector codes. A `re_replace` written inside a template is not checked here:
  it runs, and fails its field, when the template is evaluated.

  The answer is `Loader.load/1`'s with those codes added. The selector check raised
  `Loader.fingerprint/0`'s revision to 2 and the pattern check to 3, for #1667 to store the
  answer under.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.BoundedRegex
  alias Cinder.Indexers.Definitions.Loader
  alias Cinder.Indexers.ParserWorker

  @codes [
    comment: {:selector, :comment},
    escape: {:selector, :escape},
    structure: {:selector, :structure},
    template: {:selector, :template},
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
      codes = selector_codes(definition, opts) ++ regex_codes(definition)
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
  # when there is none.
  defp selector_codes(definition, opts),
    do: definition |> selectors() |> ParserWorker.check_selectors(opts) |> codes_of()

  defp codes_of({:ok, results}) do
    found = MapSet.new(results, &elem(&1, 1))
    for {outcome, code} <- @codes, outcome in found, do: code
  end

  defp codes_of({:error, failure}), do: [Keyword.fetch!(@codes, failure)]

  @doc false
  # The selectors `check/2` runs, in its order; public for its test.
  @spec selectors(map()) :: [String.t()]
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
    block(search.rows) ++
      block(search.rows && search.rows.dateheaders) ++
      block(search.rows && search.rows.count) ++
      Enum.flat_map(search.fields, fn {_name, field} -> block(field) end) ++
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
end
