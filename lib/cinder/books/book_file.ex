defmodule Cinder.Books.BookFile do
  @moduledoc """
  One imported book asset on disk.

  The contract's File boundary: "Belongs to one edition and one media kind. Internal Cinder ID;
  checksum is evidence, never catalog identity."

  `edition_id` is **nullable on purpose**. The same contract forbids resolving identity from "a
  title, ISBN, ASIN, path, or filename alone", and a release name usually carries nothing that
  names an edition. A null is the contract's "explicitly incomplete" signal; picking an arbitrary
  edition to satisfy a foreign key would be exactly the silent fallback the contract exists to
  prevent. The media kind comes from the owning target, which already carries it — duplicating it
  here would let the two disagree.

  ## Audiobook file-level facts

  `narrator`, `duration_seconds`, `track_number`, `disc_number`, and `chapter_count` (added in
  B7a) describe the imported FILE, not the edition. Two rips of the same recording can
  legitimately carry a different narrator credit (rare, but the reason this rides on the file
  rather than a re-derivation from `edition_id`, which is nullable anyway per the note above), and
  a multi-track audiobook can legitimately split into a different number of tracks across two
  different rips of the same work. All five are `nil` for an e-book file, unchanged behavior.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Acquisition.{AudiobookScorer, BookScorer}
  alias Cinder.Books.{BookTarget, Edition}

  schema "book_files" do
    belongs_to :book_target, BookTarget
    belongs_to :edition, Edition
    field :path, :string
    field :size, :integer

    field :format, Ecto.Enum,
      values: BookScorer.accepted_formats() ++ AudiobookScorer.accepted_formats()

    field :narrator, :string
    field :duration_seconds, :integer
    field :track_number, :integer
    field :disc_number, :integer
    field :chapter_count, :integer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(file, attrs) do
    file
    |> cast(attrs, [
      :book_target_id,
      :edition_id,
      :path,
      :size,
      :format,
      :narrator,
      :duration_seconds,
      :track_number,
      :disc_number,
      :chapter_count
    ])
    |> validate_required([:book_target_id, :path, :format])
    |> check_constraint(:format, name: :book_files_format_valid)
    |> foreign_key_constraint(:book_target_id)
    |> foreign_key_constraint(:edition_id)
    |> unique_constraint(:path)
  end
end
