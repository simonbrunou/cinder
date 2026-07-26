defmodule Cinder.Mailer do
  use Swoosh.Mailer, otp_app: :cinder

  @default_from "contact@example.com"

  @doc """
  The configured SMTP from-address (`Cinder.Settings`' `smtp_from` field, overlaid onto this
  module's config alongside `relay`/`port`/`username`/`password`), or the shipped default when
  unset.
  """
  @spec from_address() :: String.t()
  def from_address do
    case Application.get_env(:cinder, __MODULE__, [])[:from] do
      value when is_binary(value) and value != "" -> value
      _ -> @default_from
    end
  end

  @doc "The sender `{name, address}` every outgoing email uses."
  @spec from() :: {String.t(), String.t()}
  def from, do: {"Cinder", from_address()}
end
