defmodule Cinder.Download.Client do
  @moduledoc """
  Behaviour for the download client (qBittorrent): add a release, report status.

  Fleshed out in Phase 3.
  """

  @callback add(release :: map()) :: {:ok, id :: String.t()} | {:error, term()}
  @callback status(id :: String.t()) :: {:ok, map()} | {:error, term()}
end
