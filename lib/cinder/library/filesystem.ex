defmodule Cinder.Library.Filesystem do
  @moduledoc """
  Thin filesystem primitives behind a behaviour so the import is testable
  without touching disk. The "pick the right video file" policy lives in
  `Cinder.Library`, not here.
  """

  @callback dir?(path :: String.t()) :: boolean()
  @callback find_files(dir :: String.t()) ::
              {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}
  @callback mkdir_p(dir :: String.t()) :: :ok | {:error, term()}
  @callback ln(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
  @callback cp(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
  @callback lstat(path :: String.t()) :: {:ok, File.Stat.t()} | {:error, term()}
  @callback rename(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
  @callback rm(path :: String.t()) :: :ok | {:error, term()}
  @callback rmdir(dir :: String.t()) :: :ok | {:error, term()}
  @callback write(path :: String.t(), content :: iodata()) :: :ok | {:error, term()}
  @callback moviehash_data(path :: String.t()) ::
              {:ok, {non_neg_integer(), binary(), binary()}} | :too_small | {:error, term()}
end
