defmodule Cinder.Library.MediaServer do
  @moduledoc """
  Behaviour for the media server (Jellyfin / Plex): trigger a library scan.

  `scan/1` takes the library kind (`Cinder.Library.kinds/0`, e.g. `:movies` / `:tv`)
  so a server with separate libraries refreshes the right one after an import.
  Jellyfin's full refresh ignores the kind; Plex maps it to a per-kind section id.
  """

  @callback scan(kind :: atom()) :: :ok | {:error, term()}

  @doc "Lightweight reachability check — `:ok` if the media server answers, else `{:error, reason}`."
  @callback health() :: :ok | {:error, term()}
end
