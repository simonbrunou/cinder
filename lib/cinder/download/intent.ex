defmodule Cinder.Download.Intent do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  schema "download_intents" do
    field :operation_key, :string
    field :kind, Ecto.Enum, values: [:movie, :episode, :season_pack]
    field :target_id, :integer
    field :episode_ids, {:array, :integer}, default: []
    field :protocol, Ecto.Enum, values: [:torrent, :usenet]
    field :release, :map
    field :status, Ecto.Enum, values: [:reserved, :submitted], default: :reserved
    field :remote_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(intent, attrs) do
    intent
    |> cast(attrs, [
      :operation_key,
      :kind,
      :target_id,
      :episode_ids,
      :protocol,
      :release,
      :status,
      :remote_id
    ])
    |> validate_required([:operation_key, :kind, :target_id, :protocol, :release, :status])
    |> unique_constraint(:operation_key)
  end
end
