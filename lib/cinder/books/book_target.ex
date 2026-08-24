defmodule Cinder.Books.BookTarget do
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Books.Work
  alias Cinder.Catalog.Profile
  alias Cinder.LibraryKind

  @book_media_kinds LibraryKind.all() -- LibraryKind.video()
  @statuses [:unmonitored, :monitored, :available, :held]

  schema "book_targets" do
    belongs_to :work, Work
    field :media_kind, Ecto.Enum, values: @book_media_kinds
    field :status, Ecto.Enum, values: @statuses, default: :unmonitored
    belongs_to :profile, Profile
    field :hold_reason, :string

    timestamps(type: :utc_datetime)
  end

  def create_changeset(target, attrs) do
    target
    |> cast(attrs, [:media_kind, :status, :profile_id, :hold_reason])
    |> validate_required([:work_id, :media_kind, :status])
    |> validate_hold_reason()
    |> add_constraints()
    |> unique_constraint([:work_id, :media_kind])
  end

  def transition_changeset(target, attrs) do
    changeset = cast(target, attrs, [:status, :hold_reason])

    changeset =
      case {target.status, get_change(changeset, :status),
            Map.has_key?(attrs, :hold_reason) or Map.has_key?(attrs, "hold_reason")} do
        {:held, status, false} when status not in [nil, :held] ->
          put_change(changeset, :hold_reason, nil)

        _other ->
          changeset
      end

    changeset
    |> validate_required([:status])
    |> validate_hold_reason()
    |> add_constraints()
  end

  defp add_constraints(changeset) do
    changeset
    |> check_constraint(:status, name: :book_targets_status_valid)
    |> check_constraint(:media_kind, name: :book_targets_media_kind_valid)
    |> check_constraint(:profile_id, name: :book_targets_profile_integrity)
    |> foreign_key_constraint(:work_id)
    |> foreign_key_constraint(:profile_id)
  end

  defp validate_hold_reason(changeset) do
    case {get_field(changeset, :status), get_field(changeset, :hold_reason)} do
      {:held, nil} ->
        add_error(changeset, :hold_reason, "can't be blank when held")

      {status, reason} when status != :held and not is_nil(reason) ->
        add_error(changeset, :hold_reason, "must be blank unless held")

      _valid ->
        changeset
    end
  end
end
