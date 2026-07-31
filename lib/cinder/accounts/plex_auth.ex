defmodule Cinder.Accounts.PlexAuth do
  @moduledoc """
  Behaviour for "Sign in with Plex" (PIN-based OAuth against plex.tv): create a
  PIN, poll it for a linked auth token, fetch the signed-in Plex account, and
  check which servers that account can reach. Real impl:
  `Cinder.Accounts.PlexAuth.HTTP`.

  `watchlist/1` rides along here because it is the same plex.tv account API and the
  same per-user token — the watchlist lives on the Plex ACCOUNT, not on the household's
  server, so the media-server behaviour is the wrong seam for it.
  """

  alias Cinder.Util

  @callback create_pin() :: {:ok, %{id: integer(), code: String.t()}} | {:error, term()}
  @callback check_pin(integer()) :: {:ok, String.t()} | {:error, :pending | term()}
  @callback account(String.t()) ::
              {:ok, %{id: integer(), email: String.t() | nil, username: String.t() | nil}}
              | {:error, term()}
  @callback server_ids(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback server_machine_id() :: {:ok, String.t()} | {:error, term()}

  @typedoc """
  One entry off a Plex account's watchlist, already resolved to a TMDB id (entries plex.tv
  cannot map to one are dropped by the impl — there is nothing Cinder could request).
  `type` is plex.tv's own discriminator, `"movie"` or `"show"`.
  """
  @type watchlist_entry :: %{
          tmdb_id: integer(),
          type: String.t(),
          title: String.t() | nil,
          year: integer() | nil
        }

  @doc """
  The watchlist of the account owning `token`. `{:error, :unauthorized}` specifically means
  plex.tv rejected the token (expired/revoked) — the caller uses it to switch that one user's
  sync off rather than retrying forever.
  """
  @callback watchlist(String.t()) :: {:ok, [watchlist_entry()]} | {:error, :unauthorized | term()}

  @doc "True when a Plex media server is configured (non-blank `:url` and `:token`)."
  def configured? do
    config = Application.get_env(:cinder, Cinder.Library.MediaServer.Plex, [])
    Util.present?(config[:url]) and Util.present?(config[:token])
  end

  @doc "Builds the `app.plex.tv/auth#?...` URL the browser is redirected to to link a PIN."
  def auth_url(code, forward_url) do
    "https://app.plex.tv/auth#?clientID=#{URI.encode_www_form(client_identifier())}" <>
      "&code=#{URI.encode_www_form(code)}" <>
      "&context%5Bdevice%5D%5Bproduct%5D=Cinder" <>
      "&forwardUrl=#{URI.encode_www_form(forward_url)}"
  end

  @doc """
  A stable per-install UUID sent as `X-Plex-Client-Identifier` on every plex.tv call.
  Persisted with the bare `Cinder.Settings` KV pattern (no registry entry, like
  `setup_complete`) — generated once, on first use.
  """
  def client_identifier do
    Cinder.Settings.get("plex_client_identifier") || generate_client_identifier()
  end

  defp generate_client_identifier do
    id = Ecto.UUID.generate()
    Cinder.Settings.put("plex_client_identifier", id)
    id
  end

  @doc "Resolves the configured impl at runtime (never `compile_env!` — see catalog.ex)."
  def impl, do: Application.fetch_env!(:cinder, :plex_auth)
end
