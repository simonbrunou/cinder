defmodule Cinder.Repo.Migrations.AddFailureReasonToMovies do
  use Ecto.Migration

  # A human-facing detail for a parked movie (e.g. SABnzbd's paused state or fail_message),
  # surfaced on /activity. Nil for parks with no actionable client-side detail; the transition
  # changeset force-clears it on any transition out of :import_failed, so it never goes stale.
  def change do
    alter table(:movies) do
      add :failure_reason, :string
    end
  end
end
