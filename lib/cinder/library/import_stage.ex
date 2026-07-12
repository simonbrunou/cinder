defmodule Cinder.Library.ImportStage do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Cinder.Repo

  schema "import_stages" do
    field :operation_key, :string

    field :state, Ecto.Enum,
      values: [:preparing, :prepared, :committed, :rolling_back, :cleaning, :quarantined],
      default: :preparing

    field :kind, Ecto.Enum, values: [:placement, :noop], default: :placement
    field :recovery_action, Ecto.Enum, values: [:rollback, :cleanup]
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
    field :attempt_count, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :effects_claimed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [
      :operation_key,
      :state,
      :kind,
      :recovery_action,
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
      :last_error,
      :attempt_count,
      :next_attempt_at,
      :effects_claimed_at
    ])
    |> validate_required([:operation_key, :state, :root, :dest, :candidate])
    |> unique_constraint(:operation_key)
    |> unique_constraint(:dest)
  end

  def create(attrs), do: %__MODULE__{} |> changeset(attrs) |> Repo.insert()
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
           set: [
             state: :committed,
             recovery_action: nil,
             next_attempt_at: nil,
             last_error: nil,
             updated_at: DateTime.utc_now(:second)
           ]
         ) do
      {count, _} when count == length(ids) -> :ok
      _ -> Repo.rollback(:stale_import_stage)
    end
  end

  @lease_seconds 30

  def claim(id, from_states, state, recovery_action) do
    now = DateTime.utc_now(:second)

    result =
      Repo.update_all(
        from(s in __MODULE__,
          where: s.id == ^id and s.state in ^from_states,
          select: s
        ),
        set: [
          state: state,
          recovery_action: recovery_action,
          next_attempt_at: DateTime.add(now, @lease_seconds),
          updated_at: now
        ]
      )

    claimed_result(result, state)
  end

  def claim_retry(id, state) do
    now = DateTime.utc_now(:second)

    result =
      Repo.update_all(
        from(s in __MODULE__,
          where:
            s.id == ^id and s.state == ^state and
              (is_nil(s.next_attempt_at) or s.next_attempt_at <= ^now),
          select: s
        ),
        set: [next_attempt_at: DateTime.add(now, @lease_seconds), updated_at: now]
      )

    claimed_result(result, state)
  end

  def claim_effects(id) do
    now = DateTime.utc_now(:second)

    case Repo.update_all(
           from(s in __MODULE__,
             where:
               s.id == ^id and is_nil(s.effects_claimed_at) and
                 (s.state in [:committed, :cleaning] or
                    (s.state == :quarantined and s.recovery_action == :cleanup)),
             select: s
           ),
           set: [effects_claimed_at: now, updated_at: now]
         ) do
      {1, [stage]} -> {:claimed, stage}
      {0, _} -> {:not_claimed, get(id)}
    end
  end

  defp claimed_result({1, [stage]}, state) do
    pause_after_claim(stage, state)
    {:claimed, stage}
  end

  defp claimed_result({0, _}, _state), do: :not_claimed

  defp pause_after_claim(stage, state) do
    case Application.get_env(:cinder, :import_stage_claim_barrier) do
      %{owner: owner, state: ^state} = barrier ->
        if Map.get(barrier, :once, false),
          do: Application.delete_env(:cinder, :import_stage_claim_barrier)

        ref = make_ref()
        send(owner, {:import_stage_claim_barrier, self(), ref, stage.id, state})
        receive do: ({^ref, :continue} -> :ok)

      _ ->
        :ok
    end
  end

  def with_destination_lock(dest, fun),
    do: :global.trans({{__MODULE__, :destination}, dest}, fun)

  def with_lock(operation_key, fun),
    do: :global.trans({{__MODULE__, :operation}, operation_key}, fun)
end
