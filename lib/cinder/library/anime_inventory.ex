defmodule Cinder.Library.AnimeInventory do
  @moduledoc """
  The anime import's file bookkeeping, either side of `Cinder.Library.AnimePreflight`'s
  (pure) reasoning: `build/3` inventories a download — relative path plus stat identity —
  for the preflight to decide on and the grab snapshot to persist, and `same_inventory/2`,
  `same_container_kind/2` and `import_pairs/3` re-validate that snapshot against the disk
  at import time, turning its assignments into `{episode, source}` pairs.

  Re-validation is a separate step on purpose: the snapshot is taken when the operator maps
  the release and acted on later, so a file that moved, changed size or was replaced in
  between must fail as `:inventory_changed` rather than import against a stale decision.

  Split out of `Cinder.Library` as plain code motion to keep that module under
  `code_health_test.exs`'s line cap, as `Deletion` (#256) and `Naming` (#260) were before it.
  """

  alias Cinder.Catalog.Grab
  alias Cinder.Library

  @anime_identity_keys ~w(relative_path size major_device inode mtime)

  def build(videos, content_path, folder?) do
    videos
    |> Enum.reduce_while({:ok, []}, fn {path, _size}, {:ok, files} ->
      case inventory_anime_file(path, content_path, folder?) do
        {:ok, file} -> {:cont, {:ok, [file | files]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.map(files, &inventory_entry/1)}
      {:error, _reason} = error -> error
    end
  end

  defp inventory_anime_file(path, content_path, folder?) do
    with {:ok, source} <- Library.safe_source_file(path),
         {:ok, stat} <- fs().lstat(source),
         {:ok, relative_path} <- Library.inventory_relative_path(source, content_path, folder?) do
      {:ok, {source, relative_path, stat}}
    end
  end

  defp inventory_entry({_source, relative_path, stat}) do
    %{
      relative_path: relative_path,
      identity: %{
        size: stat.size,
        major_device: stat.major_device,
        inode: stat.inode,
        mtime: stat.mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_iso8601()
      }
    }
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)

  def same_container_kind(container?, container?), do: :ok
  def same_container_kind(_current, _persisted), do: {:error, :inventory_changed}

  def same_inventory(current, %{"files" => persisted}) when is_list(persisted) do
    current =
      Enum.map(current, fn %{relative_path: relative_path, identity: identity} ->
        identity
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.put("relative_path", relative_path)
      end)

    persisted = Enum.map(persisted, &Map.take(&1, @anime_identity_keys))

    if sort_inventory(current) == sort_inventory(persisted),
      do: :ok,
      else: {:error, :inventory_changed}
  end

  def same_inventory(_current, _persisted), do: {:error, :inventory_changed}

  defp sort_inventory(files), do: Enum.sort_by(files, & &1["relative_path"])

  def import_pairs(%Grab{} = grab, assignments, folder?) do
    episodes = Map.new(grab.episodes, &{&1.id, &1})

    assignments
    |> Enum.reduce_while({:ok, []}, fn assignment, {:ok, acc} ->
      case anime_assignment_pairs(grab.content_path, folder?, assignment, episodes) do
        {:ok, pairs} -> {:cont, {:ok, Enum.reverse(pairs, acc)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _reason} = error -> error
    end
  end

  defp anime_assignment_pairs(
         content_path,
         folder?,
         %{relative_path: relative_path, episode_ids: episode_ids},
         episodes
       ) do
    with {:ok, source} <- anime_assignment_source(content_path, relative_path, folder?),
         {:ok, assigned} <- assigned_episodes(episode_ids, episodes) do
      {:ok, Enum.map(assigned, &{&1, source})}
    end
  end

  defp anime_assignment_pairs(_content_path, _folder?, _assignment, _episodes),
    do: {:error, :invalid_anime_assignment}

  defp anime_assignment_source(content_path, relative_path, true),
    do: content_path |> Path.join(relative_path) |> revalidate_anime_source()

  defp anime_assignment_source(content_path, relative_path, false) do
    if relative_path == Path.basename(content_path),
      do: revalidate_anime_source(content_path),
      else: {:error, :invalid_anime_assignment}
  end

  defp revalidate_anime_source(path) do
    case Library.safe_source_file(path) do
      {:ok, _source} = ok -> ok
      {:error, :download_roots_not_configured} = error -> error
      {:error, _reason} -> {:error, :inventory_changed}
    end
  end

  defp assigned_episodes(ids, episodes) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Map.fetch(episodes, id) do
        {:ok, episode} -> {:cont, {:ok, [episode | acc]}}
        :error -> {:halt, {:error, :invalid_anime_assignment}}
      end
    end)
    |> case do
      {:ok, assigned} -> {:ok, Enum.reverse(assigned)}
      {:error, _reason} = error -> error
    end
  end
end
