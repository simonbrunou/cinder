defmodule Cinder.Test.ForeignFile do
  @moduledoc """
  Publishes a *different* file at `path` — the "another writer won this name" fault every identity
  check in the import is meant to notice.

  Deliberately not `File.rm!/1` followed by `File.write!/2`. That frees the old inode before the
  replacement is created, and the filesystem may hand the replacement the very number it just
  freed: the identity is then unchanged, and a check comparing `{device, inode}` reads a
  stranger's file as its own. It is allocation luck, so it passes locally and fails on CI (it did,
  in #583). Writing the replacement while the old file still holds its inode and renaming it over
  the name makes the difference structural.

  Where the identity under test also carries the size — `StageEngine.identity_matches?/2` does,
  `Sidecars`' `{major_device, inode}` does not — a size difference happens to cover for the
  reuse. Do not rely on that: it is invisible at the call site and one equal-length fixture away
  from a flake.
  """

  @spec publish!(String.t(), iodata()) :: String.t()
  def publish!(path, content) do
    staging = "#{path}.foreign-#{System.unique_integer([:positive])}"
    File.write!(staging, content)
    File.rename!(staging, path)
    path
  end
end
