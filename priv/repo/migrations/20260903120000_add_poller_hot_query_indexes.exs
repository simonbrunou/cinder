defmodule Cinder.Repo.Migrations.AddPollerHotQueryIndexes do
  use Ecto.Migration

  # #454: the 5s Poller/TvPoller/book poller each full-scan movies/grabs/book_grabs on every
  # tick, forever, and rows are never pruned. movies.status backs Catalog.list_by_status/1
  # (a plain index, mirroring the existing requests/download_intents status indexes).
  # grabs.content_path and book_grabs.content_path each back two distinct hot predicates —
  # `content_path IS NULL` (still downloading) and `content_path IS NOT NULL` (ready to
  # import) — so, like episodes_wanted_index, a partial index per predicate is a tighter fit
  # than one plain index: each covers only the rows a given poller pass actually visits, and
  # (for grabs) the downloaded index also folds in the `mapping_status == :resolved` filter
  # `list_grabs_downloaded/0` applies, so that query needs no residual per-row check at all.
  def change do
    create index(:movies, [:status])

    create index(:grabs, [:content_path],
             where: "content_path IS NULL",
             name: :grabs_downloading_index
           )

    create index(:grabs, [:content_path],
             where: "content_path IS NOT NULL AND mapping_status = 'resolved'",
             name: :grabs_downloaded_index
           )

    create index(:book_grabs, [:content_path],
             where: "content_path IS NULL",
             name: :book_grabs_downloading_index
           )

    create index(:book_grabs, [:content_path],
             where: "content_path IS NOT NULL",
             name: :book_grabs_downloaded_index
           )
  end
end
