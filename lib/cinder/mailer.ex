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

  @doc """
  False when `deliver/1` cannot send: the adapter is `Swoosh.Adapters.Local` and Swoosh's local
  mailbox (`Swoosh.Adapters.Local.Storage.Memory`, the adapter's default storage driver and the
  only one Cinder configures) is not running, so every delivery that reaches the adapter exits
  with `:noproc`. That is prod with no SMTP host: `Cinder.Settings` keeps the Local adapter, and
  `config :swoosh, local: false` keeps the mailbox from starting (#1546).

  True under any other adapter, such as `Swoosh.Adapters.SMTP` once an SMTP host is set, or
  `Swoosh.Adapters.Test` in test, and under the Local adapter while its mailbox runs, as in dev.
  It does not tell whether a given delivery will succeed: an SMTP relay can still refuse one.
  """
  @spec deliverable?() :: boolean()
  def deliverable? do
    adapter = Application.get_env(:cinder, __MODULE__, [])[:adapter]

    adapter != Swoosh.Adapters.Local or
      :global.whereis_name(Swoosh.Adapters.Local.Storage.Memory) != :undefined
  end

  @doc "The sender `{name, address}` every outgoing email uses."
  @spec from() :: {String.t(), String.t()}
  def from, do: {"Cinder", from_address()}

  @doc """
  Names a failed delivery's reason for a log line: an exception's module, an atom, or a tuple's
  leading atom tag, else `(no tag)`. It never returns the rest of the value. A reason can hold
  the email (the recipient's address, a confirm-link token) or the mailer config, SMTP password
  included: `Swoosh.Adapter.validate_config/2` raises a message that inspects the whole config,
  and `:idna` exits with the label of an address it refuses (#1535, #1544).
  """
  @spec reason_tag(term()) :: String.t()
  def reason_tag(%{__exception__: true, __struct__: module}) when is_atom(module),
    do: inspect(module)

  def reason_tag(tag) when is_atom(tag), do: inspect(tag)

  def reason_tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: inspect(elem(reason, 0))

  def reason_tag(_reason), do: "(no tag)"
end
