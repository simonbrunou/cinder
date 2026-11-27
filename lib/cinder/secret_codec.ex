defmodule Cinder.SecretCodec do
  @moduledoc """
  The one codec for secrets stored as Base64 `Cinder.Vault` ciphertext: the secret settings
  (`Cinder.Settings.Crypto`), the configured indexers' secrets (`Cinder.Indexers.Secrets`), the
  Plex token (`Cinder.Accounts`) and the download intent's link (`Cinder.Download`).

  `decode/1` tells three answers apart and never raises, logs or returns the ciphertext:
  `:absent` for a value never set (`nil`), `{:ok, plaintext}`, and `:unreadable` for anything
  that does not decrypt, such as a value encrypted under another `SECRET_KEY_BASE`. Code that
  reads a stored secret goes through `decode/1` rather than calling `Cinder.Vault.decrypt/1`.
  """

  @type decoded :: :absent | {:ok, binary()} | :unreadable

  @doc "The stored form of `plaintext`: its Vault ciphertext, Base64-encoded."
  @spec encode(binary()) :: binary()
  def encode(plaintext) when is_binary(plaintext),
    do: plaintext |> Cinder.Vault.encrypt!() |> Base.encode64()

  @doc "Decodes a stored value: `:absent`, `{:ok, plaintext}` or `:unreadable`."
  @spec decode(term()) :: decoded()
  def decode(nil), do: :absent

  # The is_binary guard matters: Cloak's AES-GCM decrypt returns {:ok, :error} (not an error
  # tuple, not a raise) when the GCM tag fails to authenticate, as under another key.
  def decode(stored) when is_binary(stored) do
    with {:ok, ciphertext} <- Base.decode64(stored),
         {:ok, plaintext} when is_binary(plaintext) <- Cinder.Vault.decrypt(ciphertext) do
      {:ok, plaintext}
    else
      _ -> :unreadable
    end
  rescue
    _ -> :unreadable
  end

  def decode(_other), do: :unreadable
end
