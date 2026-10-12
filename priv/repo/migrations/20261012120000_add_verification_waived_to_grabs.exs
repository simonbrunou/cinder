defmodule Cinder.Repo.Migrations.AddVerificationWaivedToGrabs do
  use Ecto.Migration

  # Marks one grab whose release-policy verification the operator waived with "Import anyway"
  # (GitHub #630): checks whose outcome was unknown are skipped for THAT grab's import. It lives on
  # the grab row, which is deleted when the import finishes or the grab is discarded, so a
  # re-grab of the same release starts unwaived. Default false so every existing grab keeps being
  # verified normally.
  def change do
    alter table(:grabs) do
      add :verification_waived, :boolean, null: false, default: false
    end
  end
end
