defmodule Cinder.Settings.Crypto do
  @moduledoc """
  Secret-row encode/decode for `Cinder.Settings` — carved out of `settings.ex` (plain code
  motion, 1500-line cap). Secret values are encrypted at rest via `Cinder.Vault`, keyed off
  `SECRET_KEY_BASE`; a value encrypted under a different key decodes to `:error`, never a
  raise and never the ciphertext.
  """

  require Logger

  alias Cinder.Settings.Setting
  alias Cinder.Util

  @doc "Decodes a row to its plaintext (nil-blanked); an undecryptable secret decodes to nil."
  def decode_setting(setting), do: setting |> decoded() |> unwrap() |> Util.blank_to_nil()

  defp unwrap({:ok, value}), do: value
  defp unwrap(:error), do: nil

  def decoded(%Setting{is_secret: false, value: value}), do: {:ok, value}
  def decoded(%Setting{is_secret: true, value: nil}), do: {:ok, nil}

  def decoded(%Setting{is_secret: true, value: value, key: key}) do
    case decrypt_secret(value) do
      {:ok, plaintext} -> {:ok, plaintext}
      :error -> warn_undecryptable(key)
    end
  end

  @doc "The stored representation for a value: encrypted+base64 for secrets, plaintext otherwise."
  def store_value(true = _secret?, value), do: Base.encode64(Cinder.Vault.encrypt!(value))
  def store_value(false = _secret?, value), do: value

  @doc """
  Whether a secret row decodes cleanly — a non-logging companion to `decoded/1` so the
  /settings + service-health surfaces can count undecryptable secrets without re-logging on
  every render.
  """
  def decryptable?(%Setting{is_secret: true, value: nil}), do: true

  def decryptable?(%Setting{is_secret: true, value: value}),
    do: match?({:ok, _}, decrypt_secret(value))

  # Decrypts a secret's stored base64 ciphertext. Returns :error (never raises, never logs, never
  # returns the ciphertext) when the value was encrypted under a different SECRET_KEY_BASE. The
  # is_binary guard matters: Cloak's AES-GCM decrypt returns {:ok, :error} (not an error tuple, not
  # a raise) when the GCM tag fails to authenticate — without the guard :error would be poured into
  # Application env as a credential.
  defp decrypt_secret(value) do
    with {:ok, ciphertext} <- Base.decode64(value),
         {:ok, plaintext} when is_binary(plaintext) <- Cinder.Vault.decrypt(ciphertext) do
      {:ok, plaintext}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp warn_undecryptable(key) do
    Logger.warning("Cinder.Settings: cannot decrypt #{key}; re-enter it in /settings")
    :error
  end
end
