defmodule Cinder.Accounts.PlexAuth.SignInProbe do
  @moduledoc """
  The `plex_signin` health check: does plex.tv still list the household server for the owner's
  Plex token? Plex sign-in admits a user only when it does (`Cinder.Accounts.PlexAuth.server_access/2`),
  and on 2026-11-05 plex.tv stopped listing it for every account while the local server kept
  answering its `/identity`, so the `media_server` row stayed green (#1204).

  `health/0` reads the token the media server uses (`config :cinder,
  Cinder.Library.MediaServer.Plex, token:`), which belongs to the account that owns the server.
  It needs `account/2` to return an integer `id`, then `server_access/2` to return `:ok`, each
  call bounded with 3-second connect and receive timeouts (`timeouts: :probe`). It does not
  create a PIN, follow the browser callback or see what a shared user sees.

  A failure reads, by `reason/1`:

    * `:not_configured` when `Cinder.Accounts.PlexAuth.configured?/0` is false;
    * `:token_rejected` when plex.tv answered 401 or 403, to `account/2` or to the resource list;
    * `:server_not_listed` when the list does not hold the server's machine id;
    * `{step, reason}` otherwise, `step` being `:account`, `:server_machine_id` or `:server_ids`.
  """
  alias Cinder.Accounts.PlexAuth

  @opts [timeouts: :probe]
  @steps [:account, :server_machine_id, :server_ids]
  # Reasons that name no step: this module's own and those `Cinder.Health.check/1` adds.
  @plain_reasons [:not_configured, :token_rejected, :server_not_listed, :timeout]

  @spec health() :: :ok | {:error, term()}
  def health do
    if PlexAuth.configured?(), do: check(token()), else: {:error, :not_configured}
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
  def reason({:server_access, {:forbidden, _count}}), do: :server_not_listed

  def reason({step, {:plex_tv_status, status}})
      when step in [:account, :server_ids] and status in [401, 403],
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

  defp check(token) do
    with {:ok, _id} <- account(token),
         :ok <- PlexAuth.server_access(token, @opts) do
      :ok
    else
      {:error, reason} -> {:error, reason(reason)}
    end
  end

  defp account(token) do
    case PlexAuth.impl().account(token, @opts) do
      {:ok, %{id: id}} when is_integer(id) -> {:ok, id}
      {:ok, _account} -> {:error, {:account, :unexpected_response}}
      {:error, reason} -> {:error, {:account, reason}}
    end
  end

  defp token do
    :cinder
    |> Application.get_env(Cinder.Library.MediaServer.Plex, [])
    |> Keyword.fetch!(:token)
  end
end
