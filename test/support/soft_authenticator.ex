defmodule Cinder.Test.SoftAuthenticator do
  @moduledoc """
  A software WebAuthn authenticator for tests: one P-256 (ES256) credential that answers the
  registration and sign-in ceremonies the way a browser hands them to Cinder, each field
  base64url-encoded without padding.

  `attest/4` builds the `navigator.credentials.create` response (attestation format `none`) and
  `assert/4` the `navigator.credentials.get` one. Both take the challenge bytes, the relying
  party ID and the origin, and options that change one thing about the answer, so a refusal test
  starts from a valid response and breaks exactly one field:

    * `:sign_count` (default: the credential's `sign_count`) is the counter `assert/4` reports;
    * `:flags` (default `[:up, :uv]`) are the authenticator data flags set;
    * `:type`, `:origin_in_client_data` and `:challenge_in_client_data` replace what the client
      data JSON says;
    * `:rp_id_hash_of` hashes another RP ID into the authenticator data;
    * `:sign_with` signs with another credential's private key;
    * `:user_handle` replaces the user handle `assert/4` returns (`nil` drops it).
  """

  defstruct [:credential_id, :public_key, :private_key, :user_handle, sign_count: 0]

  @type t :: %__MODULE__{}

  @doc "A fresh credential. `:user_handle` is the handle the relying party sent at creation."
  def new(opts \\ []) do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    %__MODULE__{
      credential_id:
        Keyword.get_lazy(opts, :credential_id, fn -> :crypto.strong_rand_bytes(32) end),
      public_key: public_key,
      private_key: private_key,
      user_handle: Keyword.get(opts, :user_handle),
      sign_count: Keyword.get(opts, :sign_count, 0)
    }
  end

  @doc "The COSE key map Wax decodes from this credential's attested credential data."
  def cose_key(%__MODULE__{public_key: <<4, x::binary-size(32), y::binary-size(32)>>}),
    do: %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}

  @doc """
  The `navigator.credentials.create` response for `challenge`. `:cose` merges entries over the
  attested COSE key, such as `%{3 => -36}` for another algorithm.
  """
  def attest(%__MODULE__{} = auth, challenge, rp_id, origin, opts \\ []) do
    client_data = client_data("webauthn.create", challenge, origin, opts)

    cose =
      auth
      |> cose_key()
      |> Map.merge(Keyword.get(opts, :cose, %{}))
      |> Map.new(fn
        {k, v} when is_binary(v) -> {k, %CBOR.Tag{tag: :bytes, value: v}}
        pair -> pair
      end)
      |> CBOR.encode()

    attested =
      <<0::128, byte_size(auth.credential_id)::16, auth.credential_id::binary, cose::binary>>

    auth_data =
      authenticator_data(rp_id, [:at | Keyword.get(opts, :flags, [:up, :uv])], 0, opts) <>
        attested

    attestation_object =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}
      })

    %{
      "id" => b64(auth.credential_id),
      "attestationObject" => b64(attestation_object),
      "clientDataJSON" => b64(client_data)
    }
  end

  @doc "The `navigator.credentials.get` response for `challenge`."
  def assert(%__MODULE__{} = auth, challenge, rp_id, origin, opts \\ []) do
    client_data = client_data("webauthn.get", challenge, origin, opts)
    count = Keyword.get(opts, :sign_count, auth.sign_count)
    auth_data = authenticator_data(rp_id, Keyword.get(opts, :flags, [:up, :uv]), count, opts)
    signer = Keyword.get(opts, :sign_with, auth)
    message = auth_data <> :crypto.hash(:sha256, client_data)
    signature = :crypto.sign(:ecdsa, :sha256, message, [signer.private_key, :prime256v1])

    %{
      "id" => b64(auth.credential_id),
      "authenticatorData" => b64(auth_data),
      "clientDataJSON" => b64(client_data),
      "signature" => b64(signature),
      "userHandle" =>
        case Keyword.get(opts, :user_handle, auth.user_handle) do
          nil -> nil
          handle -> b64(handle)
        end
    }
  end

  defp client_data(type, challenge, origin, opts) do
    Jason.encode!(%{
      "type" => Keyword.get(opts, :type, type),
      "challenge" => Keyword.get(opts, :challenge_in_client_data, b64(challenge)),
      "origin" => Keyword.get(opts, :origin_in_client_data, origin),
      "crossOrigin" => false
    })
  end

  @flag_bits %{up: 0x01, uv: 0x04, at: 0x40}

  defp authenticator_data(rp_id, flags, count, opts) do
    hash = :crypto.hash(:sha256, Keyword.get(opts, :rp_id_hash_of, rp_id))
    flag_byte = flags |> Enum.map(&Map.fetch!(@flag_bits, &1)) |> Enum.reduce(0, &Bitwise.bor/2)
    <<hash::binary, flag_byte::8, count::32>>
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
