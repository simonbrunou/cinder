defmodule Cinder.Download.IntentEpisode do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  schema "download_intent_episodes" do
    field :episode_id, :integer
    belongs_to :intent, Cinder.Download.Intent
  end

  def changeset(reservation, attrs) do
    reservation
    |> cast(attrs, [:intent_id, :episode_id])
    |> validate_required([:intent_id, :episode_id])
    |> foreign_key_constraint(:intent_id)
    |> unique_constraint(:episode_id)
  end
end
