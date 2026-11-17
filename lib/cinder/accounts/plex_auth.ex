defmodule Cinder.Accounts.PlexAuth do
  @moduledoc """
  Behaviour for "Sign in with Plex" (PIN-based OAuth against plex.tv): create a
  PIN, poll it for a linked auth token, fetch the signed-in Plex account, and read who the
  household server is shared with (`server_share_ids/3`), which `server_access/2` checks the
  signing-in account against. Real impl: `Cinder.Accounts.PlexAuth.HTTP`.

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
  The plex.tv account ids the household server is shared with, read with the token of the
  account that owns the server (`owner_token`) from plex.tv's share list for `machine_id`
  (`GET /api/servers/<machine id>/shared_servers`), in plex.tv's order. The gate rests on the
  premise of #1212's brief: sharing on Plex starts from the owner's account, so an account cannot
  put itself on this list the way a device can report any `clientIdentifier` to plex.tv.
  """
  @callback server_share_ids(String.t(), String.t(), call_opts()) ::
              {:ok, [pos_integer()]} | {:error, term()}

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
  The Plex sign-in gate: `:ok` when `plex_id`, the plex.tv id of the account signing in, is the
  id of the account that owns the household server, or an id on that server's share list
  (`share_ids/1`). The owner is the account whose token the media server uses
  (`config :cinder, Cinder.Library.MediaServer.Plex, token:`), read with `account/2`. Both
  `CinderWeb.PlexAuthController` intents call it, and the `plex_signin` health check
  (`Cinder.Accounts.PlexAuth.SignInProbe`) calls `owner_id/1` and `share_ids/1`, its two halves.
  It reaches the server and plex.tv through `impl/0`, so tests drive it with Mox.

  An id that is not an integer is never admitted. The owner's id ends the check, so the share
  list is read only for an account that is not the owner's.

  A refusal names the step that refused:

    * `{:error, {:owner_account, reason}}` when the owner's account could not be read, or no
      token is configured (`:not_configured`);
    * `{:error, {:server_machine_id, reason}}` when the server's id could not be read;
    * `{:error, {:server_shares, reason}}` when plex.tv did not return the share list;
    * `{:error, {:server_access, {:forbidden, count}}}` when the account is neither the owner
      nor on the list; `count` is how many ids the list held, for the sign-in log line. The ids
      themselves are never returned.

  `opts` goes to every call (`t:call_opts/0`).
  """
  @spec server_access(term(), call_opts()) ::
          :ok
          | {:error, {:owner_account | :server_machine_id | :server_shares, term()}}
          | {:error, {:server_access, {:forbidden, non_neg_integer()}}}
  def server_access(plex_id, opts \\ []) do
    with {:ok, owner_id} <- owner_id(opts) do
      if is_integer(plex_id) and plex_id == owner_id,
        do: :ok,
        else: shared_access(plex_id, opts)
    end
  end

  defp shared_access(plex_id, opts) do
    with {:ok, ids} <- share_ids(opts) do
      if is_integer(plex_id) and plex_id in ids,
        do: :ok,
        else: {:error, {:server_access, {:forbidden, length(ids)}}}
    end
  end

  @doc """
  The plex.tv id of the account that owns the household server: `account/2` on the configured
  media server token. Anything but a positive integer id is
  `{:error, {:owner_account, :unexpected_response}}`; a blank token is
  `{:error, {:owner_account, :not_configured}}`.
  """
  @spec owner_id(call_opts()) :: {:ok, pos_integer()} | {:error, {:owner_account, term()}}
  def owner_id(opts \\ []) do
    with {:ok, token} <- owner_token(:owner_account) do
      case impl().account(token, opts) do
        {:ok, %{id: id}} when is_integer(id) and id > 0 -> {:ok, id}
        {:ok, _account} -> {:error, {:owner_account, :unexpected_response}}
        other -> step(:owner_account, other)
      end
    end
  end

  @doc """
  The ids on the household server's share list: the server's machine id
  (`server_machine_id/1`), then `server_share_ids/3` with the configured media server token.
  """
  @spec share_ids(call_opts()) ::
          {:ok, [pos_integer()]} | {:error, {:server_machine_id | :server_shares, term()}}
  def share_ids(opts \\ []) do
    with {:ok, token} <- owner_token(:server_shares),
         {:ok, server_id} <- step(:server_machine_id, impl().server_machine_id(opts)) do
      step(:server_shares, impl().server_share_ids(token, server_id, opts))
    end
  end

  defp owner_token(step) do
    config = Application.get_env(:cinder, Cinder.Library.MediaServer.Plex, [])

    if Util.present?(config[:token]),
      do: {:ok, config[:token]},
      else: {:error, {step, :not_configured}}
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
