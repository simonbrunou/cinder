defmodule Cinder.Books.SeriesMembership do
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Books.Work

  schema "book_series_memberships" do
    belongs_to :work, Work
    field :name, :string
    field :position, :string
    field :provider, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:name, :position, :provider])
    |> validate_required([:work_id, :name, :provider])
    |> foreign_key_constraint(:work_id)
  end
end
