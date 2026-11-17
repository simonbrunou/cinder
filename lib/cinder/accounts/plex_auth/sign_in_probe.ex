defmodule Cinder.Accounts.PlexAuth.SignInProbe do
  @moduledoc """
  The `plex_signin` health check: can Cinder still read what Plex sign-in admits a user by? The
  gate (`Cinder.Accounts.PlexAuth.server_access/2`) reads the account that owns the Plex token
  and the household server's share list. On 2026-11-05 plex.tv stopped listing the household
  server for every account, which the gate then read, and every Plex sign-in was refused while
  the local server kept answering its `/identity`, so the `media_server` row stayed green (#1204).

  `health/0` reads the token the media server uses (`config :cinder,
  Cinder.Library.MediaServer.Plex, token:`), which belongs to the account that owns the server.
  It needs `PlexAuth.owner_id/1` to return that account's id, then `PlexAuth.share_ids/1` to
  return the share list, three calls in all (the account, the server's `/identity`, the list),
  each bounded with 3-second connect and receive timeouts (`timeouts: :probe`). The gate admits
  the owner without reading the list, so the check reads it on its own. It does not create a PIN,
  follow the browser callback or see what a shared user sees, and an empty list passes.

  A failure reads, by `reason/1`:

    * `:not_configured` when `Cinder.Accounts.PlexAuth.configured?/0` is false;
    * `:token_rejected` when plex.tv answered 401 or 403, to the account or to the share list;
    * `{step, reason}` otherwise, `step` being `:owner_account`, `:server_machine_id` or
      `:server_shares`.
  """
  alias Cinder.Accounts.PlexAuth

  @opts [timeouts: :probe]
  @steps [:owner_account, :server_machine_id, :server_shares]
  # Reasons that name no step: this module's own and those `Cinder.Health.check/1` adds.
  @plain_reasons [:not_configured, :token_rejected, :timeout]

  @spec health() :: :ok | {:error, term()}
  def health do
    if PlexAuth.configured?(), do: check(), else: {:error, :not_configured}
  end

  @doc """
  Cuts a failure of this check, or of `Cinder.Health.check/1` running it, down to a closed set:
  the atoms in the moduledoc, `:timeout`, and `{step, reason}` where `reason` is an atom, an
  HTTP status as `{:plex_tv_status, n}`, or `:error`. An exception becomes `{:exception, module}`,
  anything else `:error`. A notice or a log line can then carry it whole: the terms an HTTP
  failure brings back can hold the request, and the `x-plex-token` header with it.
  `reason(reason(r)) == reason(r)`.
  """
  @spec reason(term()) :: term()
  def reason(reason) when reason in @plain_reasons, do: reason

  def reason({step, {:plex_tv_status, status}})
      when step in [:owner_account, :server_shares] and status in [401, 403],
      do: :token_rejected

  def reason({step, {:plex_tv_status, status}} = reason)
      when step in @steps and is_integer(status),
      do: reason

  def reason({step, reason}) when step in @steps and is_atom(reason), do: {step, reason}

  # `%Req.TransportError{reason: :econnrefused}` and the like keep only their atom.
  def reason({step, %{__exception__: true, reason: reason}})
      when step in @steps and is_atom(reason),
      do: {step, reason}

  def reason({step, _reason}) when step in @steps, do: {step, :error}
  def reason({:exception, module} = reason) when is_atom(module), do: reason
  def reason(%module{__exception__: true}), do: {:exception, module}
  def reason(_reason), do: :error

  defp check do
    with {:ok, _id} <- PlexAuth.owner_id(@opts),
         {:ok, _ids} <- PlexAuth.share_ids(@opts) do
      :ok
    else
      {:error, reason} -> {:error, reason(reason)}
    end
  end
end
