defmodule Cinder.Subtitles.TrackProbe do
  @moduledoc """
  A video's text subtitle tracks, kept per file (moviehash). Listing them with their cue counts
  reads the whole file, and `Cinder.Subtitles` asks on every sweep for each video that may carry
  its own track (`Cinder.Subtitles.OwnTrack`), so the answer is stored once per file. A failed probe
  is not stored, so it is retried.
  """
  use Ecto.Schema

  import Ecto.Changeset

  require Logger

  alias Cinder.Repo

  schema "subtitle_track_probes" do
    field :moviehash, :string
    field :tracks, {:array, :map}

    timestamps(type: :utc_datetime)
  end

  @keys ~w(index language default? forced? hearing_impaired? packet_count)a

  @doc """
  The tracks of the file identified by `moviehash`, from the store or from `probe` (stored on
  success). Without a moviehash nothing can be stored, so `probe` runs.
  """
  @spec tracks(String.t() | nil, (-> {:ok, [map()]} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def tracks(nil, probe), do: probe.()

  def tracks(moviehash, probe) do
    case Repo.get_by(__MODULE__, moviehash: moviehash) do
      %__MODULE__{tracks: tracks} ->
        {:ok, Enum.map(tracks, &decode/1)}

      nil ->
        with {:ok, tracks} <- probe.() do
          store(moviehash, tracks)
          {:ok, tracks}
        end
    end
  end

  defp store(moviehash, tracks) do
    %__MODULE__{}
    |> change(moviehash: moviehash, tracks: Enum.map(tracks, &Map.take(&1, @keys)))
    |> unique_constraint(:moviehash)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :moviehash)
    |> case do
      {:ok, _row} ->
        :ok

      {:error, changeset} ->
        Logger.warning("track probe store failed: #{inspect(changeset.errors)}")
    end
  end

  # Stored as JSON, read back with string keys. A key the probe did not report stays absent, so a
  # `Map.get/3` default still applies (a nil packet count would compare above any number).
  defp decode(track) do
    Enum.reduce(@keys, %{}, fn key, acc ->
      case Map.fetch(track, Atom.to_string(key)) do
        {:ok, value} when not is_nil(value) -> Map.put(acc, key, value)
        _absent -> acc
      end
    end)
  end
end
