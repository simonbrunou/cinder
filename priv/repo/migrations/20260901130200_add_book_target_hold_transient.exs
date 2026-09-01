defmodule Cinder.Repo.Migrations.AddBookTargetHoldTransient do
  use Ecto.Migration

  def change do
    # Whether a `:held` target's hold is worth an unattended retry (`Cinder.Books.Rehunter`).
    # Nullable, no default, and only meaningful while `status == :held`: the caller that holds a
    # target states this fact explicitly (see `Cinder.Books.hold_target/4`'s callers) rather than
    # having it inferred from the free-text `hold_reason` string, which has no closed vocabulary.
    alter table(:book_targets) do
      add :hold_transient, :boolean
    end
  end
end
