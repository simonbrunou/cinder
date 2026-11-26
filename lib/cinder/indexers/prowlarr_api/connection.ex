defmodule Cinder.Indexers.ProwlarrApi.Connection do
  @moduledoc """
  The Prowlarr URL and API key one run of reads uses (`Cinder.Indexers.ProwlarrApi.connection/0`).
  The key is redacted from `inspect/1`.
  """

  @derive {Inspect, except: [:api_key]}
  # `url`, not `base_url`: `test/code_health/service_base_url_fragment_test.exs` reads a
  # `base_url` pair as a request's base URL, and the adapter cuts this one's fragment where it
  # builds the request.
  @enforce_keys [:url, :api_key]
  defstruct [:url, :api_key]

  @type t :: %__MODULE__{url: String.t(), api_key: String.t()}
end
