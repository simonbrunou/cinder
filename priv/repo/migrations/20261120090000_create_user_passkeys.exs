defmodule Cinder.Repo.Migrations.CreateUserPasskeys do
  use Ecto.Migration

  def change do
    # The WebAuthn user handle Cinder gives a user's passkeys: 32 random bytes, set by the user's
    # first request for passkey registration options (before any passkey exists) and never
    # changed, so it carries nothing about the user (no id, no email) and survives a
    # secret_key_base rotation. Existing rows keep NULL until then.
    alter table(:users) do
      add :passkey_handle, :binary
    end

    create unique_index(:users, [:passkey_handle])

    create table(:user_passkeys) do
      # Mirrors the other per-user tables: deleting the user deletes their passkeys.
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :credential_id, :binary, null: false
      # The credential's COSE public key. Public material only: the private key never leaves
      # the authenticator.
      add :public_key, :binary, null: false
      add :sign_count, :integer, null: false, default: 0
      add :name, :string, null: false
      add :last_used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_passkeys, [:credential_id])
    create index(:user_passkeys, [:user_id])
  end
end
