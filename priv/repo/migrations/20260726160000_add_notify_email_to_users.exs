defmodule Cinder.Repo.Migrations.AddNotifyEmailToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :notify_email, :boolean, null: false, default: true
    end

    execute("UPDATE users SET notify_email = 1")
  end

  def down do
    alter table(:users) do
      remove :notify_email
    end
  end
end
