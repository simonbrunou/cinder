defmodule Cinder.ApiKey do
  @moduledoc """
  The single admin-generated key that authenticates the read-only `/api/v1` scope.

  One key for the whole household (no per-user keys, no scopes) — the consumers are dashboard
  widgets and bots, not people. It is stored as a **SHA-256 hash**, not as an encrypted secret:
  the settings vault is reversible by design (the app has to hand a TMDB token back to TMDB),
  but nothing ever needs the API key back, so a DB read must not yield a usable credential.
  The plaintext is returned exactly once, by `generate/0`, and never persisted.

  Stored under a raw settings key rather than a `Cinder.Settings.Registry` field on purpose
  (the `auto_approve_all` pattern): it targets no `:cinder` env key, must never appear in the
  `/settings` form state, and has no label to translate.
  """
  alias Cinder.Settings

  @setting_key "api_key_hash"
  @rand_size 32

  @doc """
  Mints a new key, replacing any existing one, and returns the plaintext.

  This is the only moment the plaintext exists — the caller must show it to the admin now or
  lose it. Regenerating revokes the previous key, so a leaked key is rotated by generating again.
  """
  @spec generate() :: String.t()
  def generate do
    key = @rand_size |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    Settings.put(@setting_key, hash(key))
    key
  end

  @doc "Revokes the key, if one is set. Idempotent."
  @spec revoke() :: :ok
  def revoke do
    Settings.delete(@setting_key)
    :ok
  end

  @doc "True when a key has been generated and not revoked."
  @spec configured?() :: boolean()
  def configured?, do: is_binary(Settings.get(@setting_key))

  @doc """
  True when `presented` is the current key.

  The comparison is `Plug.Crypto.secure_compare/2` over fixed-length hex digests, so a
  near-miss key can't be walked byte by byte. Callers must answer every `false` identically:
  "wrong key" and "no key configured" are the same non-answer.
  """
  @spec valid?(term()) :: boolean()
  def valid?(presented) when is_binary(presented) do
    case Settings.get(@setting_key) do
      stored when is_binary(stored) -> Plug.Crypto.secure_compare(hash(presented), stored)
      _ -> false
    end
  end

  def valid?(_presented), do: false

  defp hash(key), do: :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)
end
