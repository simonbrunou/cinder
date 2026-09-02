defmodule Cinder.Repo.Migrations.AddBookTargetAudiobookshelfScannedAt do
  use Ecto.Migration

  def change do
    # The durable, retried-until-success post-import scan flag (B7c). Nullable, no default: NULL
    # means "this target's on-disk content changed and Audiobookshelf has not been told yet" — a
    # fresh `:available` transition of an audiobook target leaves it NULL (see
    # `Cinder.Books.Files.arm_target/1`), and `Cinder.Download.BookPoller` stamps it only after a
    # successful `Cinder.Library.AudiobookServer.impl().scan/0`. Deliberately NOT a one-shot
    # `Cinder.Library.ImportStage.claim_post_commit_effects/1` claim: a scan failure must stay
    # recoverable without re-downloading, so every subsequent poller tick re-derives and retries
    # the same target from this column rather than a claimed-once effects row. Never CHECKed
    # against `status`/`media_kind` — an e-book target simply never matches
    # `Cinder.Books.list_pending_audiobook_scans/0`'s `media_kind == :audiobook` filter, so it
    # stays NULL and unused for the lifetime of that row.
    alter table(:book_targets) do
      add :audiobookshelf_scanned_at, :utc_datetime
    end
  end
end
