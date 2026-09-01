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
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Acquisition.BookScorer
  alias Cinder.Books.{BookTarget, Edition}

  schema "book_files" do
    belongs_to :book_target, BookTarget
    belongs_to :edition, Edition
    field :path, :string
    field :size, :integer
    field :format, Ecto.Enum, values: BookScorer.accepted_formats()

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(file, attrs) do
    file
    |> cast(attrs, [:book_target_id, :edition_id, :path, :size, :format])
    |> validate_required([:book_target_id, :path, :format])
    |> check_constraint(:format, name: :book_files_format_valid)
    |> foreign_key_constraint(:book_target_id)
    |> foreign_key_constraint(:edition_id)
    |> unique_constraint(:path)
  end
end
