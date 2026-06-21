defmodule Cinder.Vault do
  @moduledoc false
  # Cloak vault for encrypting secret settings at rest. The AES-GCM key is derived
  # from SECRET_KEY_BASE in config/runtime.exs, so nothing crypto-related is committed
  # and each install gets a unique key with no extra env var. Losing/rotating
  # SECRET_KEY_BASE makes stored secrets undecryptable — Cinder.Settings degrades
  # gracefully (skip + re-enter) rather than failing to boot.
  use Cloak.Vault, otp_app: :cinder
end
