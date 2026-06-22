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
    field :content_path, :string
    field :download_attempts, :integer, default: 0
    has_many :episodes, Episode

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(grab, attrs) do
    grab
    |> cast(attrs, [:download_id, :download_protocol, :content_path, :download_attempts])
    |> validate_required([:download_id, :download_protocol])
  end
end
