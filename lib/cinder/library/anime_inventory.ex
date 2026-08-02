defmodule Cinder.Library.AnimeInventory do
  @moduledoc """
  Builds the anime file inventory — relative path plus stat identity — that
  `Cinder.Library.AnimePreflight` reasons over and the grab snapshot persists.

  Split out of `Cinder.Library` as plain code motion to keep that module under
  `code_health_test.exs`'s line cap, as `Deletion` (#256) and `Naming` (#260) were before it.
  """

  alias Cinder.Library

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
end
