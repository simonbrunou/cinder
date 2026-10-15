defmodule Cinder.Library.MediaServer do
  @moduledoc """
  Behaviour for the media server (Jellyfin / Plex): trigger a library scan and read its catalog.

  `scan/1` takes the library kind (`Cinder.Library.kinds/0`, e.g. `:movies` / `:tv`)
  so a server with separate libraries refreshes the right one after an import.
  Jellyfin's full refresh ignores the kind; Plex maps it to a per-kind section id.
  """

  @callback scan(kind :: atom()) :: :ok | {:error, term()}

  @doc "Lightweight reachability check — `:ok` if the media server answers, else `{:error, reason}`."
  @callback health() :: :ok | {:error, term()}

  @typedoc """
  One media-server account, as read by `c:list_users/0`.

  `id` is the server's own account id: an **integer** for Plex (stored as `users.plex_id`) and
  a **string** GUID for Jellyfin (stored as `users.jellyfin_user_id`), so either way an
  imported account resolves on the matching media-server sign-in rather than creating a second
  one. `email` is `nil` when the server reports none: a Plex entry like that isn't importable
  (Plex has an email field, so a missing one means unknown), while Jellyfin exposes no email at
  all and the import synthesizes one — see `Cinder.Accounts.import_media_server_users/2`.
  """
  @type user :: %{
          id: integer() | String.t(),
          email: String.t() | nil,
          username: String.t() | nil
        }

  @doc "The media server's own user accounts, for the admin import on `/users`."
  @callback list_users() :: {:ok, [user()]} | {:error, term()}

  @typedoc "One exact provider-ID match in a configured movie or TV library."
  @type item :: %{
          id: String.t(),
          tmdb_id: pos_integer(),
          deep_link: String.t() | nil
        }

  @doc "Lists a complete, bounded inventory for one configured library kind."
  @callback list_items(kind :: atom()) :: {:ok, [item()]} | {:error, term()}

  @typedoc """
  One season present in the configured TV library: the show's exact TMDB match, its opaque
  item id (for `c:deep_link/1`), and how many episodes the server holds for the season.
  """
  @type season :: %{
          item_id: String.t(),
          tmdb_id: pos_integer(),
          season_number: pos_integer(),
          episode_count: non_neg_integer()
        }

  @doc """
  Lists a complete, bounded season inventory for the TV library, specials excluded. Like
  `c:list_items/1`, any partial read is an error rather than a short list.
  """
  @callback list_seasons() :: {:ok, [season()]} | {:error, term()}

  @doc "Builds a browser deep link for one opaque item id, without network I/O."
  @callback deep_link(item_id :: String.t()) :: String.t() | nil

  @doc "Resolves the configured impl at runtime (never `compile_env!` — see catalog.ex)."
  def impl, do: Application.fetch_env!(:cinder, :media_server)
end
