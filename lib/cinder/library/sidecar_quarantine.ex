defmodule Cinder.Library.SidecarQuarantine do
  @moduledoc """
  A durable record of every sidecar quarantine file `Cinder.Library.Sidecars` could not prove it
  owned and therefore left on disk at `.cinder-sidecar-quarantine-<token>` (issue #585). A row
  never causes an automatic sweep, rename, or delete: the file it names might be a third party's
  bytes, so retention itself stays exactly what it is today — this table exists only so
  `Cinder.Health` can surface a row's path, since the path is otherwise known only at the moment
  retention happens and would vanish with log rotation.
  """
  use Ecto.Schema

  import Ecto.Changeset

  require Logger

  alias Cinder.Repo

  schema "sidecar_quarantines" do
    field :path, :string
    field :destination, :string
    field :reason, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Upserts a retention row keyed on `path`. Called from inside the reclaim path right after it has
  already failed once, so it must never itself fail the caller — any insert error is logged and
  swallowed, and this always returns `:ok`.
  """
  def record(destination, path, reason) do
    now = DateTime.utc_now(:second)

    %__MODULE__{}
    |> changeset(%{path: path, destination: destination, reason: reason})
    |> Repo.insert(
      on_conflict: [set: [destination: destination, reason: reason, updated_at: now]],
      conflict_target: :path
    )
    |> case do
      {:ok, _row} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "sidecar quarantine record failed for #{path}: #{inspect(changeset.errors)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning("sidecar quarantine record failed for #{path}: #{inspect(error)}")
      :ok
  end

  @doc """
  Every row whose quarantine file still exists on disk. A row whose file is gone is deleted here
  rather than left to accumulate — its disappearance is exactly the operator having already dealt
  with it. A stat error that is not `:enoent` keeps the row: a temporarily unreachable mount must
  not silently drop the only record of a retained file.
  """
  def list_present do
    Repo.all(__MODULE__)
    |> Enum.filter(&present?/1)
  end

  defp present?(%__MODULE__{path: path} = row) do
    case fs().lstat(path) do
      {:ok, _stat} ->
        true

      {:error, :enoent} ->
        Repo.delete(row)
        false

      {:error, _reason} ->
        true
    end
  end

  defp changeset(row, attrs) do
    row
    |> cast(attrs, [:path, :destination, :reason])
    |> validate_required([:path, :destination, :reason])
    |> unique_constraint(:path)
  end

  defp fs, do: Application.get_env(:cinder, :filesystem)
end
