defmodule Cinder.Requests.Request do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :approved, :denied]
  # The polymorphic request target. Movies are the only writer today; series/episode are
  # reserved for the TV requester flow (M5+). An allowlist keeps a typo'd discriminator out of
  # the DB before a second writer (or its dispatch) exists to trip over it.
  @target_types ["movie", "series", "season", "episode"]

  schema "requests" do
    field :target_type, :string
    field :target_id, :integer
    field :season_number, :integer
    field :title, :string
    field :year, :integer
    field :poster_path, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :denial_reason, :string
    field :original_language, :string
    field :preferred_language, :string
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
      :season_number,
      :title,
      :year,
      :poster_path,
      :status,
      :approved_by_id,
      :original_language,
      :preferred_language
    ])
    |> validate_required([:user_id, :target_type, :target_id, :status])
    |> validate_inclusion(:target_type, @target_types)
    |> validate_inclusion(:preferred_language, ["original", "french", "any"])
    # The constraint name must match the SQLite index name exactly as reported by exqlite
    # on a UNIQUE violation. The partial index is named :requests_pending_unique in the
    # migration; exqlite reports that name directly so we use it here. Using a wrong name
    # would cause a duplicate-pending violation to raise instead of returning {:error, changeset}.
    |> unique_constraint([:user_id, :target_type, :target_id],
      name: :requests_pending_unique
    )
  end

  def status_changeset(request, attrs) do
    request
    |> cast(attrs, [:status, :denial_reason, :approved_by_id])
    |> validate_required([:status])
  end
end
