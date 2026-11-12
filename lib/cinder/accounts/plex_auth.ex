defmodule Cinder.Accounts.PlexAuth do
  @moduledoc """
  Behaviour for "Sign in with Plex" (PIN-based OAuth against plex.tv): create a
  PIN, poll it for a linked auth token, fetch the signed-in Plex account, and
  list the ids of the resources plex.tv lists for that account (`resource_ids/2`), which
  `server_access/2` matches against the household server's machine id (`server_machine_id/1`).
  Real impl: `Cinder.Accounts.PlexAuth.HTTP`.

  `watchlist/1` rides along here because it is the same plex.tv account API and the
  same per-user token — the watchlist lives on the Plex ACCOUNT, not on the household's
  server, so the media-server behaviour is the wrong seam for it.
  """

  alias Cinder.Util

  @callback create_pin() :: {:ok, %{id: integer(), code: String.t()}} | {:error, term()}
  @callback check_pin(integer()) :: {:ok, String.t()} | {:error, :pending | term()}
  @typedoc """
  Options of the calls the sign-in gate and the `plex_signin` health check share. `[]` keeps
  sign-in's bounds: a 15-second receive timeout on plex.tv, 5 seconds on the local `/identity`.
  `timeouts: :probe` bounds each call with 3-second connect and receive timeouts, as
  `Cinder.Health` asks of every `health/0`.
  """
  @type call_opts :: [timeouts: :probe]

  @callback account(String.t(), call_opts()) ::
              {:ok, %{id: integer(), email: String.t() | nil, username: String.t() | nil}}
              | {:error, term()}
  @doc """
  The `clientIdentifier` of every resource plex.tv lists for the account owning `token`, in
  plex.tv's order, whatever its `product`, `provides` or `owned` say. A resource without a
  non-empty string id is dropped.
  """
  @callback resource_ids(String.t(), call_opts()) :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  The configured local Plex server's machine id, read from its `/identity`. Anything but a
  non-empty string is `{:error, :unexpected_response}`.
  """
  @callback server_machine_id(call_opts()) :: {:ok, String.t()} | {:error, term()}

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

  @doc """
  The Plex sign-in gate: `:ok` when the configured Plex server's machine id
  (`server_machine_id/1`) is among the resource ids plex.tv lists for the account owning
  `token` (`resource_ids/2`), whether that account owns the server or was shared it. Both
  `CinderWeb.PlexAuthController` intents and the `plex_signin` health check
  (`Cinder.Accounts.PlexAuth.SignInProbe`) call it; it reaches the server and plex.tv through
  `impl/0`, so tests drive it with Mox.

  A refusal names the step that refused:

    * `{:error, {:server_machine_id, reason}}` when the server's id could not be read;
    * `{:error, {:server_ids, reason}}` when plex.tv did not return the list;
    * `{:error, {:server_access, {:forbidden, count}}}` when the list does not hold the id;
      `count` is how many ids it held, for the sign-in log line. The ids themselves are never
      returned.

  `opts` goes to both calls (`t:call_opts/0`).
  """
  @spec server_access(String.t(), call_opts()) ::
          :ok
          | {:error, {:server_machine_id | :server_ids, term()}}
          | {:error, {:server_access, {:forbidden, non_neg_integer()}}}
  def server_access(token, opts \\ []) do
    with {:ok, server_id} <- step(:server_machine_id, impl().server_machine_id(opts)),
         {:ok, ids} <- step(:server_ids, impl().resource_ids(token, opts)) do
      if server_id in ids,
        do: :ok,
        else: {:error, {:server_access, {:forbidden, length(ids)}}}
    end
  end

  defp step(_step, {:ok, _value} = ok), do: ok
  defp step(step, {:error, reason}), do: {:error, {step, reason}}
  defp step(step, other), do: {:error, {step, other}}

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
