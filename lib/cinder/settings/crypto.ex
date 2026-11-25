defmodule Cinder.Settings.Crypto do
  @moduledoc """
  Secret-row encode/decode for `Cinder.Settings` — carved out of `settings.ex` (plain code
  motion, 1500-line cap). Secret values are encrypted at rest through `Cinder.SecretCodec`, keyed
  off `SECRET_KEY_BASE`; a value encrypted under a different key decodes to `:error`, never a
  raise and never the ciphertext.
  """

  require Logger

  alias Cinder.SecretCodec
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
  def store_value(true = _secret?, value), do: SecretCodec.encode(value)
  def store_value(false = _secret?, value), do: value

  @doc """
  Whether a secret row decodes cleanly — a non-logging companion to `decoded/1` so the
  /settings + service-health surfaces can count undecryptable secrets without re-logging on
  every render.
  """
  def decryptable?(%Setting{is_secret: true, value: nil}), do: true

  def decryptable?(%Setting{is_secret: true, value: value}),
    do: match?({:ok, _}, decrypt_secret(value))

  # A non-nil value: `SecretCodec.decode/1` answers `:absent` only for nil, which the clauses
  # above take first.
  defp decrypt_secret(value) do
    case SecretCodec.decode(value) do
      {:ok, plaintext} -> {:ok, plaintext}
      :unreadable -> :error
    end
  end

  defp warn_undecryptable(key) do
    Logger.warning("Cinder.Settings: cannot decrypt #{key}; re-enter it in /settings")
    :error
  end
end
