defmodule Cinder.Catalog.Grab do
  @moduledoc """
  An in-flight download serving one or more `Cinder.Catalog.Episode`s (a single episode or
  a season pack). `content_path` nil ⇒ still downloading; set ⇒ downloaded and ready to
  import. Clean grabs are deleted after import; standard-TV grabs with residual videos and Anime
  mapping/verification holds stay durable until their guarded recovery action runs.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Catalog.{Episode, GrabFile}

  schema "grabs" do
    field :download_id, :string
    field :download_protocol, Ecto.Enum, values: [:torrent, :usenet]
    field :release_title, :string
    field :content_path, :string
    field :download_attempts, :integer, default: 0
    field :download_progress, :float
    field :download_speed, :integer
    field :download_eta, :integer
    field :download_progress_at, :utc_datetime
    field :mapping_snapshot, :map
    field :release_policy_snapshot, :map

    field :mapping_status, Ecto.Enum,
      values: [:resolved, :needs_mapping, :verification_blocked],
      default: :resolved

    field :mapping_issue, :map

    # Set by the unattended upgrade sweep: this grab's swaps are decided at import, per episode,
    # against what each one already holds. False (the manual path, and every grab predating #250)
    # forces the swap — the operator picked that release, possibly for something ranking can't see.
    field :arbitrate_at_import, :boolean, default: false

    has_many :episodes, Episode
    has_many :grab_files, GrabFile

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
    |> advance_download_progress_at(grab)
    |> validate_required([:download_id, :download_protocol])
  end

  defp advance_download_progress_at(changeset, %__MODULE__{} = grab) do
    progress = get_field(changeset, :download_progress)
    content_path = get_field(changeset, :content_path)

    if is_nil(grab.id) or is_nil(content_path) != is_nil(grab.content_path) or
         progress_advanced?(grab.download_progress, progress) do
      force_change(changeset, :download_progress_at, DateTime.utc_now(:second))
    else
      changeset
    end
  end

  defp progress_advanced?(previous, current) when is_number(current),
    do: current > (previous || 0)

  defp progress_advanced?(_previous, _current), do: false

  @doc false
  def reservation_changeset(%__MODULE__{id: nil} = grab, attrs) do
    grab
    |> changeset(attrs)
    |> cast(attrs, [:mapping_snapshot, :release_policy_snapshot, :mapping_status])
  end

  def reservation_changeset(%__MODULE__{} = grab, attrs) do
    grab
    |> changeset(attrs)
    |> add_error(:mapping_snapshot, "is immutable")
    |> add_error(:release_policy_snapshot, "is immutable")
  end

  @doc false
  def mapping_changeset(grab, attrs) do
    cast(grab, attrs, [:mapping_status, :mapping_issue])
  end
end
