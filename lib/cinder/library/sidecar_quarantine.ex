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
  import Ecto.Query, only: [from: 2]

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
  already failed once, and reached from `Cinder.Library.commit_stage/1` AFTER the catalog write
  has committed, so it must never fail the caller: a bookkeeping row cannot be allowed to skip
  the media-server refresh and the journal commit that follow it. Any insert failure is logged
  and swallowed and this always returns `:ok` — `catch` alongside `rescue` because a
  pool-checkout timeout exits rather than raising (the same pairing `Cinder.Health.safely/1`
  uses for the same reason).
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
  catch
    kind, value ->
      Logger.warning("sidecar quarantine record failed for #{path}: #{inspect({kind, value})}")
      :ok
  end

  @doc """
  Every row whose quarantine file still exists on disk. A row whose file is gone is deleted here
  rather than left to accumulate — its disappearance is exactly the operator having already dealt
  with it. A stat error that is not `:enoent` keeps the row: a temporarily unreachable mount must
  not silently drop the only record of a retained file.

  The prune is one `delete_all` on the ids that vanished, not a `Repo.delete/2` per row: two
  `/dashboard` mounts can read the same gone-file row concurrently, and the second `Repo.delete/2`
  would raise `Ecto.StaleEntryError`, which `Cinder.Health`'s `safely/1` turns into a skipped row
  — the whole finding silently missing from that render, which is the one thing issue #585 exists
  to prevent.
  """
  def list_present do
    {present, missing} =
      __MODULE__
      |> Repo.all()
      |> Enum.split_with(&present?/1)

    prune(Enum.map(missing, & &1.id))
    present
  end

  defp prune([]), do: :ok

  defp prune(ids) do
    Repo.delete_all(from(row in __MODULE__, where: row.id in ^ids))
    :ok
  end

  defp present?(%__MODULE__{path: path}) do
    case fs().lstat(path) do
      {:ok, _stat} -> true
      {:error, :enoent} -> false
      {:error, _reason} -> true
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
