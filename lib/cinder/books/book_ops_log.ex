defmodule Cinder.Books.BookOpsLog do
  @moduledoc """
  A durable, best-effort operational log for book-pipeline events with no other durable
  record: a duplicate grab attempt (`Cinder.Books.Grabs.create/5`'s unique-index fence), a
  metadata drift observed by `Cinder.Books.Refresher`, and an Audiobookshelf scan
  failure/recovery observed by `Cinder.Download.BookPoller`'s scan phase (`AudiobookServer`,
  B7c).

  Write-only from the pipeline's perspective: nothing here gates a decision, it exists only
  so an operator dogfooding an unattended run has something to read on `/library`.

  `book_target_id` is nullable (`on_delete: :nilify_all`) so a row outlives a deleted target,
  since there is no book-target deletion feature today, but the column is written defensively
  against a future one, exactly like `Cinder.Books.BookBlockedRelease`. A `metadata_drift` row
  is never associated with one target at all: a work can carry zero, one, or two targets
  (ebook/audiobook), and the drift belongs to the work, not any one of them.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Books.BookTarget

  @categories ~w(duplicate_grab_refused metadata_drift scan_failure scan_recovered)

  schema "book_ops_log" do
    belongs_to :book_target, BookTarget
    field :category, :string
    field :detail, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:book_target_id, :category, :detail])
    |> validate_required([:category, :detail])
    |> validate_inclusion(:category, @categories)
    |> foreign_key_constraint(:book_target_id)
  end
end
