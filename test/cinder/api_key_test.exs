defmodule Cinder.ApiKeyTest do
  # async: false — Cinder.Settings.put/2 re-applies the global Application env overlay.
  use Cinder.DataCase, async: false

  alias Cinder.{ApiKey, Settings}
  alias Cinder.Repo
  alias Cinder.Settings.Setting

  defp stored_row, do: Repo.get_by(Setting, key: "api_key_hash_v2")

  test "no key is configured on a fresh install and nothing validates" do
    refute ApiKey.configured?()
    refute ApiKey.valid?("anything")
    refute ApiKey.valid?("")
    refute ApiKey.valid?(nil)
  end

  test "legacy read-only keys do not gain write access after an upgrade" do
    key = "formerly-read-only"
    hash = :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)
    :ok = Settings.put("api_key_hash", hash)

    refute ApiKey.configured?()
    refute ApiKey.valid?(key)
  end

  test "generate/0 returns a plaintext key that validates" do
    key = ApiKey.generate()

    assert is_binary(key)
    assert byte_size(key) >= 32
    assert ApiKey.configured?()
    assert ApiKey.valid?(key)
    refute ApiKey.valid?(key <> "x")
    refute ApiKey.valid?("wrong")
  end

  test "the key is stored hashed, never in plaintext and never as a vault secret" do
    key = ApiKey.generate()
    row = stored_row()

    refute row.value == key
    refute row.value =~ key
    # A hash, not reversible ciphertext: the row is not flagged secret, because there is
    # nothing to decrypt back.
    refute row.is_secret
    assert row.value == Base.encode16(:crypto.hash(:sha256, key), case: :lower)
  end

  test "generating again revokes the previous key" do
    old = ApiKey.generate()
    new = ApiKey.generate()

    refute old == new
    refute ApiKey.valid?(old)
    assert ApiKey.valid?(new)
  end

  test "revoke/0 removes the key and is idempotent" do
    key = ApiKey.generate()

    assert ApiKey.revoke() == :ok
    refute ApiKey.configured?()
    refute ApiKey.valid?(key)
    assert is_nil(stored_row())

    assert ApiKey.revoke() == :ok
    refute ApiKey.configured?()
  end
end
