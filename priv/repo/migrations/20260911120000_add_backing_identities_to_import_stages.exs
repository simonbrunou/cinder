defmodule Cinder.Repo.Migrations.AddBackingIdentitiesToImportStages do
  use Ecto.Migration

  def change do
    # Issue #588, a follow-up to #584: the journal's `candidate_*`/`staged_*`/`backup_*` triples
    # are all `lstat`-derived, which on a mount that computes the reported inode from the PATH
    # (mergerfs `inodecalc=path-hash`, some FUSE) cannot answer a cross-path "is this the file I
    # put there" question — see the comments around `capture_backing_identity/1` and `owned?/5`
    # in `Cinder.Library.StageEngine` for the full reasoning. These two columns carry
    # `Cinder.Library.Filesystem.backing_identity/1`'s path-independent identity alongside the
    # existing path-derived one. Nullable, no default, no backfill: a nil means "no backing
    # evidence was captured for this row" (helper unavailable, path outside a configured root, or
    # a row written before this migration) and every comparison already treats that as "no
    # evidence" rather than a match.
    alter table(:import_stages) do
      add :candidate_backing_identity, :string
      add :backup_backing_identity, :string
    end
  end
end
