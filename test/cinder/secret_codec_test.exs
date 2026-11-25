defmodule Cinder.SecretCodecTest do
  use ExUnit.Case, async: true

  alias Cinder.SecretCodec
  alias Cloak.Ciphers.AES.GCM

  # A ciphertext made under another Vault key, as after a SECRET_KEY_BASE change: the key tag
  # matches the running Vault's cipher, so Cloak reaches the GCM check and answers {:ok, :error}.
  def other_key_ciphertext(plaintext) do
    {:ok, ciphertext} =
      GCM.encrypt(plaintext,
        key: :crypto.hash(:sha256, "another secret_key_base"),
        tag: "AES.GCM.V1"
      )

    Base.encode64(ciphertext)
  end

  test "encode/1 stores Base64 Vault ciphertext that decode/1 reads back" do
    stored = SecretCodec.encode("an-api-key")

    refute stored =~ "an-api-key"
    assert {:ok, raw} = Base.decode64(stored)
    assert {:ok, "an-api-key"} = Cinder.Vault.decrypt(raw)
    assert SecretCodec.decode(stored) == {:ok, "an-api-key"}
  end

  test "decode/1 answers :absent for nil" do
    assert SecretCodec.decode(nil) == :absent
  end

  test "decode/1 answers :unreadable for a ciphertext made under another key" do
    stored = other_key_ciphertext("an-api-key")

    # The control: Cloak itself answers {:ok, :error} here, not an error tuple.
    assert Cinder.Vault.decrypt(Base.decode64!(stored)) == {:ok, :error}
    assert SecretCodec.decode(stored) == :unreadable
  end

  test "decode/1 answers :unreadable for text that is not Base64, an empty value and a non-Vault blob" do
    assert SecretCodec.decode("@@@not-base64@@@") == :unreadable
    assert SecretCodec.decode("") == :unreadable
    assert SecretCodec.decode(Base.encode64("plain bytes, no key tag")) == :unreadable
  end

  test "decode/1 answers :unreadable for a value that is not text" do
    assert SecretCodec.decode(42) == :unreadable
    assert SecretCodec.decode(:error) == :unreadable
  end
end
