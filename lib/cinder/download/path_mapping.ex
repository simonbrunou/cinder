defmodule Cinder.Download.PathMapping do
  @moduledoc false

  @spec translate(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t() | nil
  def translate(path, remote_prefix, local_prefix) when is_binary(path) do
    with {:ok, remote, local} <- prefixes(remote_prefix, local_prefix),
         true <- matches?(path, remote) do
      suffix = String.replace_prefix(path, remote, "")

      if suffix == "",
        do: local,
        else: Path.join(local, String.trim_leading(suffix, "/"))
    else
      _ -> path
    end
  end

  def translate(path, _remote_prefix, _local_prefix), do: path

  @spec validate_local_prefix(String.t() | nil, String.t() | nil) ::
          :ok | {:error, {:path_mapping_local_prefix_unreadable, String.t()}}
  def validate_local_prefix(remote_prefix, local_prefix) do
    with {:ok, _remote, local} <- prefixes(remote_prefix, local_prefix),
         {:ok, %{type: :directory, access: access}} when access in [:read, :read_write] <-
           File.stat(local) do
      :ok
    else
      :noop -> :ok
      _ -> {:error, {:path_mapping_local_prefix_unreadable, normalize(local_prefix)}}
    end
  end

  defp prefixes(remote_prefix, local_prefix) do
    remote = normalize(remote_prefix)
    local = normalize(local_prefix)

    if remote == "" or local == "", do: :noop, else: {:ok, remote, local}
  end

  defp normalize(prefix) when is_binary(prefix) do
    trimmed = String.trim(prefix)

    case String.trim_trailing(trimmed, "/") do
      "" when trimmed != "" -> "/"
      prefix -> prefix
    end
  end

  defp normalize(_prefix), do: ""

  defp matches?(path, "/"), do: String.starts_with?(path, "/")
  defp matches?(path, remote), do: path == remote or String.starts_with?(path, remote <> "/")
end
