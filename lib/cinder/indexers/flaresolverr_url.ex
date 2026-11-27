defmodule Cinder.Indexers.FlareSolverrUrl do
  @moduledoc """
  The one FlareSolverr URL of every Cardigann indexer whose FlareSolverr toggle is on (#1682):
  the `flaresolverr_url` setting (`save: :direct, render: :none` in
  `Cinder.Settings.Registry`), whose inputs live in the indexers page's dialogs and the
  Prowlarr import, outside `/settings`' form.

  `put/1` is its one writer. It trims the value and saves an `http` or `https` URL with a host,
  a port in range and no user info, query or fragment, as a configured indexer's base URL is
  checked (`Cinder.Settings.Shape.service_url?/1`). A blank value clears the setting. Any other
  value is `{:error, :invalid_url}`, with nothing saved.
  """

  alias Cinder.Settings
  alias Cinder.Settings.Shape

  @key "flaresolverr_url"

  @doc "The saved FlareSolverr URL, or nil when none is saved."
  @spec get() :: String.t() | nil
  def get do
    case Settings.get(@key) do
      url when is_binary(url) and url != "" -> url
      _unset -> nil
    end
  end

  @doc "Checks and saves `url`, or clears the setting for a blank one; see the moduledoc."
  @spec put(term()) :: :ok | {:error, :invalid_url}
  def put(url) when is_binary(url) do
    url = String.trim(url)

    cond do
      url == "" -> Settings.delete(@key)
      Shape.service_url?(url) -> Settings.put(@key, url)
      true -> {:error, :invalid_url}
    end
  end

  def put(_url), do: {:error, :invalid_url}

  @doc "Whether `url`, trimmed, is a URL `put/1` saves; a blank one is not."
  @spec valid?(term()) :: boolean()
  def valid?(url) when is_binary(url), do: Shape.service_url?(String.trim(url))
  def valid?(_url), do: false
end
