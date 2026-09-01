defmodule Cinder.Books.BookTarget do
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Acquisition.Parser
  alias Cinder.Books.Work
  alias Cinder.Catalog.Profile
  alias Cinder.LibraryKind

  @book_media_kinds LibraryKind.books()
  @statuses [:unmonitored, :monitored, :available, :held]
  @known_languages Map.keys(Parser.language_tags())

  schema "book_targets" do
    belongs_to :work, Work
    field :media_kind, Ecto.Enum, values: @book_media_kinds
    field :status, Ecto.Enum, values: @statuses, default: :unmonitored
    belongs_to :profile, Profile
    field :hold_reason, :string
    field :preferred_language, :string

    timestamps(type: :utc_datetime)
  end

  def create_changeset(target, attrs) do
    target
    |> cast(attrs, [:media_kind, :profile_id])
    |> validate_required([:work_id, :media_kind, :status])
    |> add_constraints()
    |> unique_constraint([:work_id, :media_kind])
  end

  @doc """
  Changeset for the admin's language pick — independent of the status pipeline, unlike
  `transition_changeset/2`: never touches `:status` and carries no precondition, so it's safe to
  call regardless of where the target is in its lifecycle. `nil` (no preference) or a code
  `Cinder.Acquisition.Parser.language_tags/0` knows — the same table the `/books/:id` picker is
  built from and `BookScorer.tag_for/1` resolves against — so a value that reaches this changeset
  by any path other than that picker (a forged LiveView event, an API caller) can't wedge the
  target into a language `check_language/2` will never match. `validate_inclusion/3` treats `nil`
  as a member of its own allowed list here, not as "skip validation" — both must be spelled out.
  """
  def language_changeset(target, attrs) do
    target
    |> cast(attrs, [:preferred_language])
    |> validate_inclusion(:preferred_language, [nil | @known_languages])
  end

  @doc """
  The guarded-write changeset. Carries `:profile_id` alongside the status so an approval can
  attach the profile and arm the target in one write — two writes would mean two broadcasts and
  a window where a target is monitored with no profile to score against.
  """
  def transition_changeset(target, attrs) do
    changeset = cast(target, attrs, [:status, :hold_reason, :profile_id])

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
    |> check_constraint(:hold_reason, name: :book_targets_hold_reason_valid)
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
