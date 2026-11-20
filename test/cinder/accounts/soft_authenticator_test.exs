defmodule Cinder.Test.SoftAuthenticatorTest do
  # The passkey tests build every response with `Cinder.Test.SoftAuthenticator`, so a refusal
  # test only proves something when the unbroken response passes the real library. These pin it.
  use ExUnit.Case, async: true

  alias Cinder.Test.SoftAuthenticator

  @rp_id "cinder.example"
  @origin "https://cinder.example"

  defp decode(map, key), do: Base.url_decode64!(map[key], padding: false)

  test "an attestation passes Wax.register/3 and carries the credential's id and COSE key" do
    auth = SoftAuthenticator.new()

    challenge =
      Wax.new_registration_challenge(
        origin: @origin,
        rp_id: @rp_id,
        attestation: "none",
        user_verification: "required"
      )

    response = SoftAuthenticator.attest(auth, challenge.bytes, @rp_id, @origin)

    assert {:ok, {auth_data, {:none, nil, nil}}} =
             Wax.register(
               decode(response, "attestationObject"),
               decode(response, "clientDataJSON"),
               challenge
             )

    assert auth_data.attested_credential_data.credential_id == auth.credential_id

    assert auth_data.attested_credential_data.credential_public_key ==
             SoftAuthenticator.cose_key(auth)
  end

  test "an assertion passes Wax.authenticate/6 and reports the requested sign count" do
    auth = SoftAuthenticator.new(user_handle: "handle")

    challenge =
      Wax.new_authentication_challenge(
        origin: @origin,
        rp_id: @rp_id,
        user_verification: "required"
      )

    response = SoftAuthenticator.assert(auth, challenge.bytes, @rp_id, @origin, sign_count: 7)

    assert {:ok, auth_data} =
             Wax.authenticate(
               decode(response, "id"),
               decode(response, "authenticatorData"),
               decode(response, "signature"),
               decode(response, "clientDataJSON"),
               challenge,
               [{auth.credential_id, SoftAuthenticator.cose_key(auth)}]
             )

    assert auth_data.sign_count == 7
    assert decode(response, "userHandle") == "handle"
  end

  test "an assertion signed with another key fails Wax's signature check" do
    auth = SoftAuthenticator.new()
    other = SoftAuthenticator.new()
    challenge = Wax.new_authentication_challenge(origin: @origin, rp_id: @rp_id)
    response = SoftAuthenticator.assert(auth, challenge.bytes, @rp_id, @origin, sign_with: other)

    assert {:error, %Wax.InvalidSignatureError{}} =
             Wax.authenticate(
               decode(response, "id"),
               decode(response, "authenticatorData"),
               decode(response, "signature"),
               decode(response, "clientDataJSON"),
               challenge,
               [{auth.credential_id, SoftAuthenticator.cose_key(auth)}]
             )
  end
end
