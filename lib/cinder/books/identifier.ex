defmodule Cinder.Books.Identifier do
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Books.{Author, Edition, Work}

  schema "book_identifiers" do
    belongs_to :author, Author
    belongs_to :work, Work
    belongs_to :edition, Edition
    field :provider, :string
    field :kind, :string
    field :foreign_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(identifier, attrs) do
    identifier
    |> cast(attrs, [:provider, :kind, :foreign_id])
    |> validate_required([:provider, :kind, :foreign_id])
    |> check_constraint(:author_id, name: :book_identifiers_one_subject)
    |> unique_constraint([:provider, :kind, :foreign_id])
    |> foreign_key_constraint(:author_id)
    |> foreign_key_constraint(:work_id)
    |> foreign_key_constraint(:edition_id)
  end
end
