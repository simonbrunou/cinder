defmodule Cinder.Disk.Prober do
  @moduledoc """
  The seam through which the free-space guards read a filesystem's free/total bytes. `Cinder.Disk`
  is the production impl (it runs a bounded, path-scoped `df` probe); `config/test.exs` points
  `:disk_prober` at a permissive stub so tests never touch the real filesystem. Resolved at runtime,
  other external-service seams (`:filesystem`, `:media_server`).
  """

  @callback stats(path :: String.t()) ::
              {:ok, Cinder.Disk.stats()} | {:error, term()}
end
