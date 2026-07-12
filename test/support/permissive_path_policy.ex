defmodule Cinder.Test.PermissivePathPolicy do
  @moduledoc false

  alias Cinder.Library.PathPolicy

  def source_file(path, _roots, _extensions, _opts), do: {:ok, Path.expand(path)}

  def destination(path, root, _opts) do
    if PathPolicy.contained?(path, root),
      do: {:ok, Path.expand(path)},
      else: {:error, :unsafe_destination}
  end

  def deletable_file(_path, _roots, _opts), do: :ok

  def walk(path, opts) do
    filesystem = Keyword.fetch!(opts, :filesystem)

    if Keyword.get(opts, :source, false) do
      if filesystem.dir?(path), do: filesystem.find_files(path), else: {:error, :enotdir}
    else
      filesystem.find_files(path)
    end
  end
end
