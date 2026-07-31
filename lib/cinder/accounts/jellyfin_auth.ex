defmodule Cinder.Accounts.JellyfinAuth do
  @moduledoc """
  Behaviour for "Sign in with Jellyfin": one `POST {jellyfin_url}/Users/AuthenticateByName`
  against the household's OWN server, which answers with the Jellyfin user id and display name.
  There is no OAuth dance, so that single call is the whole handshake. Real impl:
  `Cinder.Accounts.JellyfinAuth.HTTP`.

  Authenticating against the household's own server IS the authorization check — unlike Plex,
  whose plex.tv account is global and needs a separate "can this account reach our server?"
  probe (`PlexAuth.server_ids/1`), only someone the configured server already knows can succeed
  here.
  """

  alias Cinder.Util

  @callback authenticate(String.t(), String.t()) ::
              {:ok, %{id: String.t(), name: String.t() | nil}} | {:error, term()}

  @doc """
  True when a Jellyfin server is configured (non-blank `:url`).

  Deliberately does not require the media-server `:api_key` the way `PlexAuth.configured?/0`
  requires Plex's token: `AuthenticateByName` takes no API key (the submitted credentials are
  the authentication), so a household that points Cinder at Jellyfin only as an identity
  provider still gets the button.
  """
  def configured? do
    config = Application.get_env(:cinder, Cinder.Library.MediaServer.Jellyfin, [])
    Util.present?(config[:url])
  end

  @doc """
  A stable per-install UUID sent as `DeviceId` in the `x-emby-authorization` header; Jellyfin
  keys the device session it opens off it. Persisted with the bare `Cinder.Settings` KV pattern
  (no registry entry), exactly like `PlexAuth.client_identifier/0` — generated once, on first
  use.
  """
  def device_id do
    Cinder.Settings.get("jellyfin_device_id") || generate_device_id()
  end

  defp generate_device_id do
    id = Ecto.UUID.generate()
    Cinder.Settings.put("jellyfin_device_id", id)
    id
  end

  @doc "Resolves the configured impl at runtime (never `compile_env!` — see catalog.ex)."
  def impl, do: Application.fetch_env!(:cinder, :jellyfin_auth)
end
