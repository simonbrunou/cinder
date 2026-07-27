defmodule Cinder.Catalog.GrabFile do
  @moduledoc """
  A video left unresolved after the standard TV importer commits a grab's clean matches.

  Device/inode identity and the relative path keep repeated poller ticks and restarts
  idempotent. Resolution is deliberately per-file; Anime's grab-wide mapping state is separate.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Catalog.{Episode, Grab}
  alias Cinder.Library.ImportStage

  schema "grab_files" do
    field :relative_path, :string
    field :size, :integer
    field :device, :integer
    field :inode, :integer
    field :source, :string
    field :scheme, :string
    field :namespace, :string
    field :canonical_value, :string
    field :decision, Ecto.Enum, values: [:fold, :part]
    field :destination, :string
    belongs_to :grab, Grab
    belongs_to :episode, Episode
    belongs_to :import_stage, ImportStage

    timestamps(type: :utc_datetime)
  end

  def changeset(grab_file, attrs) do
    grab_file
    |> cast(attrs, [
      :grab_id,
      :relative_path,
      :size,
      :device,
      :inode,
      :source,
      :scheme,
      :namespace,
      :canonical_value,
      :episode_id,
      :decision,
      :destination,
      :import_stage_id
    ])
    |> validate_required([:grab_id, :relative_path, :size, :device, :inode])
    |> validate_number(:size, greater_than_or_equal_to: 0)
    |> unique_constraint([:grab_id, :relative_path])
    |> unique_constraint([:grab_id, :device, :inode])
    |> foreign_key_constraint(:grab_id)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:import_stage_id)
  end
end
