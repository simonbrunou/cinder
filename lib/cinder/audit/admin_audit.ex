defmodule Cinder.Audit.AdminAudit do
  @moduledoc """
  An append-only record of one destructive admin action (who/what/when). `detail`
  is a free-form map (stored as JSON TEXT by ecto_sqlite3). Rows are immutable —
  `inserted_at` only, no `updated_at`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Accounts.User

  schema "admin_audit" do
    field :action, :string
    field :entity_type, :string
    field :entity_id, :integer
    field :detail, :map, default: %{}
    belongs_to :actor, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(audit, attrs) do
    audit
    |> cast(attrs, [:actor_id, :action, :entity_type, :entity_id, :detail])
    |> validate_required([:action, :entity_type])
  end
end
