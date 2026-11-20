defmodule Cinder.Test.PasskeyHelpers do
  @moduledoc """
  Runs the passkey ceremonies of `Cinder.Accounts.Passkeys` with a
  `Cinder.Test.SoftAuthenticator`, so a test starts from a real registered passkey and a real
  signed assertion, then breaks one thing.
  """
  alias Cinder.Accounts.Passkeys
  alias Cinder.Test.SoftAuthenticator

  @doc "The relying party the test endpoint derives (`CinderWeb.Passkey.relying_party/0`)."
  def rp, do: %{id: "localhost", origin: "http://localhost:4000"}

  @doc "Registers a fresh passkey for `user` and returns `{passkey, authenticator}`."
  def register_passkey!(user, name \\ "Laptop", rp \\ rp()) do
    {:ok, %{handle: handle, options: options}} = Passkeys.registration_options(user, rp)
    user_handle = Base.url_decode64!(options.user.id, padding: false)
    auth = SoftAuthenticator.new(user_handle: user_handle)
    challenge = Base.url_decode64!(options.challenge, padding: false)
    response = SoftAuthenticator.attest(auth, challenge, rp.id, rp.origin)
    {:ok, passkey} = Passkeys.register(user, handle, response, name)
    {passkey, auth}
  end

  @doc """
  Starts a sign-in for the session identity `signed_in_user_id` and returns `{handle,
  assertion}`, the assertion built by `auth` with `opts` (`SoftAuthenticator.assert/5`).
  """
  def sign_in_assertion(auth, signed_in_user_id \\ nil, opts \\ [], rp \\ rp()) do
    {:ok, %{handle: handle, options: options}} = Passkeys.sign_in_options(rp, signed_in_user_id)
    challenge = Base.url_decode64!(options.challenge, padding: false)
    {handle, SoftAuthenticator.assert(auth, challenge, rp.id, rp.origin, opts)}
  end
end
