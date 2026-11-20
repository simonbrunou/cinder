defmodule Cinder.Accounts.Passkeys do
  @moduledoc """
  Passkeys (WebAuthn credentials) as a sign-in method next to password, Plex, Jellyfin and OIDC,
  verified with `wax_` (#1560). The functions that list, export, register, rename or delete
  passkeys take their owner and touch only that owner's rows; `authenticate/3` finds the owner
  from the credential id the browser sends.

  Two ceremonies, each with a single-use challenge from `Cinder.Accounts.PasskeyChallenges`:

    * registration: `registration_options/2` stores a challenge for `{:register, user_id}` and
      returns the options for `navigator.credentials.create`; `register/4` takes that challenge,
      verifies the browser's answer with `Wax.register/3` and stores the credential id and COSE
      public key. Attestation is `none`: Cinder checks no authenticator model, and leaves
      `wax_`'s `:update_metadata` unset, so it never fetches the FIDO metadata.
    * sign-in: `sign_in_options/2` stores a challenge for `{:sign_in, signed_in_user_id}` and
      returns the options for `navigator.credentials.get`, with no `allowCredentials`: the
      browser offers the passkeys it holds for the site (discoverable credentials).
      `authenticate/3` takes that challenge and answers the passkey's owner.

  Both ceremonies require user verification (a PIN or biometric on the authenticator), since a
  passkey is the whole sign-in, not a second factor, and refreshes the sudo window. Registration
  also requires a discoverable (resident) credential, since sign-in asks for no email first.

  `authenticate/3` takes the challenge out of the store first, so every attempt spends it. Then,
  before it updates the stored passkey, it refuses an assertion whose challenge is unknown,
  spent, expired or for another session identity; an unknown credential; one Wax rejects (bad
  signature, other origin or RP ID, no user verification); a user handle other than the owner's;
  a passkey of another user than the one signed in (`:other_user`). Then it advances the stored
  sign count in one conditional `UPDATE` and refuses when no row moved
  (`:sign_count_regression`): the counter must grow, except that a credential whose stored and
  reported counts are both 0 (many passkey providers never count) passes.

  Each refusal is `{:error, reason}` with `reason` an atom, for `CinderWeb.SignInRefusal`. No
  function logs a credential id, public key, challenge or user handle: the queries that carry one
  run with `log: false`, and the schemas redact those fields.
  """
  import Ecto.Query

  alias Cinder.Accounts.PasskeyChallenges
  alias Cinder.Accounts.User
  alias Cinder.Accounts.UserPasskey
  alias Cinder.Repo

  @typedoc "The relying party: its RP ID (a host name) and the origin browsers sign for."
  @type rp :: %{id: String.t(), origin: String.t()}

  # Offered at registration, in order of preference: ES256, EdDSA, RS256.
  @algorithms [-7, -8, -257]

  @doc "The user's passkeys, oldest first."
  @spec list(User.t()) :: [UserPasskey.t()]
  def list(%User{id: user_id}) do
    Repo.all(
      from p in UserPasskey,
        where: p.user_id == ^user_id,
        order_by: [asc: p.inserted_at, asc: p.id]
    )
  end

  @doc "What `Cinder.Accounts.export_user_data/1` lists of each passkey: never key material."
  @spec export(User.t()) :: [map()]
  def export(%User{} = user) do
    Enum.map(user |> list(), fn passkey ->
      %{
        name: passkey.name,
        inserted_at: iso(passkey.inserted_at),
        last_used_at: iso(passkey.last_used_at)
      }
    end)
  end

  @doc "Renames one of the user's own passkeys."
  @spec rename(User.t(), integer(), map()) ::
          {:ok, UserPasskey.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def rename(%User{id: user_id}, passkey_id, attrs) when is_integer(passkey_id) do
    case Repo.get_by(UserPasskey, id: passkey_id, user_id: user_id) do
      nil -> {:error, :not_found}
      passkey -> passkey |> UserPasskey.rename_changeset(attrs) |> Repo.update()
    end
  end

  @doc "Deletes one of the user's own passkeys."
  @spec delete(User.t(), integer()) :: :ok | {:error, :not_found}
  def delete(%User{id: user_id}, passkey_id) when is_integer(passkey_id) do
    case Repo.delete_all(
           from p in UserPasskey, where: p.id == ^passkey_id and p.user_id == ^user_id
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  @doc """
  Starts a registration: stores a challenge for this user and returns its handle with the
  `publicKey` options for `navigator.credentials.create` (binary fields base64url-encoded).
  """
  @spec registration_options(User.t(), rp()) ::
          {:ok, %{handle: String.t(), options: map()}} | {:error, atom()}
  def registration_options(%User{} = user, rp) do
    challenge =
      Wax.new_registration_challenge(
        origin: rp.origin,
        rp_id: rp.id,
        attestation: "none",
        user_verification: "required",
        verify_trust_root: false,
        timeout: timeout_seconds()
      )

    with {:ok, user_handle} <- ensure_user_handle(user),
         {:ok, handle} <- PasskeyChallenges.put(challenge, {:register, user.id}) do
      {:ok,
       %{
         handle: handle,
         options: %{
           challenge: b64(challenge.bytes),
           rp: %{id: rp.id, name: "Cinder"},
           user: %{id: b64(user_handle), name: user.email, displayName: user.email},
           pubKeyCredParams: Enum.map(@algorithms, &%{type: "public-key", alg: &1}),
           timeout: PasskeyChallenges.ttl_ms(),
           attestation: "none",
           authenticatorSelection: %{
             residentKey: "required",
             requireResidentKey: true,
             userVerification: "required"
           },
           excludeCredentials:
             Enum.map(list(user), &%{type: "public-key", id: b64(&1.credential_id)})
         }
       }}
    end
  end

  @doc """
  Completes a registration: takes the challenge stored under `handle` for this user, verifies
  the browser's `response` (`attestationObject` and `clientDataJSON`, base64url) and stores the
  credential under `name`.
  """
  @spec register(User.t(), term(), term(), term()) ::
          {:ok, UserPasskey.t()} | {:error, atom() | Ecto.Changeset.t()}
  def register(%User{} = user, handle, response, name) do
    with {:ok, challenge} <- PasskeyChallenges.take(handle, {:register, user.id}),
         {:ok, attestation_object, client_data} <- decode_attestation(response),
         :ok <- same_origin_only(client_data),
         {:ok, {auth_data, _attestation}} <-
           wax(fn -> Wax.register(attestation_object, client_data, challenge) end),
         {:ok, credential_id, cose_key} <- attested_credential(auth_data) do
      %UserPasskey{}
      |> UserPasskey.create_changeset(%{
        credential_id: credential_id,
        public_key: :erlang.term_to_binary(cose_key),
        sign_count: auth_data.sign_count,
        user_id: user.id,
        name: if(is_binary(name), do: name, else: "")
      })
      |> Repo.insert(log: false)
      |> case do
        {:ok, passkey} -> {:ok, passkey}
        {:error, changeset} -> registration_error(changeset)
      end
    end
  end

  @doc """
  Starts a sign-in: stores a challenge bound to the session's identity (`signed_in_user_id`,
  `nil` for a signed-out visitor) and returns its handle with the `publicKey` options for
  `navigator.credentials.get`.
  """
  @spec sign_in_options(rp(), integer() | nil) ::
          {:ok, %{handle: String.t(), options: map()}} | {:error, atom()}
  def sign_in_options(rp, signed_in_user_id) do
    challenge =
      Wax.new_authentication_challenge(
        origin: rp.origin,
        rp_id: rp.id,
        user_verification: "required",
        timeout: timeout_seconds()
      )

    with {:ok, handle} <- PasskeyChallenges.put(challenge, {:sign_in, signed_in_user_id}) do
      {:ok,
       %{
         handle: handle,
         options: %{
           challenge: b64(challenge.bytes),
           rpId: rp.id,
           timeout: PasskeyChallenges.ttl_ms(),
           userVerification: "required"
         }
       }}
    end
  end

  @doc "Drops the challenge stored under `handle` without verifying anything."
  @spec discard(term()) :: :ok
  def discard(handle) do
    PasskeyChallenges.discard(handle)
    :ok
  end

  @doc """
  Completes a sign-in: takes the challenge stored under `handle`, verifies the browser's
  `assertion` (`id`, `authenticatorData`, `clientDataJSON`, `signature`, `userHandle`, each
  base64url) and answers the passkey's owner. See the moduledoc for each refusal.
  """
  @spec authenticate(term(), integer() | nil, term()) :: {:ok, User.t()} | {:error, atom()}
  def authenticate(handle, signed_in_user_id, assertion) do
    with {:ok, challenge} <- PasskeyChallenges.take(handle, {:sign_in, signed_in_user_id}),
         {:ok, fields} <- decode_assertion(assertion),
         :ok <- same_origin_only(fields.client_data),
         {:ok, passkey} <- fetch_passkey(fields.id),
         {:ok, cose_key} <- decode_public_key(passkey.public_key),
         {:ok, auth_data} <-
           wax(fn ->
             Wax.authenticate(
               fields.id,
               fields.authenticator_data,
               fields.signature,
               fields.client_data,
               challenge,
               [{passkey.credential_id, cose_key}]
             )
           end),
         :ok <- owner_handle(fields.user_handle, passkey.user),
         :ok <- signed_in_as_owner(signed_in_user_id, passkey.user_id),
         :ok <- advance_sign_count(passkey, auth_data.sign_count) do
      {:ok, passkey.user}
    end
  end

  # -- registration helpers --------------------------------------------------------------------

  # The user handle is set once, by the first registration-options request (before any passkey
  # exists), in one conditional UPDATE: two requests racing each write only into a NULL column,
  # so both read back the same handle.
  defp ensure_user_handle(%User{id: user_id}) do
    candidate = :crypto.strong_rand_bytes(32)

    Repo.update_all(
      from(u in User, where: u.id == ^user_id and is_nil(u.passkey_handle)),
      [set: [passkey_handle: candidate]],
      log: false
    )

    case Repo.one(from(u in User, where: u.id == ^user_id, select: u.passkey_handle), log: false) do
      handle when is_binary(handle) -> {:ok, handle}
      nil -> {:error, :unknown_user}
    end
  end

  defp decode_attestation(%{"attestationObject" => object, "clientDataJSON" => client_data}) do
    with {:ok, object} <- unb64(object),
         {:ok, client_data} <- unb64(client_data) do
      {:ok, object, client_data}
    end
  end

  defp decode_attestation(_response), do: {:error, :malformed}

  defp attested_credential(%Wax.AuthenticatorData{
         attested_credential_data: %{credential_id: id, credential_public_key: %{3 => alg} = key}
       })
       when is_binary(id) and byte_size(id) in 1..1023 and alg in @algorithms,
       do: {:ok, id, key}

  defp attested_credential(_auth_data), do: {:error, :unsupported_credential}

  defp registration_error(changeset) do
    if Keyword.has_key?(changeset.errors, :credential_id),
      do: {:error, :credential_taken},
      else: {:error, changeset}
  end

  # -- sign-in helpers -------------------------------------------------------------------------

  defp decode_assertion(%{
         "id" => id,
         "authenticatorData" => authenticator_data,
         "clientDataJSON" => client_data,
         "signature" => signature,
         "userHandle" => user_handle
       }) do
    with {:ok, id} <- unb64(id),
         {:ok, authenticator_data} <- unb64(authenticator_data),
         {:ok, client_data} <- unb64(client_data),
         {:ok, signature} <- unb64(signature),
         {:ok, user_handle} <- unb64(user_handle) do
      {:ok,
       %{
         id: id,
         authenticator_data: authenticator_data,
         client_data: client_data,
         signature: signature,
         user_handle: user_handle
       }}
    end
  end

  defp decode_assertion(_assertion), do: {:error, :malformed}

  defp fetch_passkey(credential_id) do
    query =
      from p in UserPasskey, where: p.credential_id == ^credential_id, preload: [:user]

    case Repo.one(query, log: false) do
      nil -> {:error, :unknown_credential}
      passkey -> {:ok, passkey}
    end
  end

  defp decode_public_key(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      %{} = key -> {:ok, key}
      _other -> {:error, :bad_public_key}
    end
  rescue
    ArgumentError -> {:error, :bad_public_key}
  end

  # A discoverable credential always returns the user handle it was created with. A passkey
  # that answers another handle, or none, is not the one this user registered.
  defp owner_handle(handle, %User{passkey_handle: handle}) when is_binary(handle), do: :ok
  defp owner_handle(_handle, _owner), do: {:error, :user_handle_mismatch}

  defp signed_in_as_owner(nil, _owner_id), do: :ok
  defp signed_in_as_owner(owner_id, owner_id), do: :ok
  defp signed_in_as_owner(_signed_in, _owner_id), do: {:error, :other_user}

  defp advance_sign_count(%UserPasskey{id: id}, count) do
    now = DateTime.utc_now(:second)

    query =
      from p in UserPasskey,
        where: p.id == ^id and (p.sign_count < ^count or (p.sign_count == 0 and ^count == 0))

    case Repo.update_all(query, set: [sign_count: count, last_used_at: now]) do
      {1, _} -> :ok
      {0, _} -> {:error, :sign_count_regression}
    end
  end

  # -- shared ----------------------------------------------------------------------------------

  # Wax checks the client data's type, challenge and origin, but not `crossOrigin` or
  # `topOrigin`: an assertion made inside another site's iframe carries them, and Cinder never
  # asks for one there.
  defp same_origin_only(client_data) do
    case Jason.decode(client_data) do
      {:ok, %{"crossOrigin" => true}} -> {:error, :cross_origin}
      {:ok, %{"topOrigin" => _}} -> {:error, :cross_origin}
      {:ok, %{}} -> :ok
      _other -> {:error, :malformed}
    end
  end

  # Wax parses some inputs with raising calls (`Base.url_decode64!/2` on the client data's
  # challenge, a `case` with no fallback on its type, a match on the attestation map), so a
  # malformed answer would crash the request. It is refused as `:malformed` instead.
  defp wax(fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, error} -> {:error, wax_reason(error)}
    end
  rescue
    _error -> {:error, :malformed}
  end

  defp wax_reason(%Wax.ExpiredChallengeError{}), do: :expired
  defp wax_reason(%Wax.InvalidSignatureError{}), do: :bad_signature
  defp wax_reason(%Wax.InvalidAuthenticatorDataError{}), do: :malformed
  defp wax_reason(%Wax.InvalidCBORError{}), do: :malformed

  defp wax_reason(%Wax.InvalidClientDataError{reason: reason})
       when is_atom(reason) and not is_nil(reason),
       do: reason

  defp wax_reason(_error), do: :rejected

  defp unb64(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :malformed}
    end
  end

  defp unb64(_value), do: {:error, :malformed}

  defp timeout_seconds, do: div(PasskeyChallenges.ttl_ms(), 1000)

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
