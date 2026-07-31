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

  @typedoc """
  One media-server account, as read by `c:list_users/0`.

  `id` is the server's own account id: an **integer** for Plex (which Cinder stores as
  `users.plex_id`, so an imported account resolves on "Sign in with Plex") and a **string**
  GUID for Jellyfin (no column yet — there is no Jellyfin sign-in). `email` is `nil` when the
  server reports none; such an account can't be imported, since a Cinder account is keyed by
  its email.
  """
  @type user :: %{
          id: integer() | String.t(),
          email: String.t() | nil,
          username: String.t() | nil
        }

  @doc "The media server's own user accounts, for the admin import on `/users`."
  @callback list_users() :: {:ok, [user()]} | {:error, term()}

  @doc "Resolves the configured impl at runtime (never `compile_env!` — see catalog.ex)."
  def impl, do: Application.fetch_env!(:cinder, :media_server)
end
