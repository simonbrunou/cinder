defmodule Cinder.Library.AudiobookServer do
  @moduledoc """
  Behaviour for the Audiobookshelf consumer: request a library scan and check reachability.

  Deliberately **not** a reuse of `Cinder.Library.MediaServer`. That behaviour's `scan/1` is
  parametrized over `Cinder.Library.kinds/0` — the *video* kind subset — and its other three
  callbacks (`list_users/0`, `list_items/1`, `deep_link/1`) exist for the Jellyfin/Plex account
  import and deep-link features on `/users` and the discovery grid, none of which Audiobookshelf
  has an equivalent surface for in this pipeline. Implementing `MediaServer` here would mean
  three no-op/`{:error, :not_supported}` callbacks purely to satisfy a shape that does not fit.
  This behaviour stays as narrow as the one real job: scan after a committed import, and answer
  the settings "Test connection" / `/status` reachability check.
  """

  @doc "Requests a rescan of the configured Audiobookshelf library."
  @callback scan() :: :ok | {:error, term()}

  @doc "Lightweight reachability check — `:ok` if Audiobookshelf answers, else `{:error, reason}`."
  @callback health() :: :ok | {:error, term()}

  @doc "Resolves the configured impl at runtime (never `compile_env!` — see catalog.ex)."
  def impl, do: Application.fetch_env!(:cinder, :audiobook_server)
end
