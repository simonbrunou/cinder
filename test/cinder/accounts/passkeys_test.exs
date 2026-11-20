defmodule Cinder.Accounts.PasskeysTest do
  # async: false: a test shrinks the challenge store's TTL, which every ceremony reads.
  use Cinder.DataCase, async: false

  import Cinder.AccountsFixtures
  import Cinder.ConfigCase, only: [put_env: 2]
  import Cinder.Test.PasskeyHelpers

  alias Cinder.Accounts
  alias Cinder.Accounts.Passkeys
  alias Cinder.Accounts.UserPasskey
  alias Cinder.Repo
  alias Cinder.Test.SoftAuthenticator

  defp count(user), do: length(Passkeys.list(user))
  defp reload(passkey), do: Repo.get!(UserPasskey, passkey.id)

  describe "registration" do
    test "stores the credential id, the COSE public key, the name and the sign count" do
      user = user_fixture()
      {passkey, auth} = register_passkey!(user, "  Phone  ")

      stored = reload(passkey)
      assert stored.user_id == user.id
      assert stored.credential_id == auth.credential_id
      assert :erlang.binary_to_term(stored.public_key) == SoftAuthenticator.cose_key(auth)
      assert stored.name == "Phone"
      assert stored.sign_count == 0
      assert stored.last_used_at == nil
      assert [%UserPasskey{id: id}] = Passkeys.list(user)
      assert id == passkey.id
    end

    test "the options ask for user verification, a discoverable credential and no attestation" do
      user = user_fixture()
      {:ok, %{options: options}} = Passkeys.registration_options(user, rp())

      assert options.rp == %{id: "localhost", name: "Cinder"}
      assert options.attestation == "none"

      assert options.authenticatorSelection == %{
               residentKey: "required",
               requireResidentKey: true,
               userVerification: "required"
             }

      assert options.user.name == user.email
      assert options.excludeCredentials == []
      assert Enum.map(options.pubKeyCredParams, & &1.alg) == [-7, -8, -257]
    end

    test "the user handle is 32 random bytes, stable across registrations and distinct per user" do
      user = user_fixture()
      other = user_fixture()

      {:ok, %{options: first}} = Passkeys.registration_options(user, rp())
      {:ok, %{options: second}} = Passkeys.registration_options(user, rp())
      {:ok, %{options: others}} = Passkeys.registration_options(other, rp())

      handle = Base.url_decode64!(first.user.id, padding: false)
      assert byte_size(handle) == 32
      assert second.user.id == first.user.id
      assert others.user.id != first.user.id
      assert Repo.reload!(user).passkey_handle == handle
    end

    test "the options exclude the credentials the user already registered" do
      user = user_fixture()
      {_passkey, auth} = register_passkey!(user)
      {:ok, %{options: options}} = Passkeys.registration_options(user, rp())

      assert options.excludeCredentials == [
               %{type: "public-key", id: Base.url_encode64(auth.credential_id, padding: false)}
             ]
    end

    test "a registration challenge completes only for the user it was issued to, and only once" do
      user = user_fixture()
      other = user_fixture()
      {:ok, %{handle: handle, options: options}} = Passkeys.registration_options(user, rp())
      challenge = Base.url_decode64!(options.challenge, padding: false)

      response =
        SoftAuthenticator.attest(SoftAuthenticator.new(), challenge, "localhost", rp().origin)

      assert {:error, :wrong_purpose} = Passkeys.register(other, handle, response, "Stolen")
      assert {:error, :unknown} = Passkeys.register(user, handle, response, "Late")
      assert count(user) == 0 and count(other) == 0
    end

    test "a sign-in challenge never completes a registration" do
      user = user_fixture()
      {:ok, %{handle: handle, options: options}} = Passkeys.sign_in_options(rp(), user.id)
      challenge = Base.url_decode64!(options.challenge, padding: false)

      response =
        SoftAuthenticator.attest(SoftAuthenticator.new(), challenge, "localhost", rp().origin)

      assert {:error, :wrong_purpose} = Passkeys.register(user, handle, response, "Key")
      assert count(user) == 0
    end

    test "a credential id another passkey already holds is refused" do
      user = user_fixture()
      other = user_fixture()
      {_passkey, auth} = register_passkey!(user)

      {:ok, %{handle: handle, options: options}} = Passkeys.registration_options(other, rp())
      challenge = Base.url_decode64!(options.challenge, padding: false)
      response = SoftAuthenticator.attest(auth, challenge, "localhost", rp().origin)

      assert {:error, :credential_taken} = Passkeys.register(other, handle, response, "Copy")
      assert count(other) == 0
    end

    test "a credential with an algorithm Cinder did not offer or an id past 1023 bytes is refused" do
      user = user_fixture()

      cases = [
        {SoftAuthenticator.new(), [cose: %{3 => -36}]},
        {SoftAuthenticator.new(credential_id: :crypto.strong_rand_bytes(1024)), []}
      ]

      for {auth, opts} <- cases do
        {:ok, %{handle: handle, options: options}} = Passkeys.registration_options(user, rp())
        challenge = Base.url_decode64!(options.challenge, padding: false)
        response = SoftAuthenticator.attest(auth, challenge, "localhost", rp().origin, opts)

        assert {{:error, :unsupported_credential}, _} =
                 {Passkeys.register(user, handle, response, "Key"), opts}
      end

      assert count(user) == 0
    end

    test "options for a user no longer stored are refused" do
      user = user_fixture()
      Repo.delete!(user)

      assert {:error, :unknown_user} = Passkeys.registration_options(user, rp())
    end

    test "a blank or too long name is a changeset error and stores nothing" do
      user = user_fixture()

      for name <- ["  ", String.duplicate("a", UserPasskey.max_name_length() + 1)] do
        {:ok, %{handle: handle, options: options}} = Passkeys.registration_options(user, rp())
        challenge = Base.url_decode64!(options.challenge, padding: false)

        response =
          SoftAuthenticator.attest(SoftAuthenticator.new(), challenge, "localhost", rp().origin)

        assert {:error, %Ecto.Changeset{errors: [name: _]}} =
                 Passkeys.register(user, handle, response, name)
      end

      assert count(user) == 0
    end

    test "an answer for another origin, without user verification or malformed is refused" do
      user = user_fixture()

      cases = [
        {[origin_in_client_data: "https://evil.example"], :origin_mismatch},
        {[rp_id_hash_of: "evil.example"], :rp_id_mismatch},
        {[flags: [:up]], :user_not_verified},
        {[type: "webauthn.get"], :create_type_expected},
        {[challenge_in_client_data: "%%%"], :malformed}
      ]

      for {opts, reason} <- cases do
        {:ok, %{handle: handle, options: options}} = Passkeys.registration_options(user, rp())
        challenge = Base.url_decode64!(options.challenge, padding: false)

        response =
          SoftAuthenticator.attest(
            SoftAuthenticator.new(),
            challenge,
            "localhost",
            rp().origin,
            opts
          )

        assert {{:error, ^reason}, _} = {Passkeys.register(user, handle, response, "Key"), opts}
      end

      {:ok, %{handle: handle}} = Passkeys.registration_options(user, rp())
      assert {:error, :malformed} = Passkeys.register(user, handle, %{"x" => 1}, "Key")
      assert count(user) == 0
    end
  end

  describe "authenticate/3" do
    setup do
      user = user_fixture()
      {passkey, auth} = register_passkey!(user)
      %{user: user, passkey: passkey, auth: auth}
    end

    test "a valid assertion answers the owner and records the count and the time", ctx do
      {handle, assertion} = sign_in_assertion(ctx.auth, nil, sign_count: 3)

      assert {:ok, user} = Passkeys.authenticate(handle, nil, assertion)
      assert user.id == ctx.user.id
      stored = reload(ctx.passkey)
      assert stored.sign_count == 3
      assert DateTime.diff(DateTime.utc_now(), stored.last_used_at) in 0..5
    end

    test "a pending user's passkey still answers its owner", ctx do
      Repo.update_all(Ecto.Query.from(u in Accounts.User, where: u.id == ^ctx.user.id),
        set: [active: false]
      )

      {handle, assertion} = sign_in_assertion(ctx.auth)
      assert {:ok, %{active: false}} = Passkeys.authenticate(handle, nil, assertion)
    end

    test "a stored public key that is not a COSE map is refused", ctx do
      for stored <- ["not a term", :erlang.term_to_binary(:not_a_map)] do
        Repo.update_all(
          Ecto.Query.from(p in UserPasskey, where: p.id == ^ctx.passkey.id),
          set: [public_key: stored]
        )

        {handle, assertion} = sign_in_assertion(ctx.auth)

        assert {{:error, :bad_public_key}, _} =
                 {Passkeys.authenticate(handle, nil, assertion), stored}
      end
    end

    test "an unknown credential is refused", _ctx do
      {handle, assertion} = sign_in_assertion(SoftAuthenticator.new(user_handle: "x"))
      assert {:error, :unknown_credential} = Passkeys.authenticate(handle, nil, assertion)
    end

    test "a bad signature is refused and leaves the count", ctx do
      {handle, assertion} =
        sign_in_assertion(ctx.auth, nil, sign_count: 1, sign_with: SoftAuthenticator.new())

      assert {:error, :bad_signature} = Passkeys.authenticate(handle, nil, assertion)
      assert reload(ctx.passkey).sign_count == 0
    end

    test "a replayed challenge is refused", ctx do
      {handle, assertion} = sign_in_assertion(ctx.auth, nil, sign_count: 1)

      assert {:ok, _} = Passkeys.authenticate(handle, nil, assertion)
      assert {:error, :unknown} = Passkeys.authenticate(handle, nil, assertion)
    end

    test "an assertion over a challenge Cinder never stored is refused", ctx do
      {handle, _} = sign_in_assertion(ctx.auth)
      {_other_handle, assertion} = sign_in_assertion(ctx.auth, nil, sign_count: 1)

      assert {:error, :challenge_mismatch} = Passkeys.authenticate(handle, nil, assertion)
    end

    test "an expired challenge is refused", ctx do
      put_env(:passkey_challenge_ttl_ms, 50)
      {handle, assertion} = sign_in_assertion(ctx.auth, nil, sign_count: 1)
      Process.sleep(60)

      assert {:error, :expired} = Passkeys.authenticate(handle, nil, assertion)
      assert reload(ctx.passkey).sign_count == 0
    end

    test "a challenge Wax reads as expired is refused even when the store still holds it", ctx do
      # A TTL under a second gives Wax a 0 s timeout, so its own expiry check refuses.
      put_env(:passkey_challenge_ttl_ms, 900)
      {handle, assertion} = sign_in_assertion(ctx.auth, nil, sign_count: 1)

      assert {:error, :expired} = Passkeys.authenticate(handle, nil, assertion)
    end

    test "the sign count must grow, except while stored and reported counts are both 0", ctx do
      {h, a} = sign_in_assertion(ctx.auth, nil, sign_count: 0)
      assert {:ok, _} = Passkeys.authenticate(h, nil, a)

      {h, a} = sign_in_assertion(ctx.auth, nil, sign_count: 5)
      assert {:ok, _} = Passkeys.authenticate(h, nil, a)

      for count <- [5, 4, 0] do
        {h, a} = sign_in_assertion(ctx.auth, nil, sign_count: count)

        assert {{:error, :sign_count_regression}, ^count} =
                 {Passkeys.authenticate(h, nil, a), count}
      end

      assert reload(ctx.passkey).sign_count == 5
      {h, a} = sign_in_assertion(ctx.auth, nil, sign_count: 6)
      assert {:ok, _} = Passkeys.authenticate(h, nil, a)
      assert reload(ctx.passkey).sign_count == 6
    end

    test "a user handle other than the owner's, or none, is refused", ctx do
      {h, a} = sign_in_assertion(ctx.auth, nil, sign_count: 1, user_handle: "someone else")
      assert {:error, :user_handle_mismatch} = Passkeys.authenticate(h, nil, a)

      {h, a} = sign_in_assertion(ctx.auth, nil, sign_count: 1, user_handle: nil)
      assert {:error, :malformed} = Passkeys.authenticate(h, nil, a)
      assert reload(ctx.passkey).sign_count == 0
    end

    test "for a signed-in session, the passkey of another user is refused before any write",
         ctx do
      other = user_fixture()
      {h, a} = sign_in_assertion(ctx.auth, other.id, sign_count: 1)

      assert {:error, :other_user} = Passkeys.authenticate(h, other.id, a)
      stored = reload(ctx.passkey)
      assert stored.sign_count == 0 and stored.last_used_at == nil
    end

    test "for a signed-in session, the user's own passkey answers", ctx do
      {h, a} = sign_in_assertion(ctx.auth, ctx.user.id, sign_count: 1)
      assert {:ok, %{id: id}} = Passkeys.authenticate(h, ctx.user.id, a)
      assert id == ctx.user.id
    end

    test "a challenge minted for one session identity never completes for another", ctx do
      {h, a} = sign_in_assertion(ctx.auth, nil, sign_count: 1)
      assert {:error, :wrong_purpose} = Passkeys.authenticate(h, ctx.user.id, a)
    end

    test "another origin, another RP ID, no user verification or a cross-origin frame is refused",
         ctx do
      cases = [
        {[origin_in_client_data: "https://evil.example"], :origin_mismatch},
        {[rp_id_hash_of: "evil.example"], :rp_id_mismatch},
        {[flags: [:up]], :user_not_verified},
        {[type: "webauthn.create"], :get_type_expected}
      ]

      for {opts, reason} <- cases do
        {h, a} = sign_in_assertion(ctx.auth, nil, [sign_count: 1] ++ opts)
        assert {{:error, ^reason}, _} = {Passkeys.authenticate(h, nil, a), opts}
      end

      # Each frame field alone: `topOrigin` with `crossOrigin` still false.
      for {field, value} <- [{"crossOrigin", true}, {"topOrigin", "https://evil.example"}] do
        {h, a} = sign_in_assertion(ctx.auth, nil, sign_count: 1)

        client_data =
          a["clientDataJSON"]
          |> Base.url_decode64!(padding: false)
          |> Jason.decode!()
          |> Map.put(field, value)
          |> Jason.encode!()
          |> Base.url_encode64(padding: false)

        assert {{:error, :cross_origin}, ^field} =
                 {Passkeys.authenticate(h, nil, %{a | "clientDataJSON" => client_data}), field}
      end

      assert reload(ctx.passkey).sign_count == 0
    end

    test "malformed fields are refused without raising", ctx do
      changes = [
        {"no fields", fn _ -> %{} end},
        {"an id that is not base64url", &Map.put(&1, "id", "not base64!")},
        {"client data that is not an object",
         &Map.put(&1, "clientDataJSON", Base.url_encode64("[1]", padding: false))},
        {"empty authenticator data", &Map.put(&1, "authenticatorData", "")},
        {"a signature that is not a string", &Map.put(&1, "signature", 42)}
      ]

      for {label, change} <- changes do
        {h, a} = sign_in_assertion(ctx.auth, nil, sign_count: 1)
        assert {{:error, :malformed}, ^label} = {Passkeys.authenticate(h, nil, change.(a)), label}
      end

      # Signed client data that Wax's own parser raises on.
      for opts <- [[challenge_in_client_data: "not base64!"], [type: "webauthn.other"]] do
        {h, a} = sign_in_assertion(ctx.auth, nil, [sign_count: 1] ++ opts)
        assert {{:error, :malformed}, ^opts} = {Passkeys.authenticate(h, nil, a), opts}
      end

      assert reload(ctx.passkey).sign_count == 0
    end
  end

  describe "managing passkeys" do
    test "a user renames and deletes their own passkey, never another user's" do
      user = user_fixture()
      other = user_fixture()
      {passkey, _} = register_passkey!(user)

      assert {:error, :not_found} = Passkeys.rename(other, passkey.id, %{"name" => "Mine"})
      assert {:error, :not_found} = Passkeys.delete(other, passkey.id)
      assert reload(passkey).name == "Laptop"

      assert {:ok, %{name: "Work key"}} =
               Passkeys.rename(user, passkey.id, %{"name" => "Work key"})

      assert {:error, %Ecto.Changeset{}} = Passkeys.rename(user, passkey.id, %{"name" => ""})
      assert reload(passkey).name == "Work key"

      assert :ok = Passkeys.delete(user, passkey.id)
      assert count(user) == 0
      assert {:error, :not_found} = Passkeys.delete(user, passkey.id)
    end

    test "deleting a user deletes their passkeys" do
      admin = admin_fixture()
      user = user_fixture()
      {passkey, _} = register_passkey!(user)
      {kept, _} = register_passkey!(admin)

      assert {:ok, _, _} = Accounts.delete_user(admin, user)
      refute Repo.get(UserPasskey, passkey.id)
      assert Repo.get(UserPasskey, kept.id)
    end

    test "the data export lists each passkey's name and dates, never its key material" do
      user = user_fixture()
      {passkey, auth} = register_passkey!(user, "Phone")

      export = Accounts.export_user_data(user)

      assert [%{name: "Phone", inserted_at: inserted_at, last_used_at: nil}] = export.passkeys
      assert inserted_at == DateTime.to_iso8601(passkey.inserted_at)
      json = Jason.encode!(export)

      for encoded <- [
            Base.url_encode64(auth.credential_id, padding: false),
            Base.encode64(auth.credential_id),
            Base.encode16(auth.credential_id, case: :lower)
          ] do
        refute json =~ encoded
      end

      refute Map.has_key?(export, :passkey_handle)
    end
  end
end
