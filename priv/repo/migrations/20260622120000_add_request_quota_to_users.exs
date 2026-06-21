defmodule Cinder.Repo.Migrations.AddRequestQuotaToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :request_quota, :integer
    end
  end
end
