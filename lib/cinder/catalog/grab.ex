defmodule Cinder.Catalog.Grab do
  @moduledoc """
  An in-flight download serving one or more `Cinder.Catalog.Episode`s (a single episode or
  a season pack). `content_path` nil ⇒ still downloading; set ⇒ downloaded and ready to
  import. Grabs are transient: deleted once their episodes import (or on a terminal park),
  so the table only ever holds in-flight downloads.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Catalog.Episode

  schema "grabs" do
    field :download_id, :string
    field :download_protocol, Ecto.Enum, values: [:torrent, :usenet]
    field :release_title, :string
    field :content_path, :string
    field :download_attempts, :integer, default: 0
    field :download_progress, :float
    field :download_speed, :integer
    field :download_eta, :integer
    field :mapping_snapshot, :map
    field :release_policy_snapshot, :map
    field :mapping_status, Ecto.Enum, values: [:resolved, :needs_mapping], default: :resolved
    field :automatic_mapping_decisions, :map
    field :manual_mapping_overrides, :map
    field :mapping_issue, :map
    has_many :episodes, Episode

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(grab, attrs) do
    grab
    |> cast(attrs, [
      :download_id,
      :download_protocol,
      :release_title,
      :content_path,
      :download_attempts,
      :download_progress,
      :download_speed,
      :download_eta
    ])
    |> validate_required([:download_id, :download_protocol])
  end

  @doc false
  def reservation_changeset(%__MODULE__{id: nil} = grab, attrs) do
    grab
    |> changeset(attrs)
    |> cast(attrs, [:mapping_snapshot, :mapping_status])
  end

  def reservation_changeset(%__MODULE__{} = grab, attrs) do
    grab
    |> changeset(attrs)
    |> add_error(:mapping_snapshot, "is immutable")
  end

  @doc false
  def mapping_changeset(grab, attrs) do
    cast(grab, attrs, [
      :mapping_status,
      :automatic_mapping_decisions,
      :manual_mapping_overrides,
      :mapping_issue
    ])
  end
end
