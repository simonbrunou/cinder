defmodule Cinder.Requests.Request do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog.Profile
  alias Cinder.LibraryKind

  @statuses [:pending, :approved, :denied]
  # The polymorphic request target. Movies are the only writer today; series/episode are
  # reserved for the TV requester flow (M5+). An allowlist keeps a typo'd discriminator out of
  # the DB before a second writer (or its dispatch) exists to trip over it.
  @target_types ["movie", "series", "season", "episode", "book"]
  @book_media_kinds LibraryKind.books()

  schema "requests" do
    field :target_type, :string
    field :target_id, :integer
    field :season_number, :integer
    # The books contract monitors at (work, media_kind), so a book request must name which of
    # the two kinds it wants. Exactly the "book" target type carries one.
    field :media_kind, Ecto.Enum, values: @book_media_kinds
    field :title, :string
    field :localizations, :map, default: %{}
    field :year, :integer
    field :poster_path, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :denial_reason, :string
    field :original_language, :string
    field :preferred_language, :string
    field :proposed_media_profile, Ecto.Enum, values: [:standard, :anime]
    belongs_to :proposed_profile, Profile
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
      :media_kind,
      :title,
      :localizations,
      :year,
      :poster_path,
      :status,
      :approved_by_id,
      :original_language,
      :preferred_language,
      :proposed_media_profile,
      :proposed_profile_id
    ])
    |> validate_required([:user_id, :target_type, :target_id, :status])
    |> validate_inclusion(:target_type, @target_types)
    |> validate_media_kind()
    |> validate_inclusion(:preferred_language, Language.preferences())
    |> check_constraint(:proposed_profile_id, name: :requests_profile_integrity)
    # The constraint name must match the SQLite index name exactly as reported by exqlite
    # on a UNIQUE violation. The partial index keeps its historical :requests_pending_unique
    # name even though it covers pending and approved rows; exqlite reports that name directly.
    # Using a wrong name would make a duplicate-active violation raise instead of returning
    # {:error, changeset}.
    |> unique_constraint([:user_id, :target_type, :target_id],
      name: :requests_pending_unique
    )
  end

  # Symmetric, and changeset-only: `target_type`'s own allowlist is too, and adding a table
  # CHECK to `requests` would mean a full SQLite rebuild for a rule no other writer can break.
  defp validate_media_kind(changeset) do
    case {get_field(changeset, :target_type), get_field(changeset, :media_kind)} do
      {"book", nil} -> add_error(changeset, :media_kind, "can't be blank for a book request")
      {"book", _kind} -> changeset
      {_type, nil} -> changeset
      {_type, _kind} -> add_error(changeset, :media_kind, "is only valid for a book request")
    end
  end

  def profile_changeset(request, attrs) do
    request
    |> cast(attrs, [:proposed_media_profile, :proposed_profile_id])
    |> foreign_key_constraint(:proposed_profile_id)
    |> check_constraint(:proposed_profile_id, name: :requests_profile_integrity)
  end

  def status_changeset(request, attrs) do
    request
    |> cast(attrs, [
      :status,
      :denial_reason,
      :approved_by_id,
      :proposed_media_profile,
      :proposed_profile_id
    ])
    |> validate_required([:status])
    |> foreign_key_constraint(:proposed_profile_id)
    # reopen_request/2 moves a denied row back to :pending, which can collide on the partial
    # requests_pending_unique index; map that to {:error, changeset} rather than raising.
    |> unique_constraint([:user_id, :target_type, :target_id], name: :requests_pending_unique)
  end
end
