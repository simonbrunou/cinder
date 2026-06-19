defmodule Cinder.Download.Client do
  @moduledoc """
  Behaviour for the download client (qBittorrent): add a release, report status.

  Fleshed out in Phase 3.
  """

  @callback add(release :: map()) :: {:ok, id :: String.t()} | {:error, term()}

  @doc """
  Reports the status of a download by id. The `:ok` map carries at least
  `:state` (`:downloading | :completed | :error`) and `:progress` (float). For a
  `:completed` download it also carries `:content_path` — the on-disk path the
  importer hardlinks from; the poller will not advance a completed download to
  `:downloaded` until `:content_path` is present.
  """
  @callback status(id :: String.t()) :: {:ok, map()} | {:error, term()}
end
