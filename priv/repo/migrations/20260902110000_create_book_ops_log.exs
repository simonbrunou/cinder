defmodule Cinder.Repo.Migrations.CreateBookOpsLog do
  use Ecto.Migration

  def change do
    # A durable, best-effort operational log for book-pipeline events with no other durable
    # record (B8b) — duplicate grab attempts and metadata drift today, scan failures/recovery
    # once B7c's AudiobookServer lands (schema-ready, no write site yet). `book_target_id` is
    # nullable (`nilify_all`) so a row outlives a deleted target, exactly like
    # `book_blocked_releases`' own FK — there is no book-target deletion feature today, but the
    # column is written defensively against a future one.
    create table(:book_ops_log) do
      add :book_target_id, references(:book_targets, on_delete: :nilify_all)
      add :category, :string, null: false
      add :detail, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:book_ops_log, [:category])
    create index(:book_ops_log, [:inserted_at])
  end
end
