defmodule Cinder.Repo.Migrations.AddOidcIdentityToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :oidc_issuer, :string
      add :oidc_subject, :string
      add :oidc_name, :string
    end

    create unique_index(:users, [:oidc_issuer, :oidc_subject], name: :users_oidc_identity_index)
  end
end
