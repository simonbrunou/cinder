defmodule Cinder.Books.Credit do
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Books.{Author, Edition, Work}

  schema "book_credits" do
    belongs_to :author, Author
    belongs_to :work, Work
    belongs_to :edition, Edition
    field :role, :string
    field :position, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(credit, attrs) do
    credit
    |> cast(attrs, [:role, :position])
    |> validate_required([:author_id, :role, :position])
    |> check_constraint(:work_id, name: :book_credits_one_subject)
    |> unique_constraint([:work_id, :author_id, :role])
    |> unique_constraint([:edition_id, :author_id, :role])
    |> foreign_key_constraint(:author_id)
    |> foreign_key_constraint(:work_id)
    |> foreign_key_constraint(:edition_id)
  end
end
