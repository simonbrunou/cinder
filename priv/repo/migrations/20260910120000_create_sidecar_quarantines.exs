defmodule Cinder.Repo.Migrations.CreateSidecarQuarantines do
  use Ecto.Migration

  # Issue #585: `Cinder.Library.Sidecars` renames a sidecar it can't prove it owns to an
  # unguessable `.cinder-sidecar-quarantine-<token>` name and only logs it — nothing sweeps that
  # prefix and nothing surfaces it, so the log line was the only trace and it disappeared with
  # log rotation. This table records the retention at the moment it happens (the only place the
  # path is ever known) so `Cinder.Health` can surface it without ever walking the library
  # filesystem to rediscover it.
  def change do
    create table(:sidecar_quarantines) do
      add :path, :string, null: false
      add :destination, :string, null: false
      add :reason, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sidecar_quarantines, [:path])
  end
end
