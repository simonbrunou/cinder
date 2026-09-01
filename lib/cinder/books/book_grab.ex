defmodule Cinder.Books.BookGrab do
  @moduledoc """
  An in-flight download for one `Cinder.Books.BookTarget`.

  The books sibling of `Cinder.Catalog.Grab`, and a separate table rather than transient columns
  on `book_targets`: the parity contract locks that table's status vocabulary to
  `unmonitored | monitored | available | held`, so there is no `:downloading` state to move a
  target into. The target stays `:monitored` for the whole download — exactly what the contract
  says `monitored` means — and this row carries the transient state.

  `content_path` nil ⇒ still downloading; set ⇒ downloaded and ready to import. The row is
  deleted after a committed import, so its unique `book_target_id` index means "one in-flight
  download per target" without needing a lifecycle flag.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Books.BookTarget

  schema "book_grabs" do
    belongs_to :book_target, BookTarget
    field :download_id, :string
    field :download_protocol, Ecto.Enum, values: [:torrent, :usenet]
    field :release_title, :string
    field :content_path, :string
    field :import_attempts, :integer, default: 0
    field :download_progress, :float
    field :download_speed, :integer
    field :download_eta, :integer
    field :download_progress_at, :utc_datetime
    field :replace, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(grab, attrs) do
    grab
    |> cast(attrs, [
      :book_target_id,
      :download_id,
      :download_protocol,
      :release_title,
      :content_path,
      :import_attempts,
      :download_progress,
      :download_speed,
      :download_eta,
      :replace
    ])
    |> advance_download_progress_at(grab)
    |> validate_required([:book_target_id, :download_id, :download_protocol])
    |> check_constraint(:download_protocol, name: :book_grabs_download_protocol_valid)
    |> foreign_key_constraint(:book_target_id)
    |> unique_constraint(:book_target_id)
    |> unique_constraint([:download_id, :download_protocol],
      name: :book_grabs_download_id_download_protocol_index,
      error_key: :download_id
    )
  end

  # Mirrors `Cinder.Catalog.Grab`: the progress clock advances on real forward motion or on the
  # completion edge, never on a speed/ETA-only write, so a stall reaper reading it cannot be
  # fooled by a client that reports churn without progress.
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
end
