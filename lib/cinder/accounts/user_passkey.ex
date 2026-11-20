defmodule Cinder.Accounts.UserPasskey do
  @moduledoc """
  One passkey (WebAuthn credential) a user registered. `credential_id` and `public_key` are
  redacted from `inspect/1`, so neither reaches a log line through a struct. `public_key` holds
  the COSE key map Wax decoded at registration, stored with `:erlang.term_to_binary/1` and read
  back by `Cinder.Accounts.Passkeys` only.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @max_name_length 64

  schema "user_passkeys" do
    field :credential_id, :binary, redact: true
    field :public_key, :binary, redact: true
    field :sign_count, :integer, default: 0
    field :name, :string
    field :last_used_at, :utc_datetime
    belongs_to :user, Cinder.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "The longest name a passkey can carry."
  def max_name_length, do: @max_name_length

  @doc "A new passkey's changeset. Only `name` comes from the user."
  def create_changeset(passkey, attrs) do
    passkey
    |> change(Map.take(attrs, [:credential_id, :public_key, :sign_count, :user_id]))
    |> name_changeset(attrs)
    |> validate_required([:credential_id, :public_key, :sign_count, :user_id])
    |> unique_constraint(:credential_id)
  end

  @doc "Renames a passkey."
  def rename_changeset(passkey, attrs), do: name_changeset(passkey, attrs)

  defp name_changeset(passkey, attrs) do
    passkey
    |> cast(attrs, [:name])
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> validate_required([:name])
    |> validate_length(:name, max: @max_name_length)
  end
end
