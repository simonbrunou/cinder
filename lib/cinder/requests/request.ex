defmodule Cinder.Requests.Request do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :approved, :denied]
  # The polymorphic request target. Movies are the only writer today; series/episode are
  # reserved for the TV requester flow (M5+). An allowlist keeps a typo'd discriminator out of
  # the DB before a second writer (or its dispatch) exists to trip over it.
  @target_types ["movie", "series", "episode"]

  schema "requests" do
    field :target_type, :string
    field :target_id, :integer
    field :title, :string
    field :year, :integer
    field :poster_path, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :denial_reason, :string
    belongs_to :user, Cinder.Accounts.User
    belongs_to :approved_by, Cinder.Accounts.User
    timestamps()
  end

  def create_changeset(request, attrs) do
    request
    |> cast(attrs, [
      :user_id,
      :target_type,
      :target_id,
      :title,
      :year,
      :poster_path,
      :status,
      :approved_by_id
    ])
    |> validate_required([:user_id, :target_type, :target_id, :status])
    |> validate_inclusion(:target_type, @target_types)
    # The constraint name is intentionally column-derived, NOT the migration's
    # :requests_pending_unique partial-index name. exqlite reports the column-derived
    # name when a duplicate is caught; using :requests_pending_unique here would turn
    # the duplicate-pending catch into a raise instead of a changeset error.
    |> unique_constraint([:user_id, :target_type, :target_id],
      name: :requests_user_id_target_type_target_id_index
    )
  end

  def status_changeset(request, attrs) do
    request
    |> cast(attrs, [:status, :denial_reason, :approved_by_id])
    |> validate_required([:status])
  end
end
