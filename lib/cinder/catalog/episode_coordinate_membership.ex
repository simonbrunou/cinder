defmodule Cinder.Catalog.EpisodeCoordinateMembership do
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Catalog.{Episode, EpisodeCoordinate}

  schema "episode_coordinate_memberships" do
    field :position, :integer
    belongs_to :episode_coordinate, EpisodeCoordinate
    belongs_to :episode, Episode

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:position])
    |> validate_required([:episode_coordinate_id, :episode_id, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:episode_coordinate_id, :episode_id],
      name: :episode_coordinate_memberships_episode_coordinate_id_episode_id_index
    )
    |> unique_constraint([:episode_coordinate_id, :position],
      name: :episode_coordinate_memberships_episode_coordinate_id_position_index
    )
    |> foreign_key_constraint(:episode_coordinate_id)
    |> foreign_key_constraint(:episode_id)
  end
end
