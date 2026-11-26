defmodule Cinder.Indexers.ProwlarrImport.Preview do
  @moduledoc """
  What `Cinder.Indexers.ProwlarrImport.preview/0` read: one `Cinder.Indexers.ProwlarrImport.Row`
  per Prowlarr indexer, in the order a commit creates them (priority, then Prowlarr id), and
  whether Prowlarr's global proxy is on.

  `mac_key` is the random key made for this preview, under which each row's plan holds an HMAC
  of the secret values Prowlarr answered for it, and `source_mac` the HMAC of the Prowlarr URL
  and key the reads used. Both are redacted from `inspect/1`; no secret value is kept.
  """

  @derive {Inspect, except: [:mac_key, :source_mac]}
  @enforce_keys [:rows, :global_proxy, :mac_key, :source_mac]
  defstruct [:rows, :global_proxy, :mac_key, :source_mac]

  @type t :: %__MODULE__{
          rows: [Cinder.Indexers.ProwlarrImport.Row.t()],
          global_proxy: boolean(),
          mac_key: binary(),
          source_mac: binary()
        }
end
