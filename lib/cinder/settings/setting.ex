defmodule Cinder.Settings.Setting do
  @moduledoc """
  A single in-app configuration value, keyed by string.

  `value` holds plaintext for non-secret keys and base64-encoded Cloak ciphertext
  for `is_secret` keys; decoding lives in `Cinder.Settings`, which owns the registry
  of which keys are secret.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "settings" do
    field :key, :string
    field :value, :string
    field :is_secret, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value, :is_secret])
    |> validate_required([:key])
    |> unique_constraint(:key)
  end
end
