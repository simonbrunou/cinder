defmodule Cinder.Acquisition.Indexer.Cardigann.Headers do
  @moduledoc """
  A Cardigann definition's custom headers (#1679), as Prowlarr's `CardigannBase.ParseCustomHeaders`
  reads them (`b0b5774`): each header's first value is a template, rendered with the request's
  variables, and the other values are ignored. A header with no value is left out.

  `render/3` refuses a header Cinder cannot send as written: a name that is not an HTTP token,
  or a value with a byte outside printable ASCII and the tab, is `{:error, :definition_error}`.
  Mint refuses such a value too, but its error holds the value, which can hold a secret.
  It leaves out the names that frame the request, which Cinder sets itself or never sends
  (`content-length`, `transfer-encoding`, `connection`, `keep-alive`, `te`, `trailer`,
  `upgrade`, `expect`, `proxy-connection`). `host` and `accept-encoding` stay in the list, and
  `Cinder.Acquisition.Indexer.Cardigann.Fetch` writes its own over them.

  The headers go on a request only when its host is one of the definition's credential hosts
  (`Fetch.send_get/3`'s `site_headers`), so they are dropped on a hop to any other host (#1615,
  "Credentials"). A search sends `search.headers` (`search/3`); a grab sends `download.headers`
  when the definition sets any, else `search.headers` (`download/3`), as Prowlarr's
  `Download?.Headers ?? Search?.Headers` does. #1680's login requests read `search/3` when the
  definition has no `login.headers`.

  No error holds a header name or value.
  """

  alias Cinder.Acquisition.Indexer.Cardigann.Template

  @framing ~w(content-length transfer-encoding connection keep-alive te trailer upgrade expect
              proxy-connection)
  @token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @value ~r/\A[\t\x20-\x7e]*\z/

  @type header :: {String.t(), String.t()}

  @doc "The definition's `search.headers` rendered under `variables`; see the moduledoc."
  @spec search(map(), Template.variables(), DateTime.t()) ::
          {:ok, [header()]} | {:error, atom()}
  def search(definition, variables, now),
    do: render(definition.search.headers || [], variables, now)

  @doc """
  The headers of a grab's requests: `download.headers` when the definition sets any, else
  `search.headers`, rendered under `variables`.
  """
  @spec download(map(), Template.variables(), DateTime.t()) ::
          {:ok, [header()]} | {:error, atom()}
  def download(definition, variables, now) do
    case definition.download do
      %{headers: [_ | _] = headers} -> render(headers, variables, now)
      _none -> search(definition, variables, now)
    end
  end

  @doc """
  Renders `headers`, the loader's `{name, values}` pairs, under `variables`. A template limit is
  its own tag (`:regex_limit`, `:filter_output_cap`); any other failure is `:definition_error`.
  """
  @spec render([{String.t(), [String.t() | nil]}], Template.variables(), DateTime.t()) ::
          {:ok, [header()]} | {:error, atom()}
  def render(headers, variables, now) do
    headers
    |> Enum.reduce_while({:ok, []}, fn
      {_name, []}, acc ->
        {:cont, acc}

      {name, [template | _]}, {:ok, acc} ->
        case rendered(name, template || "", variables, now) do
          {:ok, nil} -> {:cont, {:ok, acc}}
          {:ok, header} -> {:cont, {:ok, [header | acc]}}
          error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      error -> error
    end
  end

  defp rendered(name, template, variables, now) do
    cond do
      not Regex.match?(@token, name) ->
        {:error, :definition_error}

      String.downcase(name) in @framing ->
        {:ok, nil}

      true ->
        case Template.render(template, variables, now) do
          {:ok, value} -> value(name, value)
          {:error, reason} when reason in [:regex_limit, :filter_output_cap] -> {:error, reason}
          {:error, _reason} -> {:error, :definition_error}
        end
    end
  end

  @doc "Whether `value` is one Cinder sends as a header value: printable ASCII and the tab."
  @spec value?(String.t()) :: boolean()
  def value?(value) when is_binary(value), do: Regex.match?(@value, value)

  defp value(name, value) do
    if value?(value),
      do: {:ok, {name, value}},
      else: {:error, :definition_error}
  end
end
