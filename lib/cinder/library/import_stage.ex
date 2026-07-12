defmodule Cinder.Library.ImportStage do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Cinder.Repo

  schema "import_stages" do
    field :operation_key, :string
    field :state, Ecto.Enum, values: [:preparing, :prepared, :committed], default: :preparing
    field :root, :string
    field :dest, :string
    field :candidate, :string
    field :backup, :string
    field :candidate_inode, :integer
    field :candidate_device, :integer
    field :candidate_size, :integer
    field :staged_inode, :integer
    field :staged_device, :integer
    field :staged_size, :integer
    field :backup_inode, :integer
    field :backup_device, :integer
    field :backup_size, :integer
    field :last_error, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [
      :operation_key,
      :state,
      :root,
      :dest,
      :candidate,
      :backup,
      :candidate_inode,
      :candidate_device,
      :candidate_size,
      :staged_inode,
      :staged_device,
      :staged_size,
      :backup_inode,
      :backup_device,
      :backup_size,
      :last_error
    ])
    |> validate_required([:operation_key, :state, :root, :dest, :candidate])
    |> unique_constraint(:operation_key)
  end

  def create!(attrs), do: %__MODULE__{} |> changeset(attrs) |> Repo.insert!()
  def update(stage, attrs), do: stage |> changeset(attrs) |> Repo.update()
  def update!(stage, attrs), do: stage |> changeset(attrs) |> Repo.update!()
  def list, do: Repo.all(__MODULE__)
  def get(id), do: Repo.get(__MODULE__, id)
  def delete(stage), do: Repo.delete(stage)

  def mark_committed!(ids) do
    ids = Enum.uniq(ids)

    case Repo.update_all(
           from(s in __MODULE__, where: s.id in ^ids and s.state == :prepared),
           set: [state: :committed, last_error: nil, updated_at: DateTime.utc_now(:second)]
         ) do
      {count, _} when count == length(ids) -> :ok
      _ -> Repo.rollback(:stale_import_stage)
    end
  end

  def with_lock(operation_key, fun),
    do: :global.trans({__MODULE__, operation_key}, fun)
end
