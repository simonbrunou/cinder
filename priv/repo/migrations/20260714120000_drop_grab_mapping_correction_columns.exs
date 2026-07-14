defmodule Cinder.Repo.Migrations.DropGrabMappingCorrectionColumns do
  use Ecto.Migration

  # The grab-local mapping-correction workflow (grab-scoped file re-assignment + coordinate
  # promotion) was deleted in favor of the app's existing hold + operator Retry/Discard idiom.
  # These two columns existed only to feed that workflow: `automatic_mapping_decisions` was
  # never read back from a persisted grab once the correction UI was gone (the safety-invariant
  # inventory check consumes the same-call in-memory decisions, not the stored column), and
  # `manual_mapping_overrides` had no writer once per-file overrides were removed. `mapping_issue`
  # stays — it is the persisted hold reason the new /activity UI reads.
  def change do
    alter table(:grabs) do
      remove :automatic_mapping_decisions, :map
      remove :manual_mapping_overrides, :map
    end
  end
end
