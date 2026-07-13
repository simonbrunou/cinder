defmodule Cinder.Repo.Migrations.AddMovieVerificationHoldOrigin do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :verification_hold_origin, :string
    end
  end
end
